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
#   4. no `'*'` wildcard survives on ANY `allowedOrigins` entry;
#   4b. the origin's port is one Pacco.Web can actually bind on a developer
#      machine while the Compose backend is up — it is not a host port the
#      backend publishes, and it is not inside the platform's 5000-5009 block;
#   5. `allowCredentials`, `allowedMethods`, `allowedHeaders` and
#      `exposedHeaders` still hold their EXPECTED values — the values they
#      carry on the base ref of this change, restated here as literals. The
#      guard does not diff against the ref, so a deliberate future edit to any
#      of those keys is expected to update the literals below in the same
#      commit; the failure message names the expected value for that reason;
#   6. no logout, sign-out or revoke route is introduced, since logout is a
#      client-side session discard only and the edge's JWT validation and
#      revocation behaviour are untouched;
#   6b. no route serves or proxies Pacco.Web — the client is a standalone
#      browser process, never served by Ntrada (ADR-021 §5 rules 1 and 2).
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
# The guard is covered by `scripts/tests/cors-guard.test.sh`, which runs it over
# mutated copies of the configuration — a restored wildcard, a second origin, a
# flipped `allowCredentials`, an injected logout route — and asserts each one is
# caught. `PACCO_NTRADA_DIR` exists so that suite can point the guard at a
# throw-away copy; in normal use it is unset and the guard reads this checkout.
#
# Exit codes: 0 = all checks passed, 1 = at least one check failed.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${PACCO_NTRADA_DIR:-$ROOT/src/Pacco.APIGateway}"
FILES=(ntrada.yml ntrada.docker.yml ntrada-async.yml ntrada-async.docker.yml)

failures=0

# Host ports the Pacco Docker Compose backend publishes, and which Pacco.Web
# therefore cannot bind while the backend is running.
#
# Per ADR-021 §4, Pacco.Web "runs as a local process beside the Compose backend"
# and has "no port allocation in the platform's 5000-5009 block". A port that
# collides with the backend defeats the first half of that: the client's dev
# server is pinned (`strictPort: true` in Pacco.Web/vite.config.ts) precisely so
# the allowed origin cannot silently stop matching, so a collision is not a
# fallback — it is a dev server that refuses to start.
#
# The list is transcribed from hianshul100_Pacco/compose/infrastructure.yml and
# compose/services.yml, which are the two files the README's runbook starts. It
# is a literal here for the same reason the CORS values in check 5 are literals:
# this repository does not have the Pacco checkout to read, and a deliberate
# change to the Compose port map is expected to update this list in the same
# change.
#
# 3000 grafana · 5341 seq · 5672/15672/15692 rabbitmq · 6379 redis ·
# 8200 vault · 8500 consul · 9090 prometheus · 9411/14268/16686 jaeger ·
# 9998/9999 fabio · 27017 mongo
COMPOSE_HOST_PORTS=(3000 5341 5672 6379 8200 8500 9090 9411 9998 9999 14268 15672 15692 16686 27017)

# The platform's own service block. ADR-021 §6.3 item 1 keeps Pacco.Web out of
# it; the gateway itself is 5000 (compose/services.yml:11).
PLATFORM_PORT_BLOCK_START=5000
PLATFORM_PORT_BLOCK_END=5009

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

  # 4. No wildcard survives — on ANY entry, not only the first. Check 2 counts
  #    the entries but a two-entry list whose SECOND entry is '*' would
  #    otherwise be reported as wildcard-free, which is the one thing this guard
  #    exists to make impossible to say.
  wildcard_found=0
  for candidate in "${origins[@]:-}"; do
    [[ "$candidate" == "*" ]] && wildcard_found=1
  done
  if (( wildcard_found == 1 )); then
    fail "$name still allows the '*' wildcard origin"
  else
    pass "$name retains no wildcard origin"
  fi

  # 4b. The origin must be bindable beside the running Compose backend.
  origin_port="${origin##*:}"
  if [[ "$origin_port" =~ ^[0-9]+$ ]]; then
    collides=0
    for reserved in "${COMPOSE_HOST_PORTS[@]}"; do
      [[ "$origin_port" == "$reserved" ]] && collides=1
    done
    if (( collides == 1 )); then
      fail "$name origin '$origin' uses port $origin_port, which the Pacco Compose backend already publishes on the host — Pacco.Web cannot bind it while the backend is up"
    elif (( origin_port >= PLATFORM_PORT_BLOCK_START && origin_port <= PLATFORM_PORT_BLOCK_END )); then
      fail "$name origin '$origin' uses port $origin_port, inside the platform's ${PLATFORM_PORT_BLOCK_START}-${PLATFORM_PORT_BLOCK_END} service block, which Pacco.Web has no allocation in (ADR-021 §4)"
    else
      pass "$name origin port $origin_port is free of the Compose backend and of the ${PLATFORM_PORT_BLOCK_START}-${PLATFORM_PORT_BLOCK_END} block"
    fi
  fi

  # 5. Sibling CORS keys still hold their expected values. These are literals,
  #    not a diff against the base ref: a deliberate change to any of them is
  #    expected to update the literal here in the same commit, so the failure
  #    message names what was expected rather than claiming the key "changed".
  if [[ "$block" == *"allowCredentials: true"* ]]; then
    pass "$name leaves allowCredentials true"
  else
    fail "$name allowCredentials differs from the expected value 'true'"
  fi

  if [[ "$block" == *$'allowedMethods:\n      - post\n      - put\n      - delete'* ]]; then
    pass "$name leaves allowedMethods at its expected value"
  else
    fail "$name allowedMethods differs from the expected value (post, put, delete)"
  fi

  # `allowedHeaders: '*'` is a DIFFERENT key from `allowedOrigins` and its
  # wildcard is expected to survive; narrowing it is not this change's business.
  if [[ "$block" == *$'allowedHeaders:\n      - \'*\''* ]]; then
    pass "$name leaves allowedHeaders at its expected value"
  else
    fail "$name allowedHeaders differs from the expected value ('*')"
  fi

  if [[ "$block" == *$'exposedHeaders:\n      - Request-ID\n      - Resource-ID\n      - Trace-ID\n      - Total-Count'* ]]; then
    pass "$name leaves exposedHeaders at its expected value"
  else
    fail "$name exposedHeaders differs from the expected value (Request-ID, Resource-ID, Trace-ID, Total-Count)"
  fi

  # 6. No logout / revoke route, and no change to JWT validation.
  content="$(cat "$CONFIG_DIR/$name")"
  if grep -Eiq 'upstream:[[:space:]]*/?(logout|sign-out|signout|revoke)' "$CONFIG_DIR/$name" \
    || grep -Eiq 'revoke-(access|refresh)-token' "$CONFIG_DIR/$name"; then
    fail "$name introduces a logout or revoke route"
  else
    pass "$name adds no logout or revoke route"
  fi

  # 6b. The gateway must not serve Pacco.Web. Per ADR-021 §5 rules 1 and 2 the
  #     client is a standalone browser process: it is never bundled into a
  #     backend service image and is never served by Ntrada, which is why the
  #     edge names it as a cross-ORIGIN caller in the first place. A route that
  #     proxied or served the client would make the whole CORS change inert.
  if grep -Eiq '(downstream|module|use):[[:space:]]*.*(pacco[-.]?web|web-?client|spa|static[-_]?files?)' "$CONFIG_DIR/$name"; then
    fail "$name serves or proxies Pacco.Web from the gateway; the client is a standalone browser process (ADR-021 §5 rules 1 and 2)"
  else
    pass "$name serves no Pacco.Web content from the gateway"
  fi

  if [[ "$content" == *$'jwt:\n    issuerSigningKey'* ]]; then
    pass "$name leaves the jwt extension in place and unreordered"
  else
    fail "$name jwt extension differs from the expected shape (jwt: followed by issuerSigningKey)"
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
