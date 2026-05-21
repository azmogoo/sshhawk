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

  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "${tmpdir}"' EXIT
  local raw="${tmpdir}/raw.log"
  local failed="${tmpdir}/failed.log"
  collect_logs "${raw}"
  extract_failed_attempts "${raw}" "${failed}"
  log_info "failed ssh lines: $(wc -l < "${failed}" | tr -d ' ')"
}

main "$@"
