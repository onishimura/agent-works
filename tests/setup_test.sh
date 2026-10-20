#!/bin/bash
# Offline tests for scripts/setup.sh. The gh stub records the label calls.
# Helpers: tests/lib.sh.

. "$(dirname "$0")/lib.sh"
SETUP=$TESTS_DIR/../scripts/setup.sh

setup() { # NAME: a target repo clone with one commit
  init_test_dir "$root/$1"
  make_repos
  put README.md 'A target repo.' && commit "Base"
}

run_setup() { (cd "$T/work" && "$SETUP") > "$T/stdout" 2> "$T/stderr"; rc=$?; }
label_posts() { grep -c '^api repos/{owner}/{repo}/labels -X POST' "$T/gh/calls.log"; }

test_creates_labels_config_ignore_and_skill_link() {
  run_setup
  expect "exit code" "$rc" 0
  expect "label posts" "$(label_posts)" 7
  grep -q 'name=agent:ready .*description=Ready for the builder' "$T/gh/calls.log" || fail "no agent:ready label"
  grep -q 'name=type:chore ' "$T/gh/calls.log" || fail "no type:chore label"
  expect config "$(cat "$T/work/.agent-works/config.json")" "$(cat "$TESTS_DIR/../config.example.json")"
  expect ignore "$(cat "$T/work/.gitignore")" ".agent-works/ledger.jsonl"
  [ -f "$T/.claude/skills/agent-works/SKILL.md" ] || fail "the skill is not linked"
  expect "git status" "$(git -C "$T/work" status --porcelain | sort | tr '\n' ' ')" "?? .agent-works/ ?? .gitignore "
}

test_runs_again_without_changes() {
  run_setup
  echo '{"custom": true}' > "$T/work/.agent-works/config.json"
  echo 'exit 1' > "$T/gh/labels.write.sh"   # the labels exist, so a POST fails
  run_setup
  expect "exit code" "$rc" 0
  expect "kept config" "$(cat "$T/work/.agent-works/config.json")" '{"custom": true}'
  expect "one ignore line" "$(grep -c ledger "$T/work/.gitignore")" 1
  expect "label updates" "$(grep -c '^api repos/{owner}/{repo}/labels/.* -X PATCH' "$T/gh/calls.log")" 7
}

test_label_failure_stops() {
  touch "$T/gh/fail-writes"
  run_setup
  expect "exit code" "$rc" 1
  contains error "$(cat "$T/stderr")" "could not create the label agent:ready"
}

test_usage_error_outside_a_repo() {
  (cd "$T" && "$SETUP") > /dev/null 2>&1; rc=$?
  expect "exit code" "$rc" 2
}

run_tests
