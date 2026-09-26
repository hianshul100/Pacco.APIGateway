#!/bin/bash
#
# Response-header helpers shared by `scripts/verify-cors-runtime.sh` and the
# fixture-driven suite in `scripts/tests/`.
#
# This file is sourced, never executed. It defines functions only and has no
# side effects, so the suite can exercise the parsing in isolation from any
# network call — the reason the parsing lives here rather than inline in the
# runtime check.

# Prints the value of a response header, matched case-insensitively, or the
# empty string when the header is absent.
#
# HTTP field names are case-insensitive (RFC 9110 §5.1) and real servers emit
# `Access-Control-Allow-Origin`, not the lower-cased spelling. The match is
# therefore done with awk's `tolower()` on an explicit prefix and NOT with
# `IGNORECASE`: that variable is a GNU awk extension which mawk — the default
# `awk` on Debian and Ubuntu — parses and then silently ignores, so an
# `IGNORECASE`-based pattern reports every header as absent.
#
# The `:` is part of the compared prefix, so `Access-Control-Allow-Origin-Foo:`
# does not satisfy a lookup for `Access-Control-Allow-Origin`.
#
# Only header sections are scanned — a section opens on a status line and closes
# on the blank line before the body — so a response body that happens to spell
# the header name cannot be read as a header. The LAST matching section wins,
# which is the final response when `curl -i` has printed a `100 Continue` or a
# redirect preamble ahead of it.
#
# Usage: http_header_value <header-name> <raw-response>
http_header_value() {
  local name="$1"
  local response="$2"

  printf '%s' "$response" \
    | tr -d '\r' \
    | awk -v want="$name" '
        BEGIN { want = tolower(want) ":"; n = length(want); in_headers = 0; found = "" }
        /^HTTP\// { in_headers = 1; next }
        in_headers && $0 == "" { in_headers = 0; next }
        in_headers && tolower(substr($0, 1, n)) == want {
          value = $0
          sub(/^[^:]*:[ \t]*/, "", value)
          sub(/[ \t]+$/, "", value)
          found = value
        }
        END { if (found != "") print found }
      '
}

# Prints the `Access-Control-Allow-Origin` value of a response, or the empty
# string when the header is absent. This value is what a browser compares
# against the page origin to decide whether the response may be read.
acao() {
  http_header_value 'Access-Control-Allow-Origin' "$1"
}

# Prints the `Access-Control-Allow-Credentials` value of a response, or the
# empty string when absent. An exact origin paired with this header set to
# `true` is the combination FR-11 exists to produce; the Fetch Standard forbids
# pairing credentials with a `*` origin, which is why the wildcard had to go.
acac() {
  http_header_value 'Access-Control-Allow-Credentials' "$1"
}
