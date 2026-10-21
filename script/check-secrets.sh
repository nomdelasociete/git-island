#!/usr/bin/env bash
# Never emit matched lines, credentials, or a downloadable findings report.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if ! command -v gitleaks >/dev/null 2>&1; then
  echo 'Gitleaks 8.30.1 is required.' >&2
  exit 2
fi
if [[ "$(gitleaks version)" != '8.30.1' ]]; then
  echo 'Use the reviewed Gitleaks version 8.30.1.' >&2
  exit 2
fi
status=0
gitleaks git . --log-opts='--all' --redact=100 --no-banner --exit-code=10 >/dev/null 2>&1 || status=$?
case "$status" in
  0) echo 'Secret scan passed.' ;;
  10)
    echo 'Potential secret detected. Review locally with Gitleaks --redact=100; do not post findings or raw values in public logs.' >&2
    exit 1
    ;;
  *)
    echo 'Secret scan could not complete. Check the local scanner installation and Git history; publication is not cleared.' >&2
    exit 2
    ;;
esac
