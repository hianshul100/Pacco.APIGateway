#!/bin/bash
#
# Line-coverage measurement for the shell modules in this repository.
#
# This repository has no test project and no language toolchain beyond .NET, so
# none of the usual coverage tools are available to it and none can be added
# without pulling in a runtime this build does not otherwise need. The shell
# modules being guarded need `bash` and `awk` only, and `bash` can report its
# own executed lines, so coverage is measured with `bash -x` and a `PS4` that
# stamps every executed command with its source file and line number.
#
# Two pieces are needed:
#
#   * bashcov_run       — executes a script under xtrace and appends the
#                         stamps it emitted to an accumulating ledger;
#   * bashcov_report    — turns the ledger into a per-file percentage.
#
# `bashcov_statements` decides which lines could have been executed. A line
# counts when it starts a command; the lines that continue one — a trailing
# `\`, `|`, `&&` or `||`, or an unterminated quoted string such as the embedded
# awk programs — are folded into the line that starts it, because xtrace stamps
# a multi-line command once. Blank lines, comments, function headers and the
# bare block keywords bash never stamps (`fi`, `done`, `else`, `do`, `then`,
# `esac`, `;;`, braces, `case` patterns) are excluded for the same reason.
#
# Sourced, not executed.

# Ledger of `@@<file>:<line>@@` stamps collected so far. The caller sets this
# before the first bashcov_run; it is appended to, never truncated here.
BASHCOV_LEDGER="${BASHCOV_LEDGER:-}"

# Accumulates one line per module that fell below the required percentage, so
# the caller can print the reason alongside the table.
BASHCOV_BELOW_DETAIL=""

# Runs a script under xtrace, recording covered lines.
#
# Usage: bashcov_run <script> [args...]
# Sets:  BASHCOV_STATUS, BASHCOV_STDOUT
bashcov_run() {
  local script="$1"
  shift

  local trace
  trace="$(mktemp)"

  # Errexit is suspended around the call so a deliberately failing fixture does
  # not abort the suite — the status is the thing under assertion — and then
  # restored to whatever the caller had, rather than being switched on.
  local errexit_was_on=0
  case "$-" in *e*) errexit_was_on=1 ;; esac
  set +e
  BASHCOV_STDOUT="$(PS4='@@${BASH_SOURCE}:${LINENO}@@ ' bash -x "$script" "$@" 2>"$trace")"
  BASHCOV_STATUS=$?
  if (( errexit_was_on )); then
    set -e
  fi

  if [[ -n "$BASHCOV_LEDGER" ]]; then
    grep -o '@@[^@]*@@' "$trace" >>"$BASHCOV_LEDGER" 2>/dev/null || true
  fi
  rm -f "$trace"
}

# Prints `<line> <owner>` for every line of <file>, where <owner> is the line
# that starts the command this line belongs to, or 0 when the line is not part
# of a command at all.
#
# The indirection matters: bash stamps a multi-line command once, at the line
# where it ENDS, so a stamp has to be resolved back to the line that started it
# before it can be counted.
bashcov_line_map() {
  awk '
    function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
    function ltrim(s) { sub(/^[ \t]+/, "", s); return s }

    BEGIN { in_sq = 0; in_dq = 0; cont = 0; owner = 0 }

    {
      raw = $0

      if (!in_sq && !in_dq && !cont) {
        t = rtrim(ltrim(raw))
        candidate = 1
        if (t == "" || substr(t, 1, 1) == "#") candidate = 0
        else if (t == "fi" || t == "done" || t == "else" || t == "do" ||
                 t == "then" || t == "esac" || t == ";;" || t == "{" ||
                 t == "}" || t == "};" || t == ")" || t == ");;") candidate = 0
        # A function header (`name() {`) is not stamped; its body is.
        else if (t ~ /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) candidate = 0
        # A `case` pattern arm (`"develop")`) is not stamped either.
        else if (t ~ /\)$/ && t !~ /[;&|]/ && t !~ /^(if|elif|while|until|for|case)[ \t(]/ && t !~ /\$\(/ && t !~ /\(\(/) candidate = 0

        owner = candidate ? NR : 0
      }

      print NR, owner

      # Walk the line to learn whether it leaves a quoted string open and where
      # a comment starts, so neither confuses the continuation test below.
      code = ""
      i = 1
      n = length(raw)
      while (i <= n) {
        c = substr(raw, i, 1)
        if (in_sq) {
          if (c == "'"'"'") in_sq = 0
          code = code c
        } else if (in_dq) {
          if (c == "\\") { code = code c; i++; if (i <= n) code = code substr(raw, i, 1) }
          else { if (c == "\"") in_dq = 0; code = code c }
        } else {
          if (c == "'"'"'") { in_sq = 1; code = code c }
          else if (c == "\"") { in_dq = 1; code = code c }
          else if (c == "\\") { code = code c; i++; if (i <= n) code = code substr(raw, i, 1) }
          else if (c == "#" && (i == 1 || substr(raw, i - 1, 1) ~ /[ \t;&|(]/)) break
          else code = code c
        }
        i++
      }

      code = rtrim(code)
      cont = (in_sq || in_dq || code ~ /\\$/ || code ~ /[|&]$/ || code ~ /&&$/ || code ~ /\|\|$/)
    }
  ' "$1"
}

# Prints, one per line, the line numbers of <file> that start a command.
bashcov_statements() {
  bashcov_line_map "$1" | awk '$2 != 0 && $1 == $2 { print $1 }'
}

# Prints the statement lines of <file> that the ledger shows as executed.
bashcov_covered() { # <ledger> <file>
  local ledger="$1" file="$2" base
  base="$(basename "$file")"

  # A stamp reads `@@<path>:<line>@@`. Resolve each one through the owner map
  # so a multi-line command counts against the line that starts it.
  sed -n "s|^@@.*[/]${base}:\\([0-9][0-9]*\\)@@\$|\\1|p" "$ledger" 2>/dev/null \
    | sort -un \
    | awk 'NR == FNR { owner[$1] = $2; next } ($1 in owner) && owner[$1] != 0 { print owner[$1] }' \
        <(bashcov_line_map "$file") - \
    | sort -un
}

# Prints a coverage table for the given files and returns 1 if any file is
# below BASHCOV_MIN_PERCENT (default 80).
#
# Usage: bashcov_report <ledger> <file>...
bashcov_report() {
  local ledger="$1"
  shift
  local min="${BASHCOV_MIN_PERCENT:-80}"
  local below=0
  local file total covered percent

  printf '%-30s %8s %8s %9s\n' 'MODULE' 'STMTS' 'COVERED' 'COVERAGE'
  for file in "$@"; do
    total="$(bashcov_statements "$file" | wc -l | tr -d ' ')"
    if (( total == 0 )); then
      printf '%-30s %8s %8s %9s\n' "$(basename "$file")" 0 0 'n/a'
      continue
    fi

    covered="$(
      comm -12 <(bashcov_covered "$ledger" "$file" | sort -u) \
               <(bashcov_statements "$file" | sort -u) \
        | wc -l | tr -d ' '
    )"
    percent=$(( covered * 100 / total ))
    printf '%-30s %8s %8s %8s%%\n' "$(basename "$file")" "$total" "$covered" "$percent"
    if (( percent < min )); then
      below=$((below + 1))
      BASHCOV_BELOW_DETAIL+="  $(basename "$file"): ${percent}% < ${min}% required"$'\n'
    fi
  done

  if (( below > 0 )); then
    return 1
  fi
  return 0
}

# Prints the statement lines of <file> that the ledger does NOT show as
# executed, with their text — so a shortfall can be acted on rather than
# merely reported.
bashcov_uncovered() { # <ledger> <file>
  local ledger="$1" file="$2" line
  comm -23 <(bashcov_statements "$file" | sort -u) \
           <(bashcov_covered "$ledger" "$file" | sort -u) \
    | sort -n \
    | while read -r line; do
        printf '  %s:%s: %s\n' "$(basename "$file")" "$line" "$(sed -n "${line}p" "$file")"
      done
}
