#!/bin/bash
#
# Test fixture: prints one header value out of a recorded response.
#
# The suite drives `scripts/lib/cors-headers.sh` through this fixture rather
# than sourcing the library directly, so the library's own lines are executed
# in a traced subprocess and therefore appear in the coverage ledger.
#
# Usage: header-probe.sh <header-name> <raw-response>

set -u

# shellcheck source=../../lib/cors-headers.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../lib" && pwd)/cors-headers.sh"

case "$1" in
  Access-Control-Allow-Origin)      acao "$2" ;;
  Access-Control-Allow-Credentials) acac "$2" ;;
  *)                                http_header_value "$1" "$2" ;;
esac
