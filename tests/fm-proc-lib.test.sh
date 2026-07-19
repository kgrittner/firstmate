#!/usr/bin/env bash
# Behavior tests for the shared process-inspection primitives in bin/fm-proc-lib.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-proc-lib)
LIB="$ROOT/bin/fm-proc-lib.sh"

# shellcheck source=bin/fm-proc-lib.sh
. "$LIB"

test_cmdline_of_self() {
  local out
  out=$(fm_proc_cmdline $$) || fail "fm_proc_cmdline failed for own pid"
  assert_contains "$out" "fm-proc-lib" "own command line does not name this test script"
  pass "fm-proc-lib: fm_proc_cmdline reads the caller's own command line"
}

test_pgid_is_numeric() {
  local out
  out=$(fm_proc_pgid $$) || fail "fm_proc_pgid failed for own pid"
  case "$out" in
    ''|*[!0-9]*) fail "fm_proc_pgid printed a non-numeric pgid: $out" ;;
  esac
  pass "fm-proc-lib: fm_proc_pgid prints a numeric process group id"
}

test_ancestry_membership() {
  local status=0
  # Own pid always counts as in-ancestry.
  fm_proc_pid_in_ancestry $$ || fail "own pid not recognized as in ancestry"
  # A genuine parent, judged from a fresh child process whose own pid differs.
  FM_PROC_TARGET_PID=$$ bash -c '
    . "$1" || exit 2
    fm_proc_pid_in_ancestry "$FM_PROC_TARGET_PID"
  ' _ "$LIB" || fail "parent pid not found in a child process ancestry"
  # A live sibling process is NOT an ancestor.
  sleep 30 &
  local sibling=$!
  fm_proc_pid_in_ancestry "$sibling" && status=1
  kill "$sibling" 2>/dev/null || true
  wait "$sibling" 2>/dev/null || true
  [ "$status" = 0 ] || fail "a live non-ancestor sibling was reported as an ancestor"
  # Garbage input fails closed.
  fm_proc_pid_in_ancestry "" && fail "empty pid accepted"
  fm_proc_pid_in_ancestry "12x4" && fail "non-numeric pid accepted"
  pass "fm-proc-lib: ancestry membership accepts self and parents, rejects siblings and garbage"
}

test_harness_walk_via_fake_ps() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-claude")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '/usr/local/bin/claude\n'; exit 0 ;;
  *"args="*) printf 'claude\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" bash -c '
    . "$1" || exit 2
    pid=$(fm_proc_harness_pid) || exit 1
    name=$(fm_proc_harness_name) || exit 1
    printf "%s %s\n" "$pid" "$name"
  ' _ "$LIB") || fail "harness walk failed under an -o-capable fake ps"
  case "$out" in
    *" claude") ;;
    *) fail "harness walk did not detect claude: $out" ;;
  esac
  case "${out%% *}" in
    ''|*[!0-9]*) fail "harness walk printed a non-numeric pid: $out" ;;
  esac
  pass "fm-proc-lib: an -o-capable ps drives the portable harness walk on every platform"
}

test_harness_name_maps_interpreter_labels() {
  local fakebin out
  fakebin=$(fm_fakebin "$TMP_ROOT/fake-node-codex")
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"comm="*) printf '/usr/bin/node\n'; exit 0 ;;
  *"args="*) printf 'node /usr/local/lib/codex/cli.js\n'; exit 0 ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
  out=$(PATH="$fakebin:$PATH" bash -c '
    . "$1" || exit 2
    fm_proc_harness_name
  ' _ "$LIB") || fail "interpreter harness walk failed"
  [ "$out" = codex ] || fail "expected codex from a node interpreter label, got: $out"
  pass "fm-proc-lib: an interpreter command line maps to its harness name"
}

test_text_names_harness() {
  fm_proc_text_names_harness "claude" || fail "claude not recognized"
  fm_proc_text_names_harness "node /usr/local/bin/pi" || fail "pi path tail not recognized"
  fm_proc_text_names_harness "pi --serve" || fail "pi word not recognized"
  fm_proc_text_names_harness "vim notes.md" && fail "vim falsely recognized as a harness"
  fm_proc_text_names_harness "picker" && fail "pi prefix inside a longer word falsely recognized"
  pass "fm-proc-lib: harness-name text matching accepts pi forms and rejects lookalikes"
}

test_shim_script_parse() {
  local dir out
  dir="$TMP_ROOT/shims"
  mkdir -p "$dir"
  printf '/usr/bin/bash\0/usr/local/bin/grok\0' > "$dir/shim"
  printf '/usr/bin/bash\0-c\0echo claude\0' > "$dir/inline"
  printf '/usr/bin/bash\0-lc\0claude something\0' > "$dir/inline-combined"
  printf '/usr/bin/bash\0--norc\0/usr/local/bin/codex\0--serve\0' > "$dir/opts"
  out=$(fm_proc_shim_script "$dir/shim") || fail "plain script shim not parsed"
  [ "$out" = /usr/local/bin/grok ] || fail "wrong shim script path: $out"
  fm_proc_shim_script "$dir/inline" && fail "-c command string mistaken for a script shim"
  fm_proc_shim_script "$dir/inline-combined" && fail "-lc command string mistaken for a script shim"
  out=$(fm_proc_shim_script "$dir/opts") || fail "option-prefixed shim not parsed"
  [ "$out" = /usr/local/bin/codex ] || fail "wrong option-prefixed shim path: $out"
  fm_proc_shim_script "$dir/missing" && fail "missing cmdline file accepted"
  pass "fm-proc-lib: shim argv parsing takes the script path and refuses -c command strings"
}

test_holder_alive_rejects_garbage() {
  fm_proc_holder_alive "" && fail "empty holder pid accepted"
  fm_proc_holder_alive "abc" && fail "non-numeric holder pid accepted"
  pass "fm-proc-lib: holder liveness fails closed on malformed pids"
}

test_cmdline_of_self
test_pgid_is_numeric
test_ancestry_membership
test_harness_walk_via_fake_ps
test_harness_name_maps_interpreter_labels
test_text_names_harness
test_shim_script_parse
test_holder_alive_rejects_garbage
