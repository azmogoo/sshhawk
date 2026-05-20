#!/usr/bin/env bash
# sshawk - minimalist ssh log analyzer

set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SOURCE_MODE=""
LOG_FILE=""
QUIET=0
DEBUG=0

print_help() {
  cat <<'EOF'
sshawk - ssh log analyzer

usage:
  ./sshawk.sh [options]

options:
  --source authlog|journalctl|file
  --file PATH
  --help
EOF
}

log_info() {
  [[ "${QUIET}" -eq 0 ]] && printf '%s\n' "$*"
}

log_debug() {
  [[ "${DEBUG}" -eq 1 ]] && printf '[debug] %s\n' "$*" >&2
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --source) SOURCE_MODE="${2:-}"; shift 2 ;;
      --file) LOG_FILE="${2:-}"; SOURCE_MODE="file"; shift 2 ;;
      --quiet) QUIET=1; shift ;;
      --debug) DEBUG=1; shift ;;
      --help|-h) print_help; exit 0 ;;
      *) printf 'unknown option: %s\n' "$1" >&2; exit 1 ;;
    esac
  done
}

main() {
  parse_args "$@"
  log_info "sshawk: cli ok (parser not wired yet)"
}

main "$@"
