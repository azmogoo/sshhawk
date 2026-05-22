#!/usr/bin/env bash
#
# sshawk - minimalist ssh log analyzer
#

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

declare -A GEO_CACHE

print_help() {
  cat <<'EOF'
SSHawk — A minimalist SSH log analyzer and reporting tool

Usage:
  ./sshawk.sh [options]

Options:
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

log_info() {
  if [[ "${QUIET}" -eq 0 ]]; then
    printf '%s\n' "$*"
  fi
}

log_debug() {
  if [[ "${DEBUG}" -eq 1 ]]; then
    printf '[debug] %s\n' "$*" >&2
  fi
}

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
  echo "ssh"
}

collect_logs() {
  local out_file="$1"

  # make sure tmp parent dir exists
  mkdir -p "$(dirname "${out_file}")"

  : > "${out_file}"

  case "${SOURCE_MODE}" in
    authlog)
      if [[ ! -r "/var/log/auth.log" ]]; then
        printf 'error: cannot read /var/log/auth.log (try sudo)\n' >&2
        exit 1
      fi
      cat /var/log/auth.log > "${out_file}"
      ;;

    journalctl)
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

  # username from common failure formats
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

aggregate_ips() {
  local parsed_file="$1"
  local out_file="$2"

  : > "${out_file}"
  if [[ ! -s "${parsed_file}" ]]; then
    return 0
  fi

  # out: ip|count|first_ts|last_ts
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

extract_usernames() {
  local parsed_file="$1"
  local out_file="$2"

  : > "${out_file}"

  if [[ ! -s "${parsed_file}" ]]; then
    return 0
  fi

  # out: count|username
  awk -F'|' '$2 != "" && $2 != "unknown" {print $2}' "${parsed_file}" \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -n "${TOP_N}" \
    | awk '{print $1 "|" $2}' \
    > "${out_file}"
}

geolocate_ip() {
  local ip="$1"
  local url response status country region city isp query

  if [[ "${NO_GEO}" -eq 1 ]]; then
    echo "Unknown|Unknown|Unknown|Unknown|Unknown"
    return 0
  fi

  if [[ -n "${GEO_CACHE[${ip}]+x}" ]]; then
    echo "${GEO_CACHE[${ip}]}"
    return 0
  fi

  # skip private/loopback ips
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

  # parse json status field
  status="$(printf '%s' "${response}" | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  if [[ "${status}" != "success" ]]; then
    GEO_CACHE["${ip}"]="Unknown|Unknown|Unknown|Unknown|${ip}"
    sleep "${GEO_DELAY}" || true
    echo "${GEO_CACHE[${ip}]}"
    return 0
  fi

  country="$(printf '%s' "${response}" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  region="$(printf '%s' "${response}" | sed -n 's/.*"regionName"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  city="$(printf '%s' "${response}" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  isp="$(printf '%s' "${response}" | sed -n 's/.*"isp"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
  query="$(printf '%s' "${response}" | sed -n 's/.*"query"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1 || true)"
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
  : "${TOP_N:=${DEFAULT_TOP}}"

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  local raw="${tmpdir}/raw.log"
  local failed="${tmpdir}/failed.log"
  local parsed="${tmpdir}/parsed.tsv"
  local stats="${tmpdir}/ip_stats.tsv"

  collect_logs "${raw}"
  extract_failed_attempts "${raw}" "${failed}"
  : > "${parsed}"
  if [[ -s "${failed}" ]]; then
    while IFS= read -r line; do
      [[ -z "${line}" ]] && continue
      parse_log_line "${line}" >> "${parsed}" || true
    done < "${failed}"
  fi
  aggregate_ips "${parsed}" "${stats}"
  local ip
  ip="$(head -n 1 "${stats}" | cut -d'|' -f1)"
  [[ -n "${ip}" ]] && log_info "geo ${ip}: $(geolocate_ip "${ip}")"
}

main "$@"
