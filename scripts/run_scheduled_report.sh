#!/usr/bin/env bash
# wrapper for cron or systemd timer (read-only report generation)
set -o errexit
set -o nounset
set -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# try auth.log first, fall back to journalctl on minimal images
if [[ -r /var/log/auth.log ]]; then
  ./sshawk.sh --source authlog --no-geo --quiet
elif command -v journalctl >/dev/null 2>&1; then
  ./sshawk.sh --source journalctl --no-geo --quiet
else
  printf 'error: no readable ssh log source found\n' >&2
  exit 1
fi
