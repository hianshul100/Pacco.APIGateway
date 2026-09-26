#!/bin/bash
#
# Automated suite for the edge cross-origin guards.
#
# The guards are the only thing standing between an `ntrada*.yml` regression and
# a merge, so they need tests of their own: a check that cannot fail on a broken
# configuration, or cannot pass on a correct one, is worse than no check at all.
# The case in point is header matching — `awk`'s `IGNORECASE` is a GNU
# extension that mawk, the default `awk` on Debian and Ubuntu, accepts and then
# ignores, so an `IGNORECASE`-based match silently reports every header as
# absent. Group 1 below pins that behaviour over recorded responses.
#
# Three groups:
#
#   1. scripts/lib/cors-headers.sh over recorded response fixtures — no network,
#      no stack, runs anywhere `bash` and `awk` do.
#   2. scripts/verify-cors-config.sh over mutated copies of the four
#      `ntrada*.yml` files — each mutation the guard exists to catch is injected
#      and the guard is asserted to catch it.
#   3. scripts/verify-cors-runtime.sh against a local mock edge that presents
#      the compliant header shape and four non-compliant ones. This proves the
#      instrument works; it does NOT discharge AC-16, which is a statement about
#      the real gateway and is reported separately (§L.6.2).
#
# Line coverage of the three shell modules is measured and enforced; see
# scripts/tests/lib/bashcov.sh for why it is measured this way.
#
# Exit codes: 0 = all assertions passed and coverage met, 1 = otherwise.

set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# shellcheck source=lib/bashcov.sh
source "$TESTS_DIR/lib/bashcov.sh"

CONFIG_GUARD="$SCRIPTS_DIR/verify-cors-config.sh"
RUNTIME_CHECK="$SCRIPTS_DIR/verify-cors-runtime.sh"
HEADERS_LIB="$SCRIPTS_DIR/lib/cors-headers.sh"
HEADER_PROBE="$TESTS_DIR/fixtures/header-probe.sh"
MOCK_EDGE="$TESTS_DIR/fixtures/mock-edge.py"

WORK_DIR="$(mktemp -d)"
BASHCOV_LEDGER="$WORK_DIR/coverage.ledger"
: >"$BASHCOV_LEDGER"

MOCK_PID=""
cleanup() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

assertions=0
failed=0
skipped=0

ok()   { assertions=$((assertions + 1)); printf '  ok    %s\n' "$1"; }
notok() {
  assertions=$((assertions + 1))
  failed=$((failed + 1))
  printf '  FAIL  %s\n' "$1"
  [[ $# -gt 1 ]] && printf '        %s\n' "$2"
}
skip() { skipped=$((skipped + 1)); printf '  skip  %s\n' "$1"; }

assert_equals() { # <name> <expected> <actual>
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    notok "$1" "expected '$2', got '$3'"
  fi
}

assert_status() { # <name> <expected-status> <actual-status>
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    notok "$1" "expected exit $2, got exit $3"
  fi
}

assert_contains() { # <name> <needle> <haystack>
  if [[ "$3" == *"$2"* ]]; then
    ok "$1"
  else
    notok "$1" "output did not contain '$2'"
  fi
}

# ---------------------------------------------------------------------------
# Group 1 — header parsing over recorded responses
# ---------------------------------------------------------------------------

header_value() { # <header-name> <response>
  bashcov_run "$HEADER_PROBE" "$1" "$2"
  printf '%s' "$BASHCOV_STDOUT"
}

echo "1. scripts/lib/cors-headers.sh — header parsing"

# The capitalisation a real server emits. This is the case the IGNORECASE
# implementation got wrong, and the reason the suite exists.
CANONICAL=$'HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: http://localhost:3000\r\nAccess-Control-Allow-Credentials: true\r\n\r\n'
assert_equals "canonical capitalisation is matched" \
  "http://localhost:3000" "$(header_value Access-Control-Allow-Origin "$CANONICAL")"
assert_equals "Access-Control-Allow-Credentials is read from the same response" \
  "true" "$(header_value Access-Control-Allow-Credentials "$CANONICAL")"

LOWER=$'HTTP/2 204\r\naccess-control-allow-origin: http://localhost:3000\r\n\r\n'
assert_equals "all-lower-case spelling is matched (HTTP/2 style)" \
  "http://localhost:3000" "$(header_value Access-Control-Allow-Origin "$LOWER")"

UPPER=$'HTTP/1.1 200 OK\r\nACCESS-CONTROL-ALLOW-ORIGIN: http://localhost:3000\r\n\r\n'
assert_equals "all-upper-case spelling is matched" \
  "http://localhost:3000" "$(header_value Access-Control-Allow-Origin "$UPPER")"

ABSENT=$'HTTP/1.1 204 No Content\r\nVary: Origin\r\nContent-Length: 0\r\n\r\n'
assert_equals "an absent header yields the empty string" \
  "" "$(header_value Access-Control-Allow-Origin "$ABSENT")"
assert_equals "an absent Access-Control-Allow-Credentials yields the empty string" \
  "" "$(header_value Access-Control-Allow-Credentials "$ABSENT")"

WILDCARD=$'HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\n\r\n'
assert_equals "a wildcard value is returned verbatim, not swallowed" \
  "*" "$(header_value Access-Control-Allow-Origin "$WILDCARD")"

PADDED=$'HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: \t http://localhost:3000  \r\n\r\n'
assert_equals "surrounding whitespace is trimmed from the value" \
  "http://localhost:3000" "$(header_value Access-Control-Allow-Origin "$PADDED")"

BURIED=$'HTTP/1.1 400 Bad Request\r\nDate: Mon, 01 Jan 2035 00:00:00 GMT\r\nServer: Kestrel\r\nVary: Origin\r\nAccess-Control-Allow-Origin: http://localhost:3000\r\nContent-Type: application/json\r\n\r\n{"code":"error"}'
assert_equals "a header below other headers is still found" \
  "http://localhost:3000" "$(header_value Access-Control-Allow-Origin "$BURIED")"

PREFIXED=$'HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin-Patterns: http://evil.example\r\n\r\n'
assert_equals "a longer header name that merely starts the same does not match" \
  "" "$(header_value Access-Control-Allow-Origin "$PREFIXED")"

BODY_DECOY=$'HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\n\r\nAccess-Control-Allow-Origin: http://evil.example'
assert_equals "a body line spelling the header name is not read as a header" \
  "" "$(header_value Access-Control-Allow-Origin "$BODY_DECOY")"

# curl -i prints the 100 Continue preamble ahead of the real response; the value
# that matters is the one on the final section.
CONTINUE=$'HTTP/1.1 100 Continue\r\n\r\nHTTP/1.1 400 Bad Request\r\nAccess-Control-Allow-Origin: http://localhost:3000\r\n\r\n{}'
assert_equals "the final header section wins over a 100 Continue preamble" \
  "http://localhost:3000" "$(header_value Access-Control-Allow-Origin "$CONTINUE")"

echo

# ---------------------------------------------------------------------------
# Group 2 — the static guard against mutated configuration
# ---------------------------------------------------------------------------

echo "2. scripts/verify-cors-config.sh — mutation cases"

NTRADA_FILES=(ntrada.yml ntrada.docker.yml ntrada-async.yml ntrada-async.docker.yml)

# Copies the four real files into a throw-away directory, applies an optional
# sed expression to one of them, and runs the guard over the copy.
run_guard_on_mutation() { # <case-name> [file] [sed-expression]
  local case_name="$1"
  local target="${2:-}"
  local expression="${3:-}"
  local dir="$WORK_DIR/cfg-$case_name"

  mkdir -p "$dir"
  local name
  for name in "${NTRADA_FILES[@]}"; do
    cp "$ROOT/src/Pacco.APIGateway/$name" "$dir/$name"
  done
  if [[ -n "$target" && -n "$expression" ]]; then
    sed -i "$expression" "$dir/$target"
  fi

  PACCO_NTRADA_DIR="$dir" bashcov_run "$CONFIG_GUARD"
}

run_guard_on_mutation pristine
assert_status "the guard passes on the configuration as committed" 0 "$BASHCOV_STATUS"
assert_contains "the passing run names the allowed origin" \
  "RESULT: PASS — allowed origin is 'http://localhost:3000'" "$BASHCOV_STDOUT"
assert_contains "the passing run states it is the static half only" \
  "STATIC half of FR-11 (AC-15) only" "$BASHCOV_STDOUT"

# The regression the change exists to prevent.
run_guard_on_mutation wildcard ntrada.yml "s|- 'http://localhost:3000'|- '*'|"
assert_status "a restored wildcard fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "a restored wildcard is named as a wildcard" \
  "still allows the '*' wildcard origin" "$BASHCOV_STDOUT"
assert_contains "a restored wildcard also breaks four-file identity" \
  "cors block differs from" "$BASHCOV_STDOUT"

# BR-8: an allow-list of several origins is not the contract either.
run_guard_on_mutation second-origin ntrada.yml \
  "s|- 'http://localhost:3000'|- 'http://localhost:3000'\n      - 'http://localhost:4000'|"
assert_status "a second allowed origin fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "a second allowed origin is counted" \
  "allows 2 origin(s); exactly 1 is required" "$BASHCOV_STDOUT"

# A same-value edit in only one file: the four-file identity check is the only
# thing that catches this, so it is asserted on its own.
run_guard_on_mutation drift ntrada-async.docker.yml \
  "s|- 'http://localhost:3000'|- 'http://127.0.0.1:3000'|"
assert_status "one file drifting from the other three fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "the drifting file is named" \
  "ntrada-async.docker.yml cors block differs from ntrada.yml" "$BASHCOV_STDOUT"

# An origin without a port is not an exact origin for a dev server.
run_guard_on_mutation no-port ntrada.yml "s|- 'http://localhost:3000'|- 'http://localhost'|"
assert_status "an origin without a port fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "the incomplete origin is reported" \
  "is not a concrete scheme://host:port origin" "$BASHCOV_STDOUT"

run_guard_on_mutation credentials ntrada.yml "s|allowCredentials: true|allowCredentials: false|"
assert_status "flipping allowCredentials fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "flipping allowCredentials names the expected value" \
  "allowCredentials differs from the expected value 'true'" "$BASHCOV_STDOUT"

run_guard_on_mutation methods ntrada.yml "s|^      - delete$||"
assert_status "dropping an allowed method fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "dropping an allowed method names the expected value" \
  "allowedMethods differs from the expected value" "$BASHCOV_STDOUT"

run_guard_on_mutation exposed ntrada.yml "s|^      - Trace-ID$|      - Span-ID|"
assert_status "renaming an exposed header fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "renaming an exposed header names the expected value" \
  "exposedHeaders differs from the expected value" "$BASHCOV_STDOUT"

# Logout stays a client-side session discard: no gateway route may appear.
run_guard_on_mutation logout ntrada.yml \
  "s|^      - upstream: /sign-in$|      - upstream: /sign-out\n      - upstream: /sign-in|"
assert_status "an injected sign-out route fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "the injected route is named" \
  "introduces a logout or revoke route" "$BASHCOV_STDOUT"

run_guard_on_mutation jwt ntrada.yml "s|^  jwt:$|  jsonwebtoken:|"
assert_status "renaming the jwt extension fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "the altered jwt extension is reported" \
  "jwt extension differs from the expected shape" "$BASHCOV_STDOUT"

# A deleted configuration file must not read as "nothing to check".
MISSING_DIR="$WORK_DIR/cfg-missing"
mkdir -p "$MISSING_DIR"
cp "$ROOT/src/Pacco.APIGateway/ntrada.yml" "$MISSING_DIR/ntrada.yml"
PACCO_NTRADA_DIR="$MISSING_DIR" bashcov_run "$CONFIG_GUARD"
assert_status "a missing ntrada file fails the guard" 1 "$BASHCOV_STATUS"
assert_contains "the missing file is named" "ntrada.docker.yml is missing" "$BASHCOV_STDOUT"

echo

# ---------------------------------------------------------------------------
# Group 3 — the runtime check against a mock edge
# ---------------------------------------------------------------------------

echo "3. scripts/verify-cors-runtime.sh — against a local mock edge"
echo "   (proves the instrument; AC-16 remains a statement about the REAL gateway)"

ALLOWED="http://localhost:3000"
DISALLOWED="http://localhost:3999"

start_mock_edge() { # <mode> -> echoes the base URL, or empty on failure
  local mode="$1" port=""
  local out="$WORK_DIR/mock-$mode.port"

  python3 "$MOCK_EDGE" "$mode" >"$out" 2>/dev/null &
  MOCK_PID=$!

  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    port="$(head -n 1 "$out" 2>/dev/null)"
    [[ -n "$port" ]] && break
    sleep 0.2
  done

  [[ -z "$port" ]] && return 1
  printf 'http://127.0.0.1:%s' "$port"
}

stop_mock_edge() {
  [[ -n "$MOCK_PID" ]] && kill "$MOCK_PID" 2>/dev/null
  wait "$MOCK_PID" 2>/dev/null || true
  MOCK_PID=""
}

run_against_mock() { # <mode>
  local base
  base="$(start_mock_edge "$1")" || return 1
  bashcov_run "$RUNTIME_CHECK" "$base" "$ALLOWED" "$DISALLOWED"
  stop_mock_edge
}

if ! command -v python3 >/dev/null 2>&1; then
  skip "mock-edge cases need python3, which is not installed here"
elif ! run_against_mock exact; then
  skip "mock-edge cases need a bindable loopback port"
else
  assert_status "the compliant header shape passes" 0 "$BASHCOV_STATUS"
  assert_contains "the allowed origin is echoed exactly" \
    "preflight echoes the exact origin" "$BASHCOV_STDOUT"
  assert_contains "Access-Control-Allow-Credentials is asserted" \
    "preflight returns Access-Control-Allow-Credentials: true" "$BASHCOV_STDOUT"
  assert_contains "the disallowed origin cannot read the response" \
    "preflight response is unreadable to the page" "$BASHCOV_STDOUT"

  # The pre-change configuration. The allowed-origin half alone would accept it,
  # which is exactly why the two origins' headers are compared.
  run_against_mock wildcard
  assert_status "a wildcard edge fails" 1 "$BASHCOV_STATUS"
  assert_contains "the wildcard is named on the allowed responses" \
    "allowed preflight response carries a wildcard Access-Control-Allow-Origin" "$BASHCOV_STDOUT"
  assert_contains "the wildcard is caught on the disallowed responses too" \
    "disallowed POST response carries a wildcard Access-Control-Allow-Origin" "$BASHCOV_STDOUT"
  assert_contains "the two origins are reported as indistinguishable" \
    "both origins receive the same Access-Control-Allow-Origin" "$BASHCOV_STDOUT"

  # Exact origin on the preflight, '*' on the POST — the response that carries
  # the body would still be readable from anywhere.
  run_against_mock split
  assert_status "a wildcard on the POST alone fails" 1 "$BASHCOV_STATUS"
  assert_contains "the POST wildcard is named" \
    "allowed POST response carries a wildcard Access-Control-Allow-Origin" "$BASHCOV_STDOUT"

  # Exact origin, but credentials silently dropped at runtime.
  run_against_mock no-creds
  assert_status "a missing Access-Control-Allow-Credentials fails" 1 "$BASHCOV_STATUS"
  assert_contains "the missing credentials header is named" \
    "Access-Control-Allow-Credentials: '<absent>'" "$BASHCOV_STDOUT"

  # Echoing whatever origin asks allows everyone without a literal '*'.
  run_against_mock echo-any
  assert_status "an edge that echoes any origin fails" 1 "$BASHCOV_STATUS"
  assert_contains "the echoed disallowed origin is named" \
    "the origin is echoed back" "$BASHCOV_STDOUT"
fi

# No gateway at all must be NOT RUN (2), never a pass and never a failure.
bashcov_run "$RUNTIME_CHECK" "http://127.0.0.1:1" "$ALLOWED" "$DISALLOWED"
assert_status "an unreachable gateway exits 2 (NOT RUN), not 0 or 1" 2 "$BASHCOV_STATUS"
assert_contains "an unreachable gateway is reported as NOT RUN" \
  "RESULT: NOT RUN" "$BASHCOV_STDOUT"
assert_contains "an unreachable gateway states AC-16 is not discharged" \
  "AC-16 (FR-11) is NOT discharged by this run" "$BASHCOV_STDOUT"

echo

# ---------------------------------------------------------------------------
# Coverage
# ---------------------------------------------------------------------------

echo "4. Line coverage of the guarded shell modules"

# The guards are small and wholly reachable from this suite, so the floor is set
# where a newly added unexercised branch shows up rather than where it is
# absorbed. Where python3 is unavailable the mock-edge group is skipped, and the
# runtime check is then reported without being gated — a skipped group must not
# be able to turn into a failing build.
COVERED_MODULES=("$HEADERS_LIB" "$CONFIG_GUARD")
if (( skipped == 0 )); then
  COVERED_MODULES+=("$RUNTIME_CHECK")
fi

BASHCOV_MIN_PERCENT="${BASHCOV_MIN_PERCENT:-90}"
coverage_ok=0
bashcov_report "$BASHCOV_LEDGER" "${COVERED_MODULES[@]}" || coverage_ok=1
if (( skipped > 0 )); then
  echo
  echo "  NOTE: $RUNTIME_CHECK is not gated on this run — the mock-edge group was skipped."
fi

if (( coverage_ok != 0 )); then
  echo
  echo "Uncovered statements:"
  for module in "${COVERED_MODULES[@]}"; do
    bashcov_uncovered "$BASHCOV_LEDGER" "$module"
  done
fi

echo
echo "Assertions: $assertions, failures: $failed, skipped: $skipped"

if (( failed > 0 )); then
  echo "RESULT: FAIL — $failed assertion(s) failed."
  exit 1
fi

if (( coverage_ok != 0 )); then
  echo "RESULT: FAIL — coverage below the required minimum:"
  printf '%s' "$BASHCOV_BELOW_DETAIL"
  exit 1
fi

echo "RESULT: PASS — the cross-origin guards behave as specified."
exit 0
