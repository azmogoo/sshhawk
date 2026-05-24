#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TMP_REPORT="$(mktemp -p "${PROJECT_ROOT}/reports" sshhawk_test_XXXX.md)"

cleanup() {
  rm -f "${TMP_REPORT}" 2>/dev/null || true
}
trap cleanup EXIT

echo "running sshawk test on sample log..."

"${PROJECT_ROOT}/sshawk.sh" \
  --file "${PROJECT_ROOT}/samples/sample-auth.log" \
  --no-geo \
  --format markdown \
  --output "${TMP_REPORT}" \
  --quiet

if [[ ! -f "${TMP_REPORT}" ]]; then
  echo "test failed: no report at ${TMP_REPORT}" >&2
  exit 1
fi

# known ips from sample
grep -q "203.0.113.45" "${TMP_REPORT}"
grep -q "198.51.100.23" "${TMP_REPORT}"
grep -q "192.0.2.77" "${TMP_REPORT}"

# expect 6 failed attempts total
grep -q "| Total failed attempts | 6 |" "${TMP_REPORT}"

grep -q "admin" "${TMP_REPORT}"
grep -q "root" "${TMP_REPORT}"
grep -q "deploy" "${TMP_REPORT}"

echo "test ok."

