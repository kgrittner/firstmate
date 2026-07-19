#!/usr/bin/env bash
# tests/lib.sh - shared primitives for firstmate behavior tests.
#
# Source this from a test file:
#   # shellcheck source=tests/lib.sh
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# It provides the boilerplate every test file used to re-roll: ok/not-ok
# reporters, a self-cleaning temp root, fakebin/PATH-shim helpers, deterministic
# git identity and fixture builders, state/<id>.meta writers, and the common
# string/exit-code/file assertions. It deliberately does NOT bundle the
# behavior-specific fake tmux/treehouse/no-mistakes mocks: those encode terminal
# and lifecycle assumptions that differ per suite and belong with the tests that
# own them.
#
# ROOT is exported as the firstmate repo root (this file lives in tests/), so a
# sourcing test can use "$ROOT/bin/..." without recomputing it.

# Idempotent guard: behavior-area helper files (secondmate-helpers.sh,
# wake-helpers.sh) source this library for ROOT/fail/pass, and the test that
# includes them may also source it directly. Re-sourcing must not wipe the
# registered-cleanup array or reset state.
if [ -n "${FM_TEST_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_TEST_LIB_SOURCED=1

# Exempt firstmate's own test suite from the gate-lifecycle refusal
# (bin/fm-gate-refuse-lib.sh). The no-mistakes gate runs this suite FROM a gate
# worktree - the exact environment that guard refuses - so without this every
# test that drives the real fm-spawn/fm-send/fm-teardown would be refused during
# firstmate's own validation. A confused gate agent never sources this helper, so
# the boundary against the real hazard is unaffected. tests/fm-gate-refuse.test.sh
# strips this to verify real refusal.
export FM_GATE_REFUSE_BYPASS=1

# Resolve the repo root from this library's own location. Consumed by sourcing
# test files, not by this library, so it reads as "unused" here.
# shellcheck disable=SC2034
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- reporters --------------------------------------------------------------

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# skip <msg>: report a case deliberately not run on this platform. Prints a
# distinct 'skip - ' line (never 'ok - ': CI pins exact ok-counts on POSIX, and
# a skip must not inflate them).
skip() {
  printf 'skip - %s\n' "$1"
}

# --- platform awareness -----------------------------------------------------
#
# Git Bash (MINGW*/MSYS*) differs from POSIX hosts in three ways tests must
# account for (see data/scan-wincompat-b2/report.md, issue 19):
#   - git lives in /mingw64/bin, not /usr/bin, and jq is not bundled at all;
#   - PATH doubles as the Windows DLL search path, so any PATH that hides
#     /usr/bin and /mingw64/bin breaks every MSYS binary (msys-2.0.dll);
#   - all mounts are noacl, so chmod is cosmetic and chmod-based negative
#     fixtures (unreadable/unwritable) can never be enforced.

# fm_test_windows: succeed when running under Git Bash / MSYS on Windows.
fm_test_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*) return 0 ;;
    *) return 1 ;;
  esac
}

# FM_TEST_SYSTEM_PATH: the hermetic system-tool PATH pin for tests that must
# shadow the caller's PATH. On Git Bash it must retain /mingw64/bin (git) and
# /usr/bin (coreutils + the DLL search path); on POSIX it is the traditional
# pin. jq is deliberately NOT reachable through this pin on Windows - tests
# that need jq must place it (or a shim) in their fakebin explicitly.
if fm_test_windows; then
  FM_TEST_SYSTEM_PATH=/mingw64/bin:/usr/bin:/bin:/usr/sbin:/sbin
else
  FM_TEST_SYSTEM_PATH=/usr/bin:/bin:/usr/sbin:/sbin
fi
# Consumed by sourcing test files, not by this library.
# shellcheck disable=SC2034
: "$FM_TEST_SYSTEM_PATH"

# fm_test_chmod_negative_works: succeed when chmod-based negative fixtures
# (chmod 000 / u-w / 500 to make something unreadable or unwritable) actually
# deny access on this host. On Git Bash every mount is noacl, so chmod is
# cosmetic and such fixtures silently stay accessible; those cases must skip.
fm_test_chmod_negative_works() {
  ! fm_test_windows
}

# fm_test_toolbin_dlls <dir>: make a symlink-populated fakebin/toolbin usable
# as the ONLY PATH entry on Windows. The Windows loader resolves DLLs via the
# invoked path's directory and PATH; a fakebin-only PATH of symlinked MSYS or
# MinGW binaries therefore fails to load msys-2.0.dll et al. Symlinking the
# runtime DLLs next to the tool symlinks restores resolution without putting
# /usr/bin or /mingw64/bin (and the tools a test deliberately hides, such as
# timeout or jq) back on PATH. No-op on POSIX.
fm_test_toolbin_dlls() {
  local dir=$1
  fm_test_windows || return 0
  # One ln invocation for all DLLs: per-file ln calls cost a process spawn each,
  # which is prohibitively slow on Windows. Individual failures (unmatched glob
  # words, name collisions) are non-fatal and skipped.
  ln -s -t "$dir" /usr/bin/msys-*.dll /mingw64/bin/*.dll 2>/dev/null || true
}

# fm_test_cr: echo a literal carriage return. Git Bash's script reader drops
# word-final CRs from some $'...\r' literals read out of script files, so
# CR-bearing fixtures must be built at runtime instead of spelled inline.
fm_test_cr() {
  printf '\r'
}

# --- self-cleaning temp root ------------------------------------------------
#
# fm_test_tmproot <prefix> echoes a fresh temp dir and registers it for removal
# on EXIT. The first call installs the cleanup trap. A test file that needs
# extra teardown (e.g. killing a daemon) should define its own EXIT trap and
# call fm_test_cleanup from inside it so registered dirs are still removed.

FM_TEST_CLEANUP_DIRS=()

fm_test_cleanup() {
  local d
  for d in "${FM_TEST_CLEANUP_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
}

fm_test_tmproot() {
  local prefix=${1:-fm-test} root
  root=$(mktemp -d "${TMPDIR:-/tmp}/${prefix}.XXXXXX")
  if [ "${#FM_TEST_CLEANUP_DIRS[@]}" -eq 0 ]; then
    trap fm_test_cleanup EXIT
  fi
  FM_TEST_CLEANUP_DIRS+=("$root")
  printf '%s\n' "$root"
}

# --- fakebin / PATH shims ---------------------------------------------------
#
# fm_fakebin <dir> creates <dir>/fakebin and echoes it; prepend it to PATH to
# shadow real tools with stubs. fm_fake_exit0 drops trivial exit-0 stubs for the
# named tools into a fakebin dir.

fm_fakebin() {
  local dir=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  printf '%s\n' "$fakebin"
}

fm_fake_exit0() {
  local fakebin=$1 tool
  shift
  for tool in "$@"; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$fakebin/$tool"
  done
}

# fm_fake_real_jq <fakebin>: expose the host's real jq inside a fakebin via an
# absolute-path wrapper. Tests that pin PATH to fakebin:$BASE_PATH need this
# when the code under test parses JSON: jq is not reachable through the bare
# system pin on every host (Git Bash does not bundle it; Homebrew/Nix installs
# live outside it), and prepending jq's own directory could leak other tools a
# case deliberately hides.
fm_fake_real_jq() {
  local fakebin=$1 real_jq
  real_jq=$(command -v jq 2>/dev/null) || fail "jq is required on the test host"
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
exec '$real_jq' "\$@"
SH
  chmod +x "$fakebin/jq"
}

# --- deterministic git identity and fixtures --------------------------------

# fm_git_identity [name] [email]: export a fixed author/committer identity so
# fixture commits never depend on the host git config.
fm_git_identity() {
  export GIT_AUTHOR_NAME=${1:-fmtest} GIT_AUTHOR_EMAIL=${2:-fmtest@example.invalid}
  export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
}

# fm_git_init_commit <dir>: create a git repo at <dir> with a README and one
# commit. Uses an inline identity so it works whether or not fm_git_identity was
# called.
fm_git_init_commit() {
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# %s\n' "$(basename "$dir")" > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
}

# fm_git_add_origin <repo> <bare>: clone <repo> bare into <bare> and register it
# as <repo>'s origin via a file:// URL (so later clones resolve an absolute path).
fm_git_add_origin() {
  local repo=$1 remote=$2 remote_abs
  git clone --quiet --bare "$repo" "$remote"
  remote_abs=$(cd "$remote" && pwd)
  git -C "$repo" remote add origin "file://$remote_abs"
}

# fm_git_worktree <repo> <worktree> <branch>: init <repo> with one commit, then
# add a worktree on a fresh branch.
fm_git_worktree() {
  local repo=$1 worktree=$2 branch=$3
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b "$branch" "$worktree"
}

# --- state/<id>.meta writers ------------------------------------------------

# fm_write_meta <file> <key=val> ...: write the given key=val lines to a meta
# file (truncating any prior content).
fm_write_meta() {
  local file=$1 kv
  shift
  : > "$file"
  for kv in "$@"; do
    printf '%s\n' "$kv" >> "$file"
  done
}

# fm_write_secondmate_meta <file> <home> [window] [projects]: write the standard
# kind=secondmate meta block used across the secondmate suites. window defaults
# to firstmate:fm-<basename-of-home-dir's parent id>? No - window is explicit;
# defaults to firstmate:fm-domain and projects to alpha to match the common case.
fm_write_secondmate_meta() {
  local file=$1 home=$2 window=${3:-firstmate:fm-domain} projects=${4:-alpha}
  fm_write_meta "$file" \
    "window=$window" \
    "worktree=$home" \
    "project=$home" \
    "harness=echo" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "home=$home" \
    "projects=$projects"
}

# --- common assertions ------------------------------------------------------

# assert_contains <haystack> <needle> <msg>
assert_contains() {
  case "$1" in
    *"$2"*) : ;;
    *) fail "$3 (missing: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
  esac
}

# assert_not_contains <haystack> <needle> <msg>
assert_not_contains() {
  case "$1" in
    *"$2"*) fail "$3 (unexpected: '$2')"$'\n'"--- output ---"$'\n'"$1" ;;
    *) : ;;
  esac
}

# expect_code <expected> <actual> <label>
expect_code() {
  local expected=$1 actual=$2 label=$3
  [ "$actual" = "$expected" ] || fail "$label: expected exit $expected, got $actual"
}

# assert_grep <pattern> <file> <msg>: fixed-string grep must match in <file>.
# `--` guards patterns that begin with '-' (e.g. backlog/registry lines).
assert_grep() {
  grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_no_grep <pattern> <file> <msg>: fixed-string grep must NOT match.
assert_no_grep() {
  ! grep -F -- "$1" "$2" >/dev/null || fail "$3"
}

# assert_absent <path> <msg>: path must not exist.
assert_absent() {
  [ ! -e "$1" ] || fail "$2"
}

# assert_present <path> <msg>: path must exist.
assert_present() {
  [ -e "$1" ] || fail "$2"
}
