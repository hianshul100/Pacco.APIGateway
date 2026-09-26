#!/bin/bash
set -e

# The edge cross-origin configuration guard runs BEFORE the .NET tests and needs
# no toolchain, so a regression in any `ntrada*.yml` fails the build even where
# no test project exists (AC-15 / FR-11, ADR-004 §2 obligation 1).
"$(dirname "${BASH_SOURCE[0]}")/verify-cors-config.sh"

dotnet test

# The runtime half of FR-11 (AC-16) is ./scripts/verify-cors-runtime.sh. It is
# NOT invoked here because it needs the Docker Compose stack, which CI does not
# start. Run it by hand against a running gateway; until it is run, AC-16 is
# reported as NOT RUN, never as passed (LOW_LEVEL_SPEC-13652-wave-1.md §L.6.2).
