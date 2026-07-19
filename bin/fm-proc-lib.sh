#!/usr/bin/env bash
# fm-proc-lib.sh - shared process-inspection primitives. Sourced, never executed.
#
# Owns the cross-platform process-detection strategy first built in
# bin/fm-lock.sh. Two independent platform facts drive it:
#   - `ps` portability: MSYS ps (Git Bash / Cygwin) has no -o support at all
#     (any `ps -o ...` exits 1), so every ps -o call site is dead on Windows.
#     The lib probes `ps -o comm=` once per process (fm_proc_ps_o_ok) and
#     prefers the portable ps walk whenever the ps on PATH supports it - real
#     procps on Linux/macOS and the fake ps stubs the test suites install both
#     qualify.
#   - Native-process visibility: even a working MSYS-side ps only sees MSYS
#     processes, while harnesses run as NATIVE Windows processes (claude.exe)
#     the MSYS ancestry never reaches - its view bottoms out at ppid 1. The
#     Windows fallback therefore climbs the Cygwin procfs
#     (/proc/<pid>/{exename,winpid,ppid,cmdline}) to the topmost MSYS process,
#     then follows ParentProcessId through one CIM query per walk. Pids it
#     yields are NATIVE Windows pids, and liveness on them must be answered by
#     CIM too: MSYS kill -0 operates on MSYS pids and would misjudge a native
#     one. MSYS emulates fork/exec with transient stub processes, so a nested
#     shell's NATIVE parent pid may already be dead while /proc/<pid>/ppid
#     tracks the logical parent correctly; only the topmost MSYS process
#     (ppid 1) has a trustworthy native ancestry.
#
# Script-shim harnesses (a harness that is itself a bash/sh script, e.g. a
# wrapper named `grok`): on POSIX the comm of a shebang process is the script
# name and the plain name match works; on Windows both exename and CIM Name
# report only bash, so the shim is recognized by parsing the interpreter's argv
# for its script path and matching THAT against the harness names. A shell
# running a -c command STRING is never treated as a shim: tool-call shells
# carry arbitrary text (frequently containing harness names) in exactly that
# form, and matching them would hand a transient shell's pid to the lock.
#
# API (all callable under set -u; none require or assume set -e):
#   fm_proc_harness_pid          print the pid of the nearest harness ancestor
#                                (a native Windows pid on the Windows fallback)
#   fm_proc_harness_name         print which harness the ancestry runs on:
#                                claude|codex|opencode|pi|grok; fail when none
#   fm_proc_holder_alive PID     is PID a live process that looks like a harness
#   fm_proc_pid_in_ancestry PID  is PID (MSYS or native spelling) this process
#                                or one of its ancestors
#   fm_proc_cmdline PID          print PID's command line (procfs, then ps)
#   fm_proc_pgid PID             print PID's process group id; rc 1 when
#                                unavailable
# Consumers: fm-lock.sh, fm-harness.sh, fm-sessionstart-nudge.sh,
# fm-afk-start.sh, fm-watch.sh.

# Known harness command names; extend when a new adapter is verified.
FM_PROC_HARNESS_RE='claude|codex|opencode|grok|^pi$'

case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) FM_PROC_WINDOWS=1 ;;
  *) FM_PROC_WINDOWS=0 ;;
esac

# Does the ps on PATH support -o (procps, BSD ps, or a test fake)? Probed once
# per process; MSYS ps rejects -o with exit 1.
fm_proc_ps_o_ok() {
  if [ -z "${FM_PROC_PS_O_OK:-}" ]; then
    if ps -o comm= -p $$ >/dev/null 2>&1; then FM_PROC_PS_O_OK=0; else FM_PROC_PS_O_OK=1; fi
  fi
  return "$FM_PROC_PS_O_OK"
}

# Resolve powershell.exe even under a restricted PATH (test fixtures and
# watcher children pin PATH to a few dirs that never include System32).
fm_proc_powershell() {
  local sysroot cand
  if command -v powershell.exe >/dev/null 2>&1; then
    printf 'powershell.exe\n'
    return 0
  fi
  sysroot=$(cygpath -u "${SYSTEMROOT:-C:\\Windows}" 2>/dev/null) || return 1
  cand="$sysroot/System32/WindowsPowerShell/v1.0/powershell.exe"
  [ -x "$cand" ] || return 1
  printf '%s\n' "$cand"
}

# Does TEXT name a harness? The regex covers the plain names; the extra case
# arms accept a `pi` that only appears as a word or path tail inside an
# interpreter command line (the anchored ^pi$ cannot match there).
fm_proc_text_names_harness() {
  printf '%s' "$1" | grep -qE "$FM_PROC_HARNESS_RE" && return 0
  case " $1 " in
    *" pi "*|*"/pi "*) return 0 ;;
  esac
  return 1
}

# Print the script path an interpreter process is running, parsed from a
# NUL-separated cmdline file: argv0 (the interpreter) is skipped, option words
# are skipped, and the first remaining word is the script. A single-dash
# option cluster containing "c" aborts: -c/-lc shells run inline command
# strings, which carry arbitrary text and must never be mistaken for a script
# shim. Long options (--norc, --posix) never introduce a command string.
fm_proc_shim_script() {
  local file=$1 word first=1
  [ -r "$file" ] || return 1
  while IFS= read -r -d '' word; do
    if [ "$first" = 1 ]; then
      first=0
      continue
    fi
    case "$word" in
      --*) continue ;;
      -*c*) return 1 ;;
      -*) continue ;;
      *) printf '%s\n' "$word"; return 0 ;;
    esac
  done < "$file"
  return 1
}

# Print PID's command line: Linux and Cygwin procfs first, `ps -o command=`
# where procfs is absent (macOS).
fm_proc_cmdline() {
  local pid=$1 out
  if [ -r "/proc/$pid/cmdline" ]; then
    out=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null)
    out=${out% }
    if [ -n "$out" ]; then
      printf '%s\n' "$out"
      return 0
    fi
  fi
  ps -p "$pid" -o command= 2>/dev/null
}

# Print PID's process group id. MSYS ps has no -o, but its fixed default
# output carries PGID in column 3.
fm_proc_pgid() {
  local pid=$1 out
  out=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$out" ] && [ "$FM_PROC_WINDOWS" = 1 ]; then
    out=$(ps -p "$pid" 2>/dev/null | awk 'NR > 1 { print $3; exit }')
  fi
  case "$out" in
    ''|*[!0-9]*) return 1 ;;
  esac
  printf '%s\n' "$out"
}

# --- harness ancestor ---------------------------------------------------------
# Both walks print "<pid>\t<label>": the pid to record and the text that
# matched (a command basename, script basename, or interpreter command line).

fm_proc_ps_harness_find() {
  local pid=$$ comm args base
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    base=$(basename "$comm")
    if printf '%s' "$base" | grep -qE "$FM_PROC_HARNESS_RE"; then
      printf '%s\t%s\n' "$pid" "$base"
      return 0
    fi
    case "$base" in
      node*|python*)
        # Bare interpreter: match the harness name in its script path.
        args=$(ps -o args= -p "$pid" 2>/dev/null)
        if fm_proc_text_names_harness "$args"; then
          printf '%s\t%s\n' "$pid" "$args"
          return 0
        fi ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

fm_proc_win_harness_find() {
  local pid=$$ ppid winpid exe base shim out psbin
  for _ in 1 2 3 4 5 6 7 8; do
    exe=$(cat "/proc/$pid/exename" 2>/dev/null) || break
    base=$(basename "$exe")
    if printf '%s' "$base" | grep -qE "$FM_PROC_HARNESS_RE"; then
      winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || break
      printf '%s\t%s\n' "$winpid" "$base"
      return 0
    fi
    case "$base" in
      bash|sh|dash|bash.exe|sh.exe|dash.exe)
        # Script-shim harness: a wrapper script named like a harness runs as
        # bash here; its identity lives in argv, not the executable name.
        if shim=$(fm_proc_shim_script "/proc/$pid/cmdline") \
          && printf '%s' "$(basename "$shim")" | grep -qE "$FM_PROC_HARNESS_RE"; then
          winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || break
          printf '%s\t%s\n' "$winpid" "$(basename "$shim")"
          return 0
        fi ;;
    esac
    ppid=$(cat "/proc/$pid/ppid" 2>/dev/null) || break
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
  done
  winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
  psbin=$(fm_proc_powershell) || return 1
  # One powershell invocation for the native walk; pid and regex ride in as env
  # vars so no bash-side escaping can corrupt the script. [int] casts make a
  # garbage pid a hard error (empty output) rather than a WQL injection. The
  # bash/sh arm mirrors fm_proc_shim_script's discipline: a command line whose
  # option words contain "c" (-c, -lc, ...) is an inline command string, never
  # a script shim.
  # shellcheck disable=SC2016  # Single quotes are deliberate: $... belongs to the PowerShell snippet.
  out=$(FM_PROC_PID="$winpid" FM_PROC_RE="$FM_PROC_HARNESS_RE" "$psbin" -NoProfile -NonInteractive -Command '
    $p = [int]$env:FM_PROC_PID
    for ($i = 0; $i -lt 12; $i++) {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
      if (-not $proc) { exit 1 }
      $name = $proc.Name -replace "\.exe$", ""
      if ($name -cmatch $env:FM_PROC_RE) { Write-Output "$($proc.ProcessId) $name"; exit 0 }
      $cl = "$($proc.CommandLine)"
      if ($name -match "^(node|python[0-9.]*)$" -and $cl -cmatch $env:FM_PROC_RE) { Write-Output "$($proc.ProcessId) $cl"; exit 0 }
      if ($name -match "^(bash|sh|dash)$" -and $cl -notmatch "(^|\s)-[^-\s]*c" -and $cl -cmatch $env:FM_PROC_RE) { Write-Output "$($proc.ProcessId) $cl"; exit 0 }
      $p = [int]$proc.ParentProcessId
      if ($p -le 1) { exit 1 }
    }
    exit 1' 2>/dev/null) || return 1
  out=${out//$'\r'/}
  out=${out#"${out%%[![:space:]]*}"}
  out=${out%"${out##*[![:space:]]}"}
  pid=${out%% *}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\t%s\n' "$pid" "${out#* }"
}

fm_proc_harness_find() {
  if fm_proc_ps_o_ok; then
    fm_proc_ps_harness_find && return 0
  fi
  [ "$FM_PROC_WINDOWS" = 1 ] || return 1
  fm_proc_win_harness_find
}

fm_proc_harness_pid() {
  local rec
  rec=$(fm_proc_harness_find) || return 1
  printf '%s\n' "${rec%%$'\t'*}"
}

fm_proc_harness_name() {
  local rec label
  rec=$(fm_proc_harness_find) || return 1
  label=${rec#*$'\t'}
  case "$label" in
    *claude*) echo claude ;;
    *codex*) echo codex ;;
    *opencode*) echo opencode ;;
    *grok*) echo grok ;;
    *)
      case " $label " in
        *" pi "*|*"/pi "*) echo pi ;;
        *) return 1 ;;
      esac ;;
  esac
}

# --- holder liveness ----------------------------------------------------------

fm_proc_ps_holder_alive() {
  local pid=$1 comm
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$FM_PROC_HARNESS_RE"
}

fm_proc_win_holder_alive() {
  local pid=$1 exe cmdline out psbin
  if [ -e "/proc/$pid" ]; then
    # An MSYS-visible pid: judge it from procfs. CIM indexes native pids, and
    # an MSYS pid (especially after an exec changed the native pid underneath
    # it) need not exist there at all.
    exe=$(cat "/proc/$pid/exename" 2>/dev/null) || return 1
    cmdline=$(fm_proc_cmdline "$pid" 2>/dev/null || true)
    printf '%s %s' "$(basename "$exe")" "$cmdline" | grep -qE "$FM_PROC_HARNESS_RE"
    return
  fi
  psbin=$(fm_proc_powershell) || return 1
  # shellcheck disable=SC2016  # Single quotes are deliberate: $... belongs to the PowerShell snippet.
  out=$(FM_PROC_PID="$pid" FM_PROC_RE="$FM_PROC_HARNESS_RE" "$psbin" -NoProfile -NonInteractive -Command '
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$env:FM_PROC_PID)" -ErrorAction SilentlyContinue
    if (-not $proc) { exit 1 }
    $name = $proc.Name -replace "\.exe$", ""
    if ("$name $($proc.CommandLine)" -cmatch $env:FM_PROC_RE) { Write-Output live }' 2>/dev/null)
  out=${out//[$'\r\n ']/}
  [ "$out" = live ]
}

# True when PID is a live process that looks like a harness. On Windows a
# ps-based "dead" verdict is not trusted alone: a capable ps still only sees
# MSYS pids, while a lock may hold a native pid only CIM can judge.
fm_proc_holder_alive() {
  local pid=$1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  if fm_proc_ps_o_ok; then
    fm_proc_ps_holder_alive "$pid" && return 0
  fi
  [ "$FM_PROC_WINDOWS" = 1 ] || return 1
  fm_proc_win_holder_alive "$pid"
}

# --- ancestry membership ------------------------------------------------------

fm_proc_ps_pid_in_ancestry() {
  local target=$1 pid=$$
  kill -0 "$target" 2>/dev/null || return 1
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$target" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

fm_proc_win_pid_in_ancestry() {
  local target=$1 pid=$$ winpid ppid out psbin
  # The MSYS side first: compare both the MSYS pid and its native winpid at
  # every level, so a target written in either spelling matches without ever
  # paying for a CIM query.
  for _ in 1 2 3 4 5 6 7 8; do
    [ "$pid" = "$target" ] && return 0
    winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
    [ "$winpid" = "$target" ] && return 0
    ppid=$(cat "/proc/$pid/ppid" 2>/dev/null) || break
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
  done
  # Continue natively from the topmost MSYS process: a harness holds the lock
  # under its NATIVE pid, reachable only through CIM ancestry.
  winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
  psbin=$(fm_proc_powershell) || return 1
  # shellcheck disable=SC2016  # Single quotes are deliberate: $... belongs to the PowerShell snippet.
  out=$(FM_PROC_PID="$winpid" FM_PROC_TARGET="$target" "$psbin" -NoProfile -NonInteractive -Command '
    $p = [int]$env:FM_PROC_PID
    $t = [int]$env:FM_PROC_TARGET
    for ($i = 0; $i -lt 12; $i++) {
      if ($p -eq $t) { Write-Output yes; exit 0 }
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
      if (-not $proc) { exit 1 }
      $p = [int]$proc.ParentProcessId
      if ($p -le 1) { exit 1 }
    }
    exit 1' 2>/dev/null)
  out=${out//[$'\r\n ']/}
  [ "$out" = yes ]
}

# True when PID (MSYS or native spelling) is this process or one of its
# ancestors. Liveness is implied: a dead pid cannot appear in a live chain.
fm_proc_pid_in_ancestry() {
  local target=$1
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  if fm_proc_ps_o_ok; then
    fm_proc_ps_pid_in_ancestry "$target" && return 0
  fi
  [ "$FM_PROC_WINDOWS" = 1 ] || return 1
  fm_proc_win_pid_in_ancestry "$target"
}
