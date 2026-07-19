#!/usr/bin/env bash
# Behavior tests for bin/fm-jq-lib.sh - the repo-owned jq defense for Windows.
#
# The contract under test (see the library header): fm_jq must pass jq's
# output and exit status through untouched in plain mode; in excl-strip mode it
# must strip LINE-FINAL CRs only (embedded CRs inside a value survive - the
# deliberate difference from a tr -d '\r' wrapper) while still preserving jq's
# exit status through the pipe; fm_jq_emits_crlf must detect a CRLF-emitting jq
# at the byte level (Git Bash's $(...) trims a trailing CRLF, so a naive
# capture probe reads clean even from a broken jq) and must treat a missing jq
# as clean, never as incompatible; and fm_jq_resolve_mode must pick plain off
# Windows and excl/excl-strip on it. Fake jq builds drive both mode paths on
# every platform; the resolve-mode case asserts against the real host.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-jq-lib.sh disable=SC1091
. "$ROOT/bin/fm-jq-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-jq-tests)

# A fake jq that emits CRLF line endings like winget jq 1.8.2, echoing a fixed
# two-line payload with an embedded CR inside the second value, and exiting
# with FM_FAKE_JQ_STATUS (default 0). Ignores its arguments.
make_crlf_jq() {
  local fakebin=$1
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf 'alpha\r\nbra\rvo\r\n'
exit "${FM_FAKE_JQ_STATUS:-0}"
SH
  chmod +x "$fakebin/jq"
}

# A fake jq that emits clean LF output.
make_clean_jq() {
  local fakebin=$1
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf 'alpha\nbra\rvo\n'
exit "${FM_FAKE_JQ_STATUS:-0}"
SH
  chmod +x "$fakebin/jq"
}

bytes_of() {
  od -An -c | tr -s ' ' | tr -d '\n'
}

test_probe_detects_crlf_jq() {
  local dir fakebin
  dir="$TMP_ROOT/probe-crlf"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf 'x\r\n'
SH
  chmod +x "$fakebin/jq"
  if ! (PATH="$fakebin:$PATH" fm_jq_emits_crlf); then
    fail "probe must detect a CRLF-emitting jq"
  fi
  pass "probe detects a CRLF-emitting jq"
}

test_probe_clean_on_lf_jq() {
  local dir fakebin
  dir="$TMP_ROOT/probe-clean"
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/jq" <<'SH'
#!/usr/bin/env bash
printf 'x\n'
SH
  chmod +x "$fakebin/jq"
  if (PATH="$fakebin:$PATH" fm_jq_emits_crlf); then
    fail "probe must read an LF-emitting jq as clean"
  fi
  pass "probe reads an LF-emitting jq as clean"
}

test_probe_clean_when_jq_missing() {
  local dir fakebin
  dir="$TMP_ROOT/probe-missing"
  fakebin=$(fm_fakebin "$dir")
  # PATH with no jq at all: absence must probe clean, never incompatible.
  if (PATH="$fakebin" fm_jq_emits_crlf); then
    fail "a missing jq must probe clean"
  fi
  pass "a missing jq probes clean"
}

test_strip_mode_strips_line_final_crs_only() {
  local dir fakebin out expected
  dir="$TMP_ROOT/strip"
  fakebin=$(fm_fakebin "$dir")
  make_crlf_jq "$fakebin"
  out=$(PATH="$fakebin:$PATH" FM_JQ_MODE=excl-strip fm_jq -r . | bytes_of)
  expected=$(printf 'alpha\nbra\rvo\n' | bytes_of)
  [ "$out" = "$expected" ] \
    || fail "excl-strip must drop line-final CRs and keep the embedded CR (got: $out want: $expected)"
  pass "excl-strip drops line-final CRs only; embedded CR survives"
}

test_plain_mode_passes_output_through() {
  local dir fakebin out expected
  dir="$TMP_ROOT/plain"
  fakebin=$(fm_fakebin "$dir")
  make_clean_jq "$fakebin"
  out=$(PATH="$fakebin:$PATH" FM_JQ_MODE=plain fm_jq -r . | bytes_of)
  expected=$(printf 'alpha\nbra\rvo\n' | bytes_of)
  [ "$out" = "$expected" ] \
    || fail "plain mode must not touch jq output (got: $out want: $expected)"
  pass "plain mode passes output through untouched"
}

test_exit_status_preserved_in_strip_mode() {
  local dir fakebin rc
  dir="$TMP_ROOT/status-strip"
  fakebin=$(fm_fakebin "$dir")
  make_crlf_jq "$fakebin"
  rc=0
  PATH="$fakebin:$PATH" FM_JQ_MODE=excl-strip FM_FAKE_JQ_STATUS=5 fm_jq -r . >/dev/null || rc=$?
  [ "$rc" = 5 ] || fail "excl-strip must return jq's own exit status through the pipe (got $rc)"
  pass "excl-strip preserves jq's exit status through the strip pipe"
}

test_exit_status_preserved_in_plain_and_excl_modes() {
  local dir fakebin mode rc
  dir="$TMP_ROOT/status-plain"
  fakebin=$(fm_fakebin "$dir")
  make_clean_jq "$fakebin"
  for mode in plain excl; do
    rc=0
    PATH="$fakebin:$PATH" FM_JQ_MODE=$mode FM_FAKE_JQ_STATUS=3 fm_jq -r . >/dev/null || rc=$?
    [ "$rc" = 3 ] || fail "$mode mode must return jq's own exit status (got $rc)"
  done
  pass "plain and excl modes preserve jq's exit status"
}

test_resolve_mode_matches_host_platform() {
  local mode
  mode=$(unset FM_JQ_MODE; fm_jq_resolve_mode; printf '%s' "$FM_JQ_MODE")
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      case "$mode" in
        excl|excl-strip) pass "resolve-mode picks a Windows mode on this host ($mode)" ;;
        *) fail "resolve-mode must pick excl or excl-strip on Windows (got $mode)" ;;
      esac
      ;;
    *)
      [ "$mode" = plain ] || fail "resolve-mode must pick plain off Windows (got $mode)"
      pass "resolve-mode picks plain on this host"
      ;;
  esac
}

test_fm_jq_path_identity_in_plain_mode() {
  local out
  out=$(FM_JQ_MODE=plain fm_jq_path /tmp/foo)
  [ "$out" = /tmp/foo ] || fail "fm_jq_path must be the identity in plain mode (got $out)"
  pass "fm_jq_path is the identity in plain mode"
}

# Deterministic routing enforcement: fm scripts must invoke jq only through
# fm_jq, so a Windows fleet never regains an unrouted parse site. Allowed
# residues: `command -v jq` presence checks, comment/prose mentions, the
# library's own `command jq` calls, and word matches that are not invocations
# (case patterns, tool lists, install lines).
test_no_bare_jq_invocations_in_fm_scripts() {
  local hits
  hits=$(grep -nE '(^|[|(;&`$! ])jq +' "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh \
    | grep -v 'command -v jq' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    | grep -v '/fm-jq-lib.sh:' \
    | grep -vE 'install_cmd jq|MISSING(_MANUAL)?: jq|jq \(install|jq treehouse|curl jq') || true
  [ -z "$hits" ] || fail "bare jq invocation(s) found; route through fm_jq: $hits"
  pass "no bare jq invocations remain in fm scripts"
}

test_real_jq_roundtrip() {
  # Integration against whatever jq this host resolves: value and status must
  # come back clean regardless of platform or jq build.
  local v rc
  command -v jq >/dev/null 2>&1 || { pass "real-jq roundtrip skipped (no jq on PATH)"; return 0; }
  unset FM_JQ_MODE
  v=$(fm_jq -rn '"x"') || fail "fm_jq failed against the real jq"
  [ "$v" = x ] || fail "fm_jq must return the clean value from the real jq (got $(printf '%s' "$v" | bytes_of))"
  rc=0
  fm_jq -en 'false' >/dev/null || rc=$?
  [ "$rc" = 1 ] || fail "fm_jq must propagate the real jq's -e exit status (got $rc)"
  pass "real-jq roundtrip returns clean value and exit status"
}

test_probe_detects_crlf_jq
test_probe_clean_on_lf_jq
test_probe_clean_when_jq_missing
test_strip_mode_strips_line_final_crs_only
test_plain_mode_passes_output_through
test_exit_status_preserved_in_strip_mode
test_exit_status_preserved_in_plain_and_excl_modes
test_resolve_mode_matches_host_platform
test_fm_jq_path_identity_in_plain_mode
test_no_bare_jq_invocations_in_fm_scripts
test_real_jq_roundtrip

echo "fm-jq: all tests passed"
