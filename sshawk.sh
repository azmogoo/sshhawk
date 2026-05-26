#!/usr/bin/env bash
#
# sshawk - minimalist ssh log analyzer
#

# stop on errors, unset vars, and pipe failures
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_NAME="SSHawk"
PROJECT_SUBTITLE="ssh log analyzer and reporting tool"

# runtime opts (cli overrides config)
SOURCE_MODE=""         # authlog | journalctl | file
LOG_FILE=""
TOP_N=""
NO_GEO=0
OUTPUT_PATH=""
REPORT_FORMAT=""       # text | markdown
SINCE_DATE=""
QUIET=0
DEBUG=0

# config defaults (loaded at runtime)
DEFAULT_SOURCE=""
DEFAULT_SAMPLE_FILE=""
DEFAULT_TOP=""
DEFAULT_FORMAT=""
GEO_API_URL=""
GEO_DELAY=""
REPORT_DIR=""
JOURNAL_UNITS=""

RAW_LOG_FILE=""
FAILED_LOG_FILE=""
PARSED_FILE=""
IP_STATS_FILE=""
USERNAMES_FILE=""

# geo results cached per ip during one run
declare -A GEO_CACHE

# show usage and exit
print_help() {
  cat <<'EOF'
sshawk - minimalist ssh log analyzer

usage:
  ./sshawk.sh [options]

options:
  --source authlog        Analyze /var/log/auth.log
  --source journalctl     Analyze journalctl -u ssh or journalctl -u sshd depending on the system
  --file PATH             Analyze a custom log file (useful for testing)
  --top N                 Display the top N attacking IP addresses (default from config)
  --no-geo                Disable geolocation (no curl calls)
  --output PATH           Save the report to a custom path
  --format text           Generate a text report
  --format markdown       Generate a markdown report (default)
  --since "DATE"         Filter journalctl logs since DATE (journalctl only)
  --quiet                 Reduce terminal output
  --debug                 Show debug information
  --help                  Show this help message

Examples:
  ./sshawk.sh --file samples/sample-auth.log
  ./sshawk.sh --source authlog --top 5
  sudo ./sshawk.sh --source journalctl --since "2026-05-01"
  ./sshawk.sh --file samples/sample-auth.log --no-geo --format text
EOF
}

# normal messages (skipped with --quiet)
log_info() {
  if [[ "${QUIET}" -eq 0 ]]; then
    printf '%s\n' "$*"
  fi
}

# debug lines go to stderr
log_debug() {
  if [[ "${DEBUG}" -eq 1 ]]; then
    printf '[debug] %s\n' "$*" >&2
  fi
}

# read config/sshawk.conf (optional)
load_config() {
  local conf="${SCRIPT_DIR}/config/sshawk.conf"
  if [[ ! -f "${conf}" ]]; then
    log_debug "Config not found: ${conf}"
    return 0
  fi

  # shellcheck disable=SC1090
  source "${conf}"

  # fill empty config fields
  : "${DEFAULT_SOURCE:=file}"
  : "${DEFAULT_SAMPLE_FILE:=samples/sample-auth.log}"
  : "${DEFAULT_TOP:=10}"
  : "${DEFAULT_FORMAT:=markdown}"
  : "${GEO_API_URL:=http://ip-api.com/json}"
  : "${GEO_DELAY:=1}"
  : "${REPORT_DIR:=reports}"
  : "${JOURNAL_UNITS:=ssh sshd}"
}

# only check tools we actually need for this run
check_dependencies() {
  local missing=()
  local cmd
  local required_cmds=()

  # core tools
  required_cmds+=(bash grep awk sed sort uniq wc hostname head tail)

  # journalctl mode only
  if [[ "${SOURCE_MODE}" == "journalctl" ]]; then
    required_cmds+=(journalctl systemctl)
  fi

  # geo needs curl
  if [[ "${NO_GEO}" -eq 0 ]]; then
    required_cmds+=(curl)
  fi

  for cmd in "${required_cmds[@]}"; do
    if ! command -v "${cmd}" >/dev/null 2>&1; then
      missing+=("${cmd}")
    fi
  done

  if [[ "${#missing[@]}" -gt 0 ]]; then
    printf 'error: missing commands: %s\n' "${missing[*]}" >&2
    printf 'hint: sudo apt install <packages>\n' >&2
    exit 1
  fi
}

# set SOURCE_MODE from --file, --source, or config default
detect_log_source() {
  # cli wins, else config default
  if [[ -n "${LOG_FILE}" ]]; then
    SOURCE_MODE="file"
  fi

  if [[ -z "${SOURCE_MODE}" ]]; then
    SOURCE_MODE="${DEFAULT_SOURCE}"
  fi
}

resolve_journal_unit() {
  # pick ssh or sshd unit if available
  local unit
  for unit in ${JOURNAL_UNITS}; do
    if journalctl -u "${unit}" -n 1 --no-pager >/dev/null 2>&1; then
      echo "${unit}"
      return 0
    fi
  done
  # fallback if nothing responds
  echo "ssh"
}

# copy logs into a temp file for the rest of the pipeline
collect_logs() {
  local out_file="$1"

  # make sure tmp parent dir exists
  mkdir -p "$(dirname "${out_file}")"

  : > "${out_file}"

  case "${SOURCE_MODE}" in
    authlog)
      # usually needs root
      if [[ ! -r "/var/log/auth.log" ]]; then
        printf 'error: cannot read /var/log/auth.log (try sudo)\n' >&2
        exit 1
      fi
      cat /var/log/auth.log > "${out_file}"
      ;;

    journalctl)
      # ssh or sshd depending on the distro
      local journal_unit
      journal_unit="$(resolve_journal_unit)"
      log_debug "Using journalctl unit: ${journal_unit}"

      if [[ -n "${SINCE_DATE}" ]]; then
        journalctl -u "${journal_unit}" --no-pager --since "${SINCE_DATE}" > "${out_file}" 2>/dev/null || true
      else
        journalctl -u "${journal_unit}" --no-pager > "${out_file}" 2>/dev/null || true
      fi
      ;;

    file)
      # default to sample log when no path given
      if [[ -z "${LOG_FILE}" ]]; then
        LOG_FILE="${SCRIPT_DIR}/${DEFAULT_SAMPLE_FILE}"
      fi
      if [[ ! -f "${LOG_FILE}" ]]; then
        printf 'error: log file not found: %s\n' "${LOG_FILE}" >&2
        exit 1
      fi
      if [[ ! -r "${LOG_FILE}" ]]; then
        printf 'error: cannot read log file: %s\n' "${LOG_FILE}" >&2
        exit 1
      fi
      cat "${LOG_FILE}" > "${out_file}"
      ;;

    *)
      printf 'error: unknown source: %s\n' "${SOURCE_MODE}" >&2
      exit 1
      ;;
  esac
}

# grep ssh-related failure lines from raw log
extract_failed_attempts() {
  local in_file="$1"
  local out_file="$2"

  # common openssh failure patterns
  local patterns
  patterns='Failed password for|Failed publickey|Invalid user|authentication failure|Unable to negotiate|Disconnected from authenticating user|Connection closed by.*preauth'

  : > "${out_file}"

  # ssh/sshd lines only; || true avoids errexit on no match
  grep -Ei "${patterns}" "${in_file}" 2>/dev/null | grep -E 'sshd|ssh\[' >> "${out_file}" || true
}

# one log line -> "ip|user|timestamp" (or nothing if no ip)
parse_log_line() {
  local line="$1"
  local ip=""
  local user="unknown"
  local ts=""

  # syslog ts (best effort): "May 20 08:12:01"
  ts="$(printf '%s' "${line}" | awk '{print $1, $2, $3}' | head -n 1)"

  # ipv4 in line
  if [[ "${line}" =~ ([0-9]{1,3}\.){3}[0-9]{1,3} ]]; then
    ip="${BASH_REMATCH[0]}"
  fi

  # try several regexes (order matters: invalid user before plain user)
  if [[ "${line}" =~ [Ff]ailed[[:space:]]+password[[:space:]]+for[[:space:]]+invalid[[:space:]]+user[[:space:]]+([^[:space:]]+) ]]; then
    user="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ [Ff]ailed[[:space:]]+password[[:space:]]+for[[:space:]]+([^[:space:]]+) ]]; then
    user="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ [Ff]ailed[[:space:]]+publickey[[:space:]]+for[[:space:]]+invalid[[:space:]]+user[[:space:]]+([^[:space:]]+) ]]; then
    user="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ [Ff]ailed[[:space:]]+publickey[[:space:]]+for[[:space:]]+([^[:space:]]+) ]]; then
    user="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ [Ii]nvalid[[:space:]]+user[[:space:]]+([^[:space:]]+) ]]; then
    user="${BASH_REMATCH[1]}"
  elif [[ "${line}" =~ user=([^[:space:]]+) ]]; then
    # auth failure lines: user=...
    user="${BASH_REMATCH[1]}"
  fi

  if [[ -n "${ip}" ]]; then
    printf '%s|%s|%s\n' "${ip}" "${user}" "${ts}"
  fi
}

# count attempts per ip, keep first/last timestamp
aggregate_ips() {
  local parsed_file="$1"
  local out_file="$2"

  : > "${out_file}"
  if [[ ! -s "${parsed_file}" ]]; then
    return 0
  fi

  # awk groups by ip, sort puts highest count first
  awk -F'|' '
    {
      ip=$1; ts=$3
      count[ip]++
      if (!(ip in first)) first[ip]=ts
      last[ip]=ts
    }
    END {
      for (ip in count) {
        printf "%s|%d|%s|%s\n", ip, count[ip], first[ip], last[ip]
      }
    }
  ' "${parsed_file}" | sort -t'|' -k2 -nr > "${out_file}"
}

# top usernames: sort | uniq -c | sort -nr | head
extract_usernames() {
  local parsed_file="$1"
  local out_file="$2"

  : > "${out_file}"

  if [[ ! -s "${parsed_file}" ]]; then
    return 0
  fi

  awk -F'|' '$2 != "" && $2 != "unknown" {print $2}' "${parsed_file}" \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -n "${TOP_N}" \
    | awk '{print $1 "|" $2}' \
    > "${out_file}"
}

# returns "country|region|city|isp|query" for report tables
geolocate_ip() {
  local ip="$1"
  local url response status country region city isp query

  if [[ "${NO_GEO}" -eq 1 ]]; then
    echo "Unknown|Unknown|Unknown|Unknown|Unknown"
    return 0
  fi

  # already looked up this ip in this run
  if [[ -n "${GEO_CACHE[${ip}]+x}" ]]; then
    echo "${GEO_CACHE[${ip}]}"
    return 0
  fi

  # skip private/loopback ips (no api call)
  if [[ "${ip}" =~ ^10\. ]] || \
     [[ "${ip}" =~ ^192\.168\. ]] || \
     [[ "${ip}" =~ ^127\. ]] || \
     [[ "${ip}" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] || \
     [[ "${ip}" =~ ^169\.254\. ]]; then
    GEO_CACHE["${ip}"]="Local/Private|N/A|N/A|N/A|N/A"
    echo "${GEO_CACHE[${ip}]}"
    return 0
  fi

  url="${GEO_API_URL}/${ip}?fields=status,country,regionName,city,isp,query"
  log_debug "Geolocating ${ip} via API"

  response="$(curl -sS --max-time 10 "${url}" 2>/dev/null || true)"

  # simple sed extract (no jq required)
  status="$(printf '%s' "${response}" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  if [[ "${status}" != "success" ]]; then
    GEO_CACHE["${ip}"]="Unknown|Unknown|Unknown|Unknown|${ip}"
    # small pause to avoid rate limits even on failure
    sleep "${GEO_DELAY}" || true
    echo "${GEO_CACHE[${ip}]}"
    return 0
  fi

  country="$(printf '%s' "${response}" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  region="$(printf '%s' "${response}" | sed -n 's/.*"regionName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  city="$(printf '%s' "${response}" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  isp="$(printf '%s' "${response}" | sed -n 's/.*"isp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  query="$(printf '%s' "${response}" | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"

  country="${country:-Unknown}"
  region="${region:-Unknown}"
  city="${city:-Unknown}"
  isp="${isp:-Unknown}"
  query="${query:-${ip}}"

  GEO_CACHE["${ip}"]="${country}|${region}|${city}|${isp}|${query}"
  sleep "${GEO_DELAY}" || true
  echo "${GEO_CACHE[${ip}]}"
}

# write markdown or plain text report to disk
generate_report() {
  local parsed_file="$1"
  local ip_stats_file="$2"
  local usernames_file="$3"
  local report_path="$4"

  local hostname exec_date source_label total_failed unique_ips observations recommendations

  hostname="$(hostname 2>/dev/null || true)"
  [[ -z "${hostname}" ]] && hostname="unknown-host"
  exec_date="$(date '+%Y-%m-%d %H:%M:%S')"

  case "${SOURCE_MODE}" in
    authlog) source_label="/var/log/auth.log" ;;
    journalctl)
      if [[ -n "${SINCE_DATE}" ]]; then
        source_label="journalctl (since ${SINCE_DATE})"
      else
        source_label="journalctl (ssh/sshd)"
      fi
      ;;
    file) source_label="${LOG_FILE}" ;;
    *) source_label="unknown" ;;
  esac

  total_failed="$(wc -l < "${parsed_file}" 2>/dev/null | tr -d ' ')"
  unique_ips="$(awk -F'|' '{print $1}' "${parsed_file}" 2>/dev/null | sort -u | wc -l | tr -d ' ')"

  if [[ "${total_failed}" -eq 0 ]]; then
    observations="No failed SSH authentication attempts were detected."
  else
    observations="Detected ${total_failed} failed SSH authentication event(s) from ${unique_ips} unique IP address(es)."
    if [[ "${unique_ips}" -gt 3 ]]; then
      observations="${observations} Multiple distinct sources may indicate automated scanning."
    fi
  fi

  recommendations="$(
    cat <<'RECO'
Use SSH keys and disable password authentication where possible.
Install and configure fail2ban to automatically block repeated offenders.
Restrict SSH access by IP (firewall) or other network-level controls if feasible.
Keep the system and OpenSSH updated with security patches.
Changing the default SSH port is optional and only a minor deterrent.
RECO
  )"

  mkdir -p "$(dirname "${report_path}")"

  if [[ "${REPORT_FORMAT}" == "markdown" ]]; then
    # md tables (best viewed in github / preview, not raw cat)
    {
      echo "# ${PROJECT_NAME} Security Report"
      echo
      echo "**${PROJECT_SUBTITLE}**"
      echo
      echo "| Field | Value |"
      echo "|-------|-------|"
      echo "| Generated | ${exec_date} |"
      echo "| Hostname | ${hostname} |"
      echo "| Log source | ${source_label} |"
      echo "| Total failed attempts | ${total_failed} |"
      echo "| Unique attacking IPs | ${unique_ips} |"
      echo
      echo "## Top attacking IP addresses"
      echo
      echo "| Rank | IP | Attempts | First seen | Last seen | Country | Region | City | ISP |"
      echo "|------|----|----------|------------|-----------|---------|--------|------|-----|"
      local rank ip count first last geo country region city isp query
      rank=0
      if [[ -s "${ip_stats_file}" ]]; then
        while IFS='|' read -r ip count first last; do
          [[ -z "${ip}" ]] && continue
          rank=$((rank + 1))
          [[ "${rank}" -gt "${TOP_N}" ]] && break
          # geo called here (can be slow without --no-geo)
          geo="$(geolocate_ip "${ip}")"
          IFS='|' read -r country region city isp query <<< "${geo}"
          echo "| ${rank} | ${ip} | ${count} | ${first} | ${last} | ${country} | ${region} | ${city} | ${isp} |"
        done < "${ip_stats_file}"
      else
        echo "| 1 | N/A | 0 | N/A | N/A | Unknown | Unknown | Unknown | Unknown |"
      fi

      echo
      echo "## Top targeted usernames"
      echo
      echo "| Rank | Username | Attempts |"
      echo "|------|----------|----------|"
      local urank ucount uname
      urank=0
      if [[ -s "${usernames_file}" ]]; then
        while IFS='|' read -r ucount uname; do
          [[ -z "${uname}" ]] && continue
          urank=$((urank + 1))
          echo "| ${urank} | ${uname} | ${ucount} |"
        done < "${usernames_file}"
      else
        echo "| 1 | N/A | 0 |"
      fi

      echo
      echo "## Security observations"
      echo
      echo "${observations}"
      echo
      echo "## Recommendations"
      echo
      while IFS= read -r line; do
        echo "- ${line}"
      done <<< "${recommendations}"
      echo
      echo "---"
      echo "_Report generated by SSHawk. Educational use only._"
    } > "${report_path}"
  else
    # text format: easier to read in the terminal
    {
      echo "${PROJECT_NAME} Security Report"
      echo "${PROJECT_SUBTITLE}"
      echo
      echo "Generated: ${exec_date}"
      echo "Hostname : ${hostname}"
      echo "Source   : ${source_label}"
      echo "Total failed attempts : ${total_failed}"
      echo "Unique attacking IPs  : ${unique_ips}"
      echo
      echo "Top attacking IPs:"
      local rank2 ip2 count2 first2 last2 geo2 country2 region2 city2 isp2 query2
      rank2=0
      if [[ -s "${ip_stats_file}" ]]; then
        while IFS='|' read -r ip2 count2 first2 last2; do
          [[ -z "${ip2}" ]] && continue
          rank2=$((rank2 + 1))
          [[ "${rank2}" -gt "${TOP_N}" ]] && break
          geo2="$(geolocate_ip "${ip2}")"
          IFS='|' read -r country2 region2 city2 isp2 query2 <<< "${geo2}"
          echo "  ${rank2}. ${ip2} (${count2} attempts) ${first2} -> ${last2}"
          echo "     Location: ${city2}, ${region2}, ${country2} | ISP: ${isp2}"
        done < "${ip_stats_file}"
      else
        echo "  (none)"
      fi
      echo
      echo "Top targeted usernames:"
      if [[ -s "${usernames_file}" ]]; then
        while IFS='|' read -r ucount uname; do
          [[ -z "${uname}" ]] && continue
          echo "  ${uname} (${ucount} attempts)"
        done < "${usernames_file}"
      else
        echo "  (none)"
      fi
      echo
      echo "Observations:"
      echo "${observations}"
      echo
      echo "Recommendations:"
      while IFS= read -r line; do
        echo "- ${line}"
      done <<< "${recommendations}"
    } > "${report_path}"
  fi
}

# map --flags to global variables
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source)
        SOURCE_MODE="${2:-}"
        shift 2
        ;;
      --file)
        LOG_FILE="${2:-}"
        SOURCE_MODE="file"
        shift 2
        ;;
      --top)
        TOP_N="${2:-10}"
        shift 2
        ;;
      --no-geo)
        NO_GEO=1
        shift
        ;;
      --output)
        OUTPUT_PATH="${2:-}"
        shift 2
        ;;
      --format)
        REPORT_FORMAT="${2:-markdown}"
        shift 2
        ;;
      --since)
        SINCE_DATE="${2:-}"
        shift 2
        ;;
      --quiet)
        QUIET=1
        shift
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      --help|-h)
        print_help
        exit 0
        ;;
      *)
        printf 'unknown option: %s\n' "$1" >&2
        print_help >&2 || true
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  load_config
  detect_log_source

  # cli defaults
  : "${TOP_N:=${DEFAULT_TOP}}"
  : "${REPORT_FORMAT:=${DEFAULT_FORMAT}}"

  check_dependencies

  # default report path
  if [[ -z "${OUTPUT_PATH}" ]]; then
    local ts
    ts="$(date '+%Y-%m-%d_%H-%M-%S')"
    if [[ "${REPORT_FORMAT}" == "text" ]]; then
      OUTPUT_PATH="${SCRIPT_DIR}/${REPORT_DIR}/ssh_report_${ts}.txt"
    else
      OUTPUT_PATH="${SCRIPT_DIR}/${REPORT_DIR}/ssh_report_${ts}.md"
    fi
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  # nounset-safe cleanup on exit
  trap '[[ -n "${tmpdir:-}" ]] && rm -rf "${tmpdir}" 2>/dev/null || true' EXIT

  # temp files for each pipeline stage
  RAW_LOG_FILE="${tmpdir}/raw.log"
  FAILED_LOG_FILE="${tmpdir}/failed.log"
  PARSED_FILE="${tmpdir}/parsed.tsv"
  IP_STATS_FILE="${tmpdir}/ip_stats.tsv"
  USERNAMES_FILE="${tmpdir}/usernames.tsv"

  collect_logs "${RAW_LOG_FILE}"
  extract_failed_attempts "${RAW_LOG_FILE}" "${FAILED_LOG_FILE}"

  # build parsed.tsv: one row per failed attempt with an ip
  : > "${PARSED_FILE}"
  if [[ -s "${FAILED_LOG_FILE}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      # append parsed line when ip found
      parse_log_line "${line}" >> "${PARSED_FILE}" || true
    done < "${FAILED_LOG_FILE}"
  fi

  aggregate_ips "${PARSED_FILE}" "${IP_STATS_FILE}"
  extract_usernames "${PARSED_FILE}" "${USERNAMES_FILE}"
  generate_report "${PARSED_FILE}" "${IP_STATS_FILE}" "${USERNAMES_FILE}" "${OUTPUT_PATH}"

  log_info ""
  log_info "Report saved to: ${OUTPUT_PATH}"
  log_info "Total failed attempts: $(wc -l < "${PARSED_FILE}" 2>/dev/null | tr -d ' ')"
}

main "$@"

