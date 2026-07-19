#!/usr/bin/env bash
# Acquire or inspect the per-home firstmate session lock.
# Writes the harness (agent) process PID found by walking the shell's ancestry,
# which lives as long as the firstmate session - unlike the transient subshell
# PID of any one tool call, which is dead moments after it is written.
# Usage: fm-lock.sh           acquire; exit 1 if another live session holds it
#        fm-lock.sh status    print holder and liveness; always exits 0
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOCK="$STATE/.lock"
mkdir -p "$STATE"

# Known harness command names; extend when a new adapter is verified.
HARNESS_RE='claude|codex|opencode|grok|^pi$'

# Windows (Git Bash / MSYS / Cygwin): the bundled MSYS ps has no -o support and
# only sees MSYS processes, while the harness runs as a NATIVE Windows process
# (e.g. claude.exe) that the MSYS ancestry never reaches - its view bottoms out
# at ppid 1. So on these platforms the walk starts from this shell's native
# Windows pid (/proc/$$/winpid) and follows ParentProcessId through one CIM
# query loop. The pid written to the lock is then a native Windows pid, and
# liveness must be answered by CIM too: MSYS kill -0 operates on MSYS pids and
# would misjudge a native one.
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) FM_LOCK_WINDOWS=1 ;; *) FM_LOCK_WINDOWS=0 ;; esac

win_harness_pid() {
  local pid=$$ ppid winpid exe out
  # Climb the MSYS side first via /proc: MSYS emulates fork/exec with transient
  # stub processes, so a nested shell's NATIVE parent pid may already be dead,
  # while /proc/<pid>/ppid tracks the logical parent correctly. Only the
  # topmost MSYS process (ppid 1) has a trustworthy native ancestry - its
  # parents are real long-lived processes (launcher, harness), not exec stubs.
  for _ in 1 2 3 4 5 6 7 8; do
    exe=$(cat "/proc/$pid/exename" 2>/dev/null) || break
    if printf '%s' "$(basename "$exe")" | grep -qE "$HARNESS_RE"; then
      cat "/proc/$pid/winpid" 2>/dev/null
      return
    fi
    ppid=$(cat "/proc/$pid/ppid" 2>/dev/null) || break
    case "$ppid" in ''|*[!0-9]*) break ;; esac
    [ "$ppid" -gt 1 ] || break
    pid=$ppid
  done
  winpid=$(cat "/proc/$pid/winpid" 2>/dev/null) || return 1
  # One powershell invocation for the native walk; pid and regex ride in as env
  # vars so no bash-side escaping can corrupt the script. [int] casts make a
  # garbage pid a hard error (empty output) rather than a WQL injection.
  # shellcheck disable=SC2016  # Single quotes are deliberate: $... belongs to the PowerShell snippet.
  out=$(FM_LOCK_PID="$winpid" FM_LOCK_RE="$HARNESS_RE" powershell.exe -NoProfile -NonInteractive -Command '
    $p = [int]$env:FM_LOCK_PID
    for ($i = 0; $i -lt 12; $i++) {
      $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$p" -ErrorAction SilentlyContinue
      if (-not $proc) { exit 1 }
      $name = $proc.Name -replace "\.exe$", ""
      if ($name -cmatch $env:FM_LOCK_RE) { Write-Output $proc.ProcessId; exit 0 }
      if ($name -match "^(node|python[0-9.]*)$" -and "$($proc.CommandLine)" -cmatch $env:FM_LOCK_RE) { Write-Output $proc.ProcessId; exit 0 }
      $p = [int]$proc.ParentProcessId
      if ($p -le 1) { exit 1 }
    }
    exit 1' 2>/dev/null) || return 1
  out=${out//[$'\r\n ']/}
  [ -n "$out" ] || return 1
  echo "$out"
}

win_holder_alive() {
  local out
  # shellcheck disable=SC2016  # Single quotes are deliberate: $... belongs to the PowerShell snippet.
  out=$(FM_LOCK_PID="$1" FM_LOCK_RE="$HARNESS_RE" powershell.exe -NoProfile -NonInteractive -Command '
    $proc = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$env:FM_LOCK_PID)" -ErrorAction SilentlyContinue
    if (-not $proc) { exit 1 }
    $name = $proc.Name -replace "\.exe$", ""
    if ("$name $($proc.CommandLine)" -cmatch $env:FM_LOCK_RE) { Write-Output live }' 2>/dev/null)
  out=${out//[$'\r\n ']/}
  [ "$out" = live ]
}

harness_pid() {
  if [ "$FM_LOCK_WINDOWS" = 1 ]; then win_harness_pid; return; fi
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if printf '%s' "$(basename "$comm")" | grep -qE "$HARNESS_RE"; then
      echo "$pid"; return 0
    fi
    # Bare interpreter (e.g. node): match the harness name in its script path.
    case "$comm" in
      *node*|*python*) printf '%s' "$args" | grep -qE "$HARNESS_RE" && { echo "$pid"; return 0; } ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [ -n "$pid" ] && [ "$pid" -gt 1 ] || return 1
  done
  return 1
}

holder_alive() {  # true if $1 is a live process that looks like a harness
  local pid=$1 comm
  if [ "$FM_LOCK_WINDOWS" = 1 ]; then win_holder_alive "$pid"; return; fi
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  printf '%s' "$(basename "$comm") $(ps -o args= -p "$pid" 2>/dev/null)" | grep -qE "$HARNESS_RE"
}

if [ "${1:-}" = "status" ]; then
  if [ ! -f "$LOCK" ]; then echo "lock: free"; exit 0; fi
  old=$(cat "$LOCK")
  if holder_alive "$old"; then echo "lock: held by live harness pid $old"; else echo "lock: stale (pid $old dead or not a harness)"; fi
  exit 0
fi

me=$(harness_pid) || { echo "error: cannot locate harness process in ancestry" >&2; exit 1; }
if [ -f "$LOCK" ]; then
  old=$(cat "$LOCK")
  if [ "$old" != "$me" ] && holder_alive "$old"; then
    echo "error: another live firstmate session holds the lock (pid $old); operate read-only until resolved" >&2
    exit 1
  fi
fi
echo "$me" > "$LOCK"
echo "lock acquired: harness pid $me"
