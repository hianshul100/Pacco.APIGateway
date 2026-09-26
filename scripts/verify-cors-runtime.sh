#!/bin/bash
#
# Edge cross-origin RUNTIME check — AC-16 / FR-11, header half.
#
# AC-16 is a runtime behaviour, not a configuration value: "GIVEN the running
# gateway, WHEN a cross-origin sign-in request is made from the allowed origin,
# THEN the browser accepts the response, AND WHEN the same request is made from
# any other origin, THEN the browser rejects it."
#
# This script exercises the header contract the browser's decision is made from,
# against the RUNNING gateway:
#
#   * the sign-in preflight and the sign-in POST from the ALLOWED origin must
#     come back with `Access-Control-Allow-Origin` echoing that exact origin,
#     and with `Access-Control-Allow-Credentials: true` — the pairing the Fetch
#     Standard permits only for an exact origin, never for `*`;
#   * the SAME preflight and POST from a DIFFERENT origin must come back with
#     `Access-Control-Allow-Origin` absent, or naming some other origin — which
#     is what makes the response unreadable to the page.
#
# Every one of the four captured responses is rejected if it carries a `*`
# origin: a `*` IS readable by a non-credentialed page, so a configuration that
# echoed the exact origin on the preflight and answered `*` on the POST would
# still leave the response readable from anywhere. The wildcard check therefore
# runs per response rather than only on the preflight pair.
#
# Both halves are required. A wildcard configuration passes the allowed-origin
# check on its own, so the allowed-origin check alone is NOT evidence the change
# was made — the two responses' headers are compared directly
# (LOW_LEVEL_SPEC-13652-wave-1.md §L.6.A.5).
#
# The in-browser half of AC-16 — that a real browser accepts one response and
# rejects the other — is `Pacco.Web/scripts/cors-browser-check.mjs`, which drives
# headless Chromium from two real origins. This script is the dependency-free
# check that lives with the configuration it guards.
#
# Per LOW_LEVEL_SPEC-13652-wave-1.md §L.6.2, where the stack is unavailable the
# affected rows are reported as NOT RUN, never as passed. That is exit code 2.
#
# The header parsing this check turns on lives in `scripts/lib/cors-headers.sh`
# and is covered by `scripts/tests/cors-guard.test.sh`, which drives it over
# recorded response fixtures and over a local mock edge — so the parsing is
# verified without a stack even though the check itself needs one.
#
# Usage:
#   ./scripts/verify-cors-runtime.sh [gateway-base-url] [allowed-origin] [disallowed-origin]
#
# Defaults: http://localhost:5000  http://localhost:5173  http://localhost:3999
#
# Exit codes: 0 = pass, 1 = fail, 2 = NOT RUN (gateway unreachable or curl absent).

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/cors-headers.sh
source "$SCRIPT_DIR/lib/cors-headers.sh"

GATEWAY="${1:-${PACCO_GATEWAY_URL:-http://localhost:5000}}"
ALLOWED_ORIGIN="${2:-${PACCO_WEB_ORIGIN:-http://localhost:5173}}"
DISALLOWED_ORIGIN="${3:-${PACCO_DISALLOWED_ORIGIN:-http://localhost:3999}}"
SIGN_IN_PATH="/identity/sign-in"

not_run() {
  echo
  echo "RESULT: NOT RUN — $1"
  echo "        AC-16 (FR-11) is NOT discharged by this run. It must be reported"
  echo "        as 'not run', never as passed (§L.6.2)."
  exit 2
}

if ! command -v curl >/dev/null 2>&1; then
  not_run "curl is not available on this machine."
fi

echo "Edge cross-origin runtime check (AC-16 / FR-11)"
echo "  gateway            : $GATEWAY"
echo "  allowed origin     : $ALLOWED_ORIGIN"
echo "  disallowed origin  : $DISALLOWED_ORIGIN"
echo

if ! curl -sS -o /dev/null --max-time 5 "$GATEWAY/" 2>/dev/null; then
  not_run "the gateway did not answer at $GATEWAY. Start the Docker Compose stack (docs: §L.12.3) and re-run."
fi

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# The preflight a JSON POST triggers: the client adds `Content-Type:
# application/json` and no custom header (§L.12.2).
preflight() {
  curl -sS -i -X OPTIONS --max-time 10 \
    -H "Origin: $1" \
    -H "Access-Control-Request-Method: POST" \
    -H "Access-Control-Request-Headers: content-type" \
    "$GATEWAY$SIGN_IN_PATH" 2>/dev/null
}

# The sign-in POST itself. The body is deliberately an empty credential pair:
# AC-16 asks whether the BROWSER may read the response, not whether the
# credentials are valid, and no credential may be hard-coded anywhere (AC-7).
sign_in_post() {
  curl -sS -i -X POST --max-time 10 \
    -H "Origin: $1" \
    -H "Content-Type: application/json" \
    --data '{"email":"","password":""}' \
    "$GATEWAY$SIGN_IN_PATH" 2>/dev/null
}

allowed_preflight="$(preflight "$ALLOWED_ORIGIN")"
allowed_post="$(sign_in_post "$ALLOWED_ORIGIN")"
disallowed_preflight="$(preflight "$DISALLOWED_ORIGIN")"
disallowed_post="$(sign_in_post "$DISALLOWED_ORIGIN")"

allowed_preflight_acao="$(acao "$allowed_preflight")"
allowed_post_acao="$(acao "$allowed_post")"
disallowed_preflight_acao="$(acao "$disallowed_preflight")"
disallowed_post_acao="$(acao "$disallowed_post")"

allowed_preflight_acac="$(acac "$allowed_preflight")"
allowed_post_acac="$(acac "$allowed_post")"

# Every captured response is screened for the wildcard first. A `*` origin is
# readable by any non-credentialed page, so it fails the criterion wherever it
# appears — including on a response to the disallowed origin, where a bare
# "does not echo my origin" test would have let it through.
for label in "allowed preflight" "allowed POST" "disallowed preflight" "disallowed POST"; do
  case "$label" in
    "allowed preflight")    value="$allowed_preflight_acao" ;;
    "allowed POST")         value="$allowed_post_acao" ;;
    "disallowed preflight") value="$disallowed_preflight_acao" ;;
    *)                      value="$disallowed_post_acao" ;;
  esac
  if [[ "$value" == "*" ]]; then
    fail "$label response carries a wildcard Access-Control-Allow-Origin — readable from any origin"
  fi
done

echo "Allowed origin ($ALLOWED_ORIGIN)"
if [[ "$allowed_preflight_acao" == "$ALLOWED_ORIGIN" ]]; then
  pass "preflight echoes the exact origin"
else
  fail "preflight returned Access-Control-Allow-Origin: '${allowed_preflight_acao:-<absent>}'"
fi
if [[ "$allowed_post_acao" == "$ALLOWED_ORIGIN" ]]; then
  pass "POST $SIGN_IN_PATH echoes the exact origin"
else
  fail "POST returned Access-Control-Allow-Origin: '${allowed_post_acao:-<absent>}'"
fi

# `allowCredentials: true` is the sibling half of the change: it is precisely
# what makes a `*` origin illegal, so a runtime that quietly dropped the header
# would leave the static guard passing and the contract broken.
if [[ "$allowed_preflight_acac" == "true" ]]; then
  pass "preflight returns Access-Control-Allow-Credentials: true"
else
  fail "preflight returned Access-Control-Allow-Credentials: '${allowed_preflight_acac:-<absent>}'; 'true' is required"
fi
if [[ "$allowed_post_acac" == "true" ]]; then
  pass "POST $SIGN_IN_PATH returns Access-Control-Allow-Credentials: true"
else
  fail "POST returned Access-Control-Allow-Credentials: '${allowed_post_acac:-<absent>}'; 'true' is required"
fi

echo
echo "Disallowed origin ($DISALLOWED_ORIGIN)"
for label in preflight post; do
  if [[ "$label" == preflight ]]; then value="$disallowed_preflight_acao"; else value="$disallowed_post_acao"; fi
  if [[ "$value" == "*" ]]; then
    fail "$label response is readable from a disallowed origin (Access-Control-Allow-Origin: '*')"
  elif [[ "$value" == "$DISALLOWED_ORIGIN" ]]; then
    fail "$label response is readable from a disallowed origin (the origin is echoed back)"
  else
    pass "$label response is unreadable to the page (Access-Control-Allow-Origin: '${value:-<absent>}')"
  fi
done

echo
echo "Direct comparison of the two origins' responses"
# The load-bearing assertion. Under a '*' configuration BOTH origins are
# allowed, so the allowed-origin half passes while nothing has actually changed.
# Both the preflight pair and the POST pair are compared, because exact-origin
# matching has to hold on the response that actually carries the body.
for label in preflight post; do
  if [[ "$label" == preflight ]]; then
    allowed_value="$allowed_preflight_acao"; disallowed_value="$disallowed_preflight_acao"
  else
    allowed_value="$allowed_post_acao"; disallowed_value="$disallowed_post_acao"
  fi
  if [[ "$allowed_value" != "$disallowed_value" ]]; then
    pass "$label: the two origins receive DIFFERENT Access-Control-Allow-Origin headers"
  else
    fail "$label: both origins receive the same Access-Control-Allow-Origin — exact-origin matching is not in effect"
  fi
done

echo
if (( failures > 0 )); then
  echo "RESULT: FAIL — $failures check(s) failed. AC-16 is NOT satisfied."
  exit 1
fi

echo "RESULT: PASS — AC-16 header contract holds at the running gateway."
echo
echo "NOTE: this is the header half of AC-16. The in-browser half — a real"
echo "      browser accepting one response and refusing the other — is"
echo "      'npm run verify:cors-browser' in the Pacco.Web checkout."
exit 0
