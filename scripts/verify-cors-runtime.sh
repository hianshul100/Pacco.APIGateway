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
#     come back with `Access-Control-Allow-Origin` echoing that exact origin;
#   * the SAME preflight and POST from a DIFFERENT origin must come back with
#     `Access-Control-Allow-Origin` absent, or not matching the caller — which
#     is what makes the response unreadable to the page.
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
# Usage:
#   ./scripts/verify-cors-runtime.sh [gateway-base-url] [allowed-origin] [disallowed-origin]
#
# Defaults: http://localhost:5000  http://localhost:3000  http://localhost:3999
#
# Exit codes: 0 = pass, 1 = fail, 2 = NOT RUN (gateway unreachable or curl absent).

set -u

GATEWAY="${1:-${PACCO_GATEWAY_URL:-http://localhost:5000}}"
ALLOWED_ORIGIN="${2:-${PACCO_WEB_ORIGIN:-http://localhost:3000}}"
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

# Prints the `Access-Control-Allow-Origin` value of a response, or the empty
# string when the header is absent.
acao() {
  printf '%s' "$1" \
    | tr -d '\r' \
    | awk 'BEGIN { IGNORECASE = 1 } /^access-control-allow-origin:/ { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }'
}

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

allowed_preflight_acao="$(acao "$(preflight "$ALLOWED_ORIGIN")")"
allowed_post_acao="$(acao "$(sign_in_post "$ALLOWED_ORIGIN")")"
disallowed_preflight_acao="$(acao "$(preflight "$DISALLOWED_ORIGIN")")"
disallowed_post_acao="$(acao "$(sign_in_post "$DISALLOWED_ORIGIN")")"

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

echo
echo "Disallowed origin ($DISALLOWED_ORIGIN)"
for label in preflight post; do
  if [[ "$label" == preflight ]]; then value="$disallowed_preflight_acao"; else value="$disallowed_post_acao"; fi
  if [[ -z "$value" || "$value" != "$DISALLOWED_ORIGIN" ]]; then
    pass "$label response is unreadable to the page (Access-Control-Allow-Origin: '${value:-<absent>}')"
  else
    fail "$label response is readable from a disallowed origin"
  fi
done

echo
echo "Direct comparison of the two responses"
# The load-bearing assertion. Under a '*' configuration BOTH origins are
# allowed, so the allowed-origin half passes while nothing has actually changed.
if [[ "$allowed_preflight_acao" == "*" || "$disallowed_preflight_acao" == "*" ]]; then
  fail "the gateway still answers with a wildcard Access-Control-Allow-Origin"
elif [[ "$allowed_preflight_acao" != "$disallowed_preflight_acao" ]]; then
  pass "the two origins receive DIFFERENT Access-Control-Allow-Origin headers"
else
  fail "both origins receive the same Access-Control-Allow-Origin — exact-origin matching is not in effect"
fi

echo
if (( failures > 0 )); then
  echo "RESULT: FAIL — $failures check(s) failed. AC-16 is NOT satisfied."
  exit 1
fi

echo "RESULT: PASS — AC-16 header contract holds at the running gateway."
exit 0
