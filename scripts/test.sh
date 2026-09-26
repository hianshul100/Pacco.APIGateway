#!/bin/bash
set -e

SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# The edge cross-origin guards need no toolchain — plain `bash` and `awk` — so
# they run first and a regression in any `ntrada*.yml` fails the build even
# though this repository has no test project (AC-15 / FR-11, ADR-004 §2
# obligation 1). The suite tests the guards themselves and measures their
# coverage; the guard proper asserts the configuration.
"$SCRIPTS_DIR/tests/cors-guard.test.sh"
echo
"$SCRIPTS_DIR/verify-cors-config.sh"
echo

# `dotnet test` is run only when a test project actually exists.
#
# Pacco.APIGateway.sln declares exactly one project — src/Pacco.APIGateway,
# a Microsoft.NET.Sdk.Web project with no Microsoft.NET.Test.Sdk reference — so
# `dotnet test` has nothing to run and cannot report success. Invoking it
# unconditionally would leave a permanently failing step in which the guards'
# own result is indistinguishable from the missing-test-project failure, which
# is worse than no signal at all. Adding a test project for the gateway is a
# separate piece of work and is out of this change's scope.
test_projects="$(find "$ROOT/src" "$ROOT/tests" -name '*Tests.csproj' -o -name '*.Tests.csproj' 2>/dev/null || true)"

if [[ -n "$test_projects" ]]; then
  dotnet test
else
  echo "No test project is declared in this repository — skipping 'dotnet test'."
  echo "The cross-origin guards above are this build's test signal."
fi

# The runtime half of FR-11 (AC-16) is ./scripts/verify-cors-runtime.sh. It is
# NOT invoked here because it needs the Docker Compose stack, which CI does not
# start. Run it by hand against a running gateway; until it is run, AC-16 is
# reported as NOT RUN, never as passed (LOW_LEVEL_SPEC-13652-wave-1.md §L.6.2).
