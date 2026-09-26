#!/bin/bash
#
# Edge cross-origin configuration guard — AC-15 / FR-11.
#
# Asserts, over the four `ntrada*.yml` files in this repository and with no
# dependency on any other checkout, that:
#
#   1. the `extensions.cors` block is byte-identical in all four files;
#   2. `allowedOrigins` holds EXACTLY ONE entry;
#   3. that entry is a concrete origin carrying scheme, host and port;
#   4. no `'*'` wildcard survives in `allowedOrigins`;
#   5. `allowCredentials`, `allowedMethods`, `allowedHeaders` and
#      `exposedHeaders` are unchanged from the base ref;
#   6. no logout, sign-out or revoke route is introduced, since logout is a
#      client-side session discard only and the edge's JWT validation and
#      revocation behaviour are untouched.
#
# The guard lives HERE, in the repository that owns the files, so that an edit
# to any `ntrada*.yml` is protected without relying on a sibling checkout being
# present. `Pacco.Web` carries the matching client-side assertion; neither is a
# substitute for the other.
#
# Per ADR-004 §2 obligation 1 the routing configuration is a reviewed
# architectural artifact, and per ADR-021 §5 rule 4 the edge names its browser
# caller exactly and all four configuration files stay identical.
#
# Exit codes: 0 = all checks passed, 1 = at least one check failed.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$ROOT/src/Pacco.APIGateway"
FILES=(ntrada.yml ntrada.docker.yml ntrada-async.yml ntrada-async.docker.yml)

failures=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures + 1)); }

# Prints the `extensions.cors` block verbatim, byte for byte.
#
# The block ends at the next sibling key under `extensions:` — a line indented
# by exactly two spaces — not at the next column-zero line, because everything
# under `extensions:` is nested and the sibling `tracing.udpHost` legitimately
# differs between the plain and `.docker` variants.
cors_block() {
  awk '
    /^  cors:$/          { inside = 1; print; next }
    inside && /^  [^ ]/  { inside = 0 }
    inside               { print }
  ' "$1"
}

# Prints one `allowedOrigins` entry per line, quotes stripped.
allowed_origins() {
  cors_block "$1" | awk '
    /^    allowedOrigins:$/ { inside = 1; next }
    inside && /^      - /   { gsub(/^      - /, ""); gsub(/^'"'"'|'"'"'$/, ""); print; next }
    inside                  { inside = 0 }
  '
}

echo "Edge cross-origin configuration guard (AC-15 / FR-11)"
echo

for name in "${FILES[@]}"; do
  if [[ ! -f "$CONFIG_DIR/$name" ]]; then
    fail "$name is missing from $CONFIG_DIR"
  fi
done

if (( failures > 0 )); then
  echo
  echo "RESULT: FAIL — $failures check(s) failed."
  exit 1
fi

# 1. Four-file byte identity of the cors block.
reference="$(cors_block "$CONFIG_DIR/${FILES[0]}")"
identical=1
for name in "${FILES[@]:1}"; do
  if [[ "$(cors_block "$CONFIG_DIR/$name")" != "$reference" ]]; then
    fail "$name cors block differs from ${FILES[0]}"
    identical=0
  fi
done
if (( identical == 1 )); then
  pass "cors block is byte-identical across all four ntrada*.yml files"
fi

# The single origin the four files agree on, used for reporting below.
expected_origin="$(allowed_origins "$CONFIG_DIR/${FILES[0]}" | head -n 1)"

for name in "${FILES[@]}"; do
  block="$(cors_block "$CONFIG_DIR/$name")"
  mapfile -t origins < <(allowed_origins "$CONFIG_DIR/$name")

  # 2. Exactly one allowed origin.
  if (( ${#origins[@]} == 1 )); then
    pass "$name allows exactly one origin"
  else
    fail "$name allows ${#origins[@]} origin(s); exactly 1 is required"
  fi

  origin="${origins[0]:-}"

  # 3. Concrete origin: scheme, host and port.
  if [[ "$origin" =~ ^https?://[^/:[:space:]]+:[0-9]+$ ]]; then
    pass "$name names a concrete origin with scheme, host and port ($origin)"
  else
    fail "$name origin '$origin' is not a concrete scheme://host:port origin"
  fi

  # 4. No wildcard survives.
  if [[ "$origin" == "*" ]]; then
    fail "$name still allows the '*' wildcard origin"
  else
    pass "$name retains no wildcard origin"
  fi

  # 5. Sibling CORS keys unchanged from the base ref.
  if [[ "$block" == *"allowCredentials: true"* ]]; then
    pass "$name leaves allowCredentials true"
  else
    fail "$name changed allowCredentials"
  fi

  if [[ "$block" == *$'allowedMethods:\n      - post\n      - put\n      - delete'* ]]; then
    pass "$name leaves allowedMethods untouched"
  else
    fail "$name changed allowedMethods"
  fi

  # `allowedHeaders: '*'` is a DIFFERENT key from `allowedOrigins` and its
  # wildcard is expected to survive; narrowing it is not this change's business.
  if [[ "$block" == *$'allowedHeaders:\n      - \'*\''* ]]; then
    pass "$name leaves allowedHeaders untouched"
  else
    fail "$name changed allowedHeaders"
  fi

  if [[ "$block" == *$'exposedHeaders:\n      - Request-ID\n      - Resource-ID\n      - Trace-ID\n      - Total-Count'* ]]; then
    pass "$name leaves exposedHeaders untouched"
  else
    fail "$name changed exposedHeaders"
  fi

  # 6. No logout / revoke route, and no change to JWT validation.
  content="$(cat "$CONFIG_DIR/$name")"
  if grep -Eiq 'upstream:[[:space:]]*/?(logout|sign-out|signout|revoke)' "$CONFIG_DIR/$name" \
    || grep -Eiq 'revoke-(access|refresh)-token' "$CONFIG_DIR/$name"; then
    fail "$name introduces a logout or revoke route"
  else
    pass "$name adds no logout or revoke route"
  fi

  if [[ "$content" == *$'jwt:\n    issuerSigningKey'* ]]; then
    pass "$name leaves the jwt extension in place and unreordered"
  else
    fail "$name altered the jwt extension"
  fi
done

echo
if (( failures > 0 )); then
  echo "RESULT: FAIL — $failures check(s) failed."
  exit 1
fi

echo "RESULT: PASS — allowed origin is '$expected_origin' in all four files."
echo
echo "NOTE: this guard is the STATIC half of FR-11 (AC-15) only. The runtime half"
echo "      (AC-16) is ./scripts/verify-cors-runtime.sh and needs a running"
echo "      gateway; a passing static guard is NOT evidence that the browser path"
echo "      works."
exit 0
