#!/usr/bin/env bash
# fm-jq-lib.sh - repo-owned jq invocation defense for Windows (Git Bash / MSYS).
#
# Why this exists (evidence: the wincompat scan, issues 7+8):
#   - A native Windows jq (e.g. winget jq 1.8.2) terminates every output line
#     with CRLF, so each value read from `jq -r` gains a trailing CR and every
#     bash-side comparison, case match, or numeric test on that value silently
#     fails. Before this library the only defense was an unversioned per-machine
#     ~/bin/jq wrapper, and its `tr -d '\r'` also deleted legitimate embedded
#     CRs inside values.
#   - The MSYS runtime rewrites POSIX-path arguments handed to any native
#     binary at the process boundary, so `jq -n --arg p /tmp/foo '$p'` embeds
#     "C:/Users/.../Temp/foo" inside the produced JSON while bash-side
#     consumers keep comparing the POSIX spelling.
#
# Contract for fm scripts (bin/*.sh, bin/backends/*.sh):
#   - Call `fm_jq` wherever the script would call `jq`; never invoke bare jq
#     except `command -v jq` presence checks.
#   - Never pass a file PATH as a jq argument (input operand, --slurpfile,
#     --rawfile, -f/--from-file, --argfile): with MSYS argument conversion
#     disabled a native jq cannot open a POSIX spelling. Feed a single input by
#     redirection (`fm_jq ... < "$file"`) and wrap an unavoidable path argument
#     in `$(fm_jq_path "$file")`, which prints a spelling every jq build opens.
#
# What fm_jq does, by resolved mode (memoized in exported FM_JQ_MODE):
#   plain      - non-Windows: exec jq untouched. Zero behavior change.
#   excl       - Windows, jq emits clean LF: run jq with MSYS2_ARG_CONV_EXCL='*'
#                so no argument is path-converted (verified to preserve
#                /tmp/foo in --arg values). Harmless for an MSYS-built jq,
#                which never receives argument conversion anyway.
#   excl-strip - Windows, the resolved jq PROVABLY emits CRLF (probed once via
#                fm_jq_emits_crlf): same as excl, plus stdout is filtered
#                through `sed 's/\r$//'`, stripping LINE-FINAL CRs only.
#                Embedded CRs inside a value survive; a deliberate tr -d '\r'
#                is exactly what this library replaces. jq's own exit status is
#                preserved through the pipe (PIPESTATUS), and stderr passes
#                through untouched.
# The probe result is exported so child fm scripts skip re-probing; unset
# FM_JQ_MODE to force re-resolution (tests do).
#
# fm_jq_emits_crlf probes the RESOLVED jq on PATH and is also the bootstrap
# diagnostic primitive: bin/fm-bootstrap.sh reports a CRLF-emitting jq loudly
# as an incompatible build, because everything NOT routed through fm_jq
# (crewmate project work, ad-hoc shells, other tools) stays exposed.
#
# Sourcing is idempotent; this file only defines functions.

# fm_jq_emits_crlf: succeed iff the resolved jq terminates raw output with
# CRLF. The probe must inspect BYTES through od: Git Bash's `$(...)` trims a
# TRAILING CRLF, so capturing jq's output directly would read clean even from
# a CRLF-emitting jq (interior line endings, read loops, and multi-line
# captures still carry the corrupting CRs - verified on winget jq 1.8.2).
# A missing or broken jq probes clean: presence is the caller's own check, and
# this probe must never convert "jq absent" into "jq incompatible".
fm_jq_emits_crlf() {
  local probe
  command -v jq >/dev/null 2>&1 || return 1
  probe=$(command jq -rn '"x"' 2>/dev/null | od -An -c | tr -d ' \n') || return 1
  [ "$probe" = 'x\r\n' ]
}

# fm_jq_resolve_mode: compute and export FM_JQ_MODE (plain|excl|excl-strip).
fm_jq_resolve_mode() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      if fm_jq_emits_crlf; then
        FM_JQ_MODE=excl-strip
      else
        FM_JQ_MODE=excl
      fi
      ;;
    *) FM_JQ_MODE=plain ;;
  esac
  export FM_JQ_MODE
}

# fm_jq: drop-in jq invocation with the platform defense described above.
fm_jq() {
  local rc
  case "${FM_JQ_MODE:-}" in plain|excl|excl-strip) ;; *) fm_jq_resolve_mode ;; esac
  case "$FM_JQ_MODE" in
    excl)
      MSYS2_ARG_CONV_EXCL='*' command jq "$@"
      ;;
    excl-strip)
      MSYS2_ARG_CONV_EXCL='*' command jq "$@" | sed 's/\r$//'
      rc=${PIPESTATUS[0]}
      return "$rc"
      ;;
    *)
      command jq "$@"
      ;;
  esac
}

# fm_jq_path: print a spelling of <path> that the resolved jq can open when it
# must be passed as an ARGUMENT (--slurpfile etc.). On Windows that is the
# mixed C:/ spelling (cygpath -m), which both native and MSYS-built jq open;
# elsewhere the path is printed unchanged.
fm_jq_path() {
  case "${FM_JQ_MODE:-}" in plain|excl|excl-strip) ;; *) fm_jq_resolve_mode ;; esac
  if [ "$FM_JQ_MODE" != plain ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m -- "$1"
  else
    printf '%s\n' "$1"
  fi
}
