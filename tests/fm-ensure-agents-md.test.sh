#!/usr/bin/env bash
# Behavior tests for bin/fm-ensure-agents-md.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-ensure-agents-md)

# assert_claude_import <repo> <msg>: CLAUDE.md must be a regular file (not a
# symlink) whose exact bytes are the canonical '@AGENTS.md' import line.
assert_claude_import() {
  local repo=$1 msg=$2
  assert_present "$repo/CLAUDE.md" "$msg (CLAUDE.md missing)"
  [ ! -L "$repo/CLAUDE.md" ] || fail "$msg (CLAUDE.md is a symlink)"
  [ -f "$repo/CLAUDE.md" ] || fail "$msg (CLAUDE.md is not a regular file)"
  printf '@AGENTS.md\n' > "$repo/.expected-claude"
  cmp -s "$repo/.expected-claude" "$repo/CLAUDE.md" \
    || fail "$msg (CLAUDE.md is not the one-line @AGENTS.md import)"
}

# fixture_symlink <repo>: try to create a real CLAUDE.md -> AGENTS.md symlink.
# Returns 1 when the platform cannot make symlinks (e.g. Windows without
# Developer Mode), so callers can skip legacy-form tests there.
fixture_symlink() {
  ln -s AGENTS.md "$1/CLAUDE.md" 2>/dev/null && [ -L "$1/CLAUDE.md" ]
}

test_created_agents_md_includes_self_governance() {
  local repo agents
  repo="$TMP_ROOT/new-project"
  mkdir -p "$repo"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for empty project"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created"
  assert_claude_import "$repo" "fresh create did not write the CLAUDE.md import"
  assert_grep "## Maintaining this file" "$agents" "self-governance section heading missing"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "self-governance section lost the future-session bar"
  assert_grep "Do not repeat what the codebase already shows; point to the authoritative file or command instead." "$agents" \
    "self-governance section lost pointer-over-copy guidance"
  assert_grep "Prefer rewriting or pruning existing entries over appending new ones." "$agents" \
    "self-governance section lost rewrite-or-prune guidance"
  assert_grep "When updating this file, preserve this bar for all agents and keep entries concise." "$agents" \
    "self-governance section lost all-agents maintenance guidance"
  pass "fm-ensure-agents-md.sh: created AGENTS.md includes self-governance section"
}

test_promoted_claude_md_includes_self_governance() {
  local repo agents count
  repo="$TMP_ROOT/claude-project"
  mkdir -p "$repo"
  cat > "$repo/CLAUDE.md" <<'EOF'
# Existing agent memory

Run tests with `make test`.
EOF
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_present "$agents" "AGENTS.md was not created during promotion"
  assert_claude_import "$repo" "promotion did not write the CLAUDE.md import"
  assert_grep "Run tests with \`make test\`." "$agents" \
    "promotion lost existing CLAUDE.md content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "promotion wrote $count self-governance sections"
  assert_grep "Keep this file for knowledge useful to almost every future agent session in this project." "$agents" \
    "promoted AGENTS.md missing self-governance wording"
  pass "fm-ensure-agents-md.sh: promoted CLAUDE.md includes self-governance section"
}

test_promoted_claude_md_without_trailing_newline_keeps_blank_separator() {
  local repo agents before
  repo="$TMP_ROOT/no-trailing-newline-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nRun tests with make test.' > "$repo/CLAUDE.md"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 || fail "fm-ensure-agents-md.sh failed for newline-less CLAUDE.md promotion"
  agents="$repo/AGENTS.md"
  assert_grep "Run tests with make test." "$agents" \
    "newline-less promotion lost or mangled the last content line"
  assert_grep "## Maintaining this file" "$agents" \
    "newline-less promotion did not append the self-governance section"
  before=$(grep -B1 -Fx '## Maintaining this file' "$agents" | head -n 1)
  [ -z "$before" ] || fail "self-governance heading not preceded by a blank line (got: $before)"
  pass "fm-ensure-agents-md.sh: newline-less promotion keeps a blank separator line"
}

test_existing_agents_md_with_import_gains_self_governance() {
  local repo agents out count
  repo="$TMP_ROOT/existing-imported-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nBuild with make.\n' > "$repo/AGENTS.md"
  printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md with import"
  assert_contains "$out" "updated:" "injection into existing AGENTS.md did not report an update"
  assert_grep "Build with make." "$agents" "injection dropped existing AGENTS.md content"
  assert_grep "## Maintaining this file" "$agents" "existing AGENTS.md did not gain the self-governance section"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  assert_claude_import "$repo" "injection disturbed the CLAUDE.md import"
  # Re-run must be a byte-exact no-op reporting unchanged.
  cp "$agents" "$repo/.after-first"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on idempotent re-run"
  assert_contains "$out" "unchanged:" "idempotent re-run did not report unchanged"
  diff "$repo/.after-first" "$agents" >/dev/null \
    || fail "idempotent re-run modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: existing imported AGENTS.md gains the section idempotently"
}

test_existing_agents_md_without_claude_gains_section_and_import() {
  local repo agents out count
  repo="$TMP_ROOT/existing-bare-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\nDeploy with kubectl.\n' > "$repo/AGENTS.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for existing AGENTS.md without CLAUDE.md"
  assert_contains "$out" "updated:" "injection without CLAUDE.md did not report an update"
  assert_claude_import "$repo" "existing bare AGENTS.md did not gain the CLAUDE.md import"
  assert_grep "Deploy with kubectl." "$agents" "injection dropped existing AGENTS.md content"
  count=$(grep -Fc "## Maintaining this file" "$agents")
  [ "$count" -eq 1 ] || fail "injection wrote $count self-governance sections"
  pass "fm-ensure-agents-md.sh: existing AGENTS.md without CLAUDE.md gains section and import"
}

test_existing_agents_md_with_section_reports_unchanged() {
  local repo agents out
  repo="$TMP_ROOT/fully-formed-project"
  mkdir -p "$repo"
  # Build a fully-formed project (AGENTS.md with the section + correct import).
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed building the fully-formed fixture"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  cp "$repo/CLAUDE.md" "$repo/.before-claude"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on already-formed project"
  assert_contains "$out" "unchanged:" "already-formed project was not reported unchanged"
  diff "$repo/.before" "$agents" >/dev/null \
    || fail "already-formed AGENTS.md was modified"
  cmp -s "$repo/.before-claude" "$repo/CLAUDE.md" \
    || fail "already-formed CLAUDE.md import was modified"
  assert_claude_import "$repo" "already-formed project lost the CLAUDE.md import"
  pass "fm-ensure-agents-md.sh: AGENTS.md that already has the section stays unchanged"
}

test_materialized_symlink_claude_md_is_rewritten_to_import() {
  local repo out
  repo="$TMP_ROOT/materialized-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\n## Maintaining this file\n\nKeep this file for knowledge useful to almost every future agent session in this project.\n' > "$repo/AGENTS.md"
  # A tracked CLAUDE.md -> AGENTS.md symlink checked out with
  # core.symlinks=false: a 9-byte plain file holding the bare link target.
  printf 'AGENTS.md' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on a materialized CLAUDE.md symlink"
  assert_contains "$out" "updated:" "materialized symlink rewrite did not report an update"
  assert_claude_import "$repo" "materialized CLAUDE.md symlink was not rewritten to the import"
  pass "fm-ensure-agents-md.sh: materialized CLAUDE.md symlink is rewritten to the import"
}

test_import_without_agents_md_gets_skeleton() {
  local repo out
  repo="$TMP_ROOT/dangling-import-project"
  mkdir -p "$repo"
  printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed for an import without AGENTS.md"
  assert_contains "$out" "created:" "dangling import did not report a create"
  assert_present "$repo/AGENTS.md" "AGENTS.md skeleton was not created for a dangling import"
  assert_grep "## Maintaining this file" "$repo/AGENTS.md" \
    "skeleton for dangling import lacks the self-governance section"
  assert_claude_import "$repo" "dangling import was not preserved as the canonical form"
  pass "fm-ensure-agents-md.sh: dangling @AGENTS.md import gets a skeleton, not a promotion"
}

test_legacy_symlink_claude_md_is_accepted_unchanged() {
  local repo out
  repo="$TMP_ROOT/legacy-symlink-project"
  mkdir -p "$repo"
  printf '# Existing agent memory\n\n## Maintaining this file\n\nKeep this file for knowledge useful to almost every future agent session in this project.\n' > "$repo/AGENTS.md"
  if ! fixture_symlink "$repo"; then
    pass "fm-ensure-agents-md.sh: legacy symlink acceptance skipped (no symlink support here)"
    return 0
  fi
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on a legacy CLAUDE.md symlink"
  assert_contains "$out" "unchanged:" "legacy symlink was not accepted as unchanged"
  [ -L "$repo/CLAUDE.md" ] || fail "legacy CLAUDE.md symlink was replaced"
  pass "fm-ensure-agents-md.sh: legacy CLAUDE.md symlink is accepted unchanged"
}

test_existing_crlf_agents_md_with_section_stays_unchanged() {
  local repo agents out count
  repo="$TMP_ROOT/crlf-formed-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/AGENTS.md"
  printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  cp "$agents" "$repo/.before"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed on CRLF AGENTS.md with the section"
  assert_contains "$out" "unchanged:" "complete CRLF AGENTS.md was not reported unchanged"
  cmp -s "$repo/.before" "$agents" \
    || fail "complete CRLF AGENTS.md was modified"
  count=$(LC_ALL=C grep -a -c '## Maintaining this file' "$agents")
  [ "$count" -eq 1 ] || fail "complete CRLF AGENTS.md has $count self-governance sections"
  pass "fm-ensure-agents-md.sh: CRLF AGENTS.md with the section stays unchanged"
}

test_existing_crlf_agents_md_without_section_preserves_crlf() {
  local repo agents out
  repo="$TMP_ROOT/crlf-injected-project"
  mkdir -p "$repo"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' > "$repo/AGENTS.md"
  printf '@AGENTS.md\n' > "$repo/CLAUDE.md"
  agents="$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1) \
    || fail "fm-ensure-agents-md.sh failed injecting into CRLF AGENTS.md"
  assert_contains "$out" "updated:" "CRLF AGENTS.md injection did not report an update"
  printf '%s\r\n' \
    '# Existing agent memory' \
    '' \
    'Run tests with make test.' \
    '' \
    '## Maintaining this file' \
    '' \
    'Keep this file for knowledge useful to almost every future agent session in this project.' \
    'Do not repeat what the codebase already shows; point to the authoritative file or command instead.' \
    'Prefer rewriting or pruning existing entries over appending new ones.' \
    'When updating this file, preserve this bar for all agents and keep entries concise.' > "$repo/.expected"
  cmp -s "$repo/.expected" "$agents" \
    || fail "CRLF AGENTS.md injection did not preserve CRLF line endings"
  cp "$agents" "$repo/.after-first"
  "$ROOT/bin/fm-ensure-agents-md.sh" "$repo" >/dev/null 2>&1 \
    || fail "fm-ensure-agents-md.sh failed on idempotent CRLF re-run"
  cmp -s "$repo/.after-first" "$agents" \
    || fail "idempotent CRLF re-run modified AGENTS.md"
  pass "fm-ensure-agents-md.sh: CRLF injection preserves line endings idempotently"
}

test_distinct_real_claude_md_still_conflicts() {
  local repo out rc
  repo="$TMP_ROOT/distinct-files-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/AGENTS.md"
  printf '# different real content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for distinct real files"
  assert_contains "$out" "conflict:" "distinct real files did not report a conflict"
  assert_grep "# different real content" "$repo/CLAUDE.md" "distinct real CLAUDE.md was clobbered"
  pass "fm-ensure-agents-md.sh: distinct real CLAUDE.md still conflicts"
}

test_lowercase_agents_md_refuses_case_fragile_import() {
  local repo out rc
  repo="$TMP_ROOT/lowercase-project"
  mkdir -p "$repo"
  printf '# project memory\n' > "$repo/agents.md"
  out=$("$ROOT/bin/fm-ensure-agents-md.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a lowercase agents.md"
  assert_contains "$out" "conflict:" "lowercase agents.md did not report a conflict"
  assert_contains "$out" "agents.md" "conflict message did not name the offending file"
  assert_absent "$repo/CLAUDE.md" "a case-fragile CLAUDE.md import was created for lowercase agents.md"
  assert_present "$repo/agents.md" "the real lowercase agents.md was disturbed"
  pass "fm-ensure-agents-md.sh: refuses a case-variant lowercase agents.md (issue #389)"
}

test_created_agents_md_includes_self_governance
test_promoted_claude_md_includes_self_governance
test_promoted_claude_md_without_trailing_newline_keeps_blank_separator
test_existing_agents_md_with_import_gains_self_governance
test_existing_agents_md_without_claude_gains_section_and_import
test_existing_agents_md_with_section_reports_unchanged
test_materialized_symlink_claude_md_is_rewritten_to_import
test_import_without_agents_md_gets_skeleton
test_legacy_symlink_claude_md_is_accepted_unchanged
test_existing_crlf_agents_md_with_section_stays_unchanged
test_existing_crlf_agents_md_without_section_preserves_crlf
test_distinct_real_claude_md_still_conflicts
test_lowercase_agents_md_refuses_case_fragile_import
