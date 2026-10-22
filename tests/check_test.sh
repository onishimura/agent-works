#!/bin/bash
# Offline tests for scripts/check.sh. Each test makes a bare origin repo, a work
# clone where the PR is written, and a check clone where check.sh runs.
# The gh stub in tests/bin replies for GitHub. Helpers: tests/lib.sh.

. "$(dirname "$0")/lib.sh"

setup() { # NAME: make the repos with a small shell project on main
  init_test_dir "$root/$1"
  make_repos
  put .agent-works/config.json '{
  "branch": {"base": "main", "prefix": "agent/"},
  "checks": {"verify": ["sh run-tests.sh"], "fail_first": {"test_globs": ["**/*.test.sh"]}},
  "merge": {"mode": "propose", "protected_paths": [".github/**", ".agent-works/**", "**/auth/**"]}
}'
  put run-tests.sh 'for t in $(find . -name "*.test.sh" | sort); do sh "$t" || { echo "FAIL $t"; exit 1; }; echo "ok $t"; done'
  put math.sh 'add() { echo $(($1 + $2)); }'
  put math.test.sh '. ./math.sh && [ "$(add 2 3)" = 5 ]'
  commit "Add math" && git -C "$T/work" push -q origin main
  git clone -q "$T/origin.git" "$T/clone"
}

add_sub() { # a correct change with a new test
  put sub.sh 'sub() { echo $(($1 - $2)); }'
  put sub.test.sh '. ./sub.sh && [ "$(sub 5 3)" = 2 ]'
}

# --- Tests -----------------------------------------------------------------

test_fail_first_pass() {
  branch agent/42 && add_sub && commit "Add sub" && open_pr && run_check
  expect "exit code" "$rc" 0
  expect status "$(result .status)" proposed
  expect commit "$(result .commit)" "$(head_sha)"
  expect fail-first "$(check_of fail-first)" pass
  expect verify "$(check_of verify)" pass
  expect protected-paths "$(check_of protected-paths)" pass
  expect reasons "$(result '.reasons | length')" 0
  expect "commit status" "$(posted "$(head_sha)")" success
  expect stdout "$(cat "$T/stdout")" "$(cat "$T/out/result.json")"
  expect "worktrees left" "$(git -C "$T/clone" worktree list | wc -l | tr -d ' ')" 1
}

test_fail_first_fails_when_tests_pass_without_change() {
  branch agent/42
  put math.sh 'add() { echo $(($1 + $2)); }  # zero is fine'
  put zero.test.sh '. ./math.sh && [ "$(add 0 0)" = 0 ]'
  commit "Test zero" && open_pr && run_check
  expect status "$(result .status)" rebuild
  expect fail-first "$(check_of fail-first)" fail
  expect verify "$(check_of verify)" pass
  contains reasons "$(result '.reasons[0]')" "pass without the change"
  expect "commit status" "$(posted "$(head_sha)")" failure
}

test_no_test_changes() {
  branch agent/42
  put math.sh 'add() { echo $(($1 + $2 + 0)); }'
  commit "Change add" && open_pr && run_check
  expect status "$(result .status)" rebuild
  expect fail-first "$(check_of fail-first)" fail
  contains detail "$(result '.checks[0].detail')" "no test files"
}

test_docs_issue_skips_fail_first() {
  branch agent/42 && put README.md 'Math helpers.' && commit "Add README" && open_pr
  echo '{"number": 42, "labels": [{"name": "type:docs"}]}' > "$T/gh/issues-42.json"
  run_check
  expect status "$(result .status)" proposed
  expect fail-first "$(check_of fail-first)" skipped
  contains detail "$(result '.checks[0].detail')" "type:docs"
  expect verify "$(check_of verify)" pass
}

test_chore_issue_with_test_changes_skips_fail_first() {
  branch agent/42
  rm "$T/work/math.test.sh" && put zero.test.sh '. ./math.sh && [ "$(add 0 0)" = 0 ]'
  commit "Move the add test" && open_pr
  echo '{"number": 42, "labels": [{"name": "type:chore"}]}' > "$T/gh/issues-42.json"
  run_check
  expect status "$(result .status)" proposed
  expect fail-first "$(check_of fail-first)" skipped
  contains detail "$(result '.checks[0].detail')" "type:chore"
}

test_verify_failure() {
  branch agent/42 && add_sub
  put sub.sh 'sub() { echo $(($1 + $2)); }'
  commit "Add wrong sub" && open_pr && run_check
  expect status "$(result .status)" rebuild
  expect fail-first "$(check_of fail-first)" pass
  expect verify "$(check_of verify)" fail
  contains verify.log "$(cat "$T/out/verify.log")" "FAIL ./sub.test.sh"
}

test_protected_path() {
  branch agent/42 && add_sub && put .github/workflows/ci.yml 'on: push'
  commit "Add sub and CI" && open_pr && run_check
  expect status "$(result .status)" needs-person
  expect protected-paths "$(check_of protected-paths)" fail
  contains detail "$(result '.checks[2].detail')" ".github/workflows/ci.yml"
  expect fail-first "$(check_of fail-first)" pass
  expect verify "$(check_of verify)" pass
  expect "commit status" "$(posted "$(head_sha)")" failure
}

test_config_comes_from_base() {
  branch agent/42 && add_sub
  put sub.sh 'sub() { echo $(($1 + $2)); }'
  put .agent-works/config.json "$(jq '.checks.verify = ["true"]' "$T/work/.agent-works/config.json")"
  commit "Wrong sub, weaker config" && open_pr && run_check
  expect status "$(result .status)" needs-person
  expect verify "$(check_of verify)" fail
  contains detail "$(result '.checks[2].detail')" ".agent-works/config.json"
}

test_pr_code_cannot_change_the_check_state() {
  # The test code runs in a worktree in the check's temp directory, and it tries to change the check's files there.
  branch agent/42 && add_sub && put sub.sh 'sub() { echo $(($1 + $2)); }' && put .github/workflows/ci.yml 'on: push'
  put sub.test.sh 'echo "{\"checks\": {\"verify\": [\"true\"]}}" > ../config.json; : > ../protected.txt
. ./sub.sh && [ "$(sub 5 3)" = 2 ]'
  commit "Wrong sub that changes the check files" && open_pr && run_check
  expect status "$(result .status)" needs-person
  expect verify "$(check_of verify)" fail
  expect protected-paths "$(check_of protected-paths)" fail
}

test_config_with_wrong_types_needs_a_person() {
  local good f; good=$(cat "$T/work/.agent-works/config.json")
  for f in '.checks.verify = "sh run-tests.sh"' '.checks.verify += [""]' '.merge.protected_paths = ".github/**"'; do
    git -C "$T/work" checkout -q main
    put .agent-works/config.json "$(jq "$f" <<< "$good")" && commit "Config: $f" && git -C "$T/work" push -q origin main
    branch agent/42 && put README.md "Docs: $f" && put .github/workflows/ci.yml 'on: push' && commit "Docs and CI" && open_pr
    echo '{"number": 42, "labels": [{"name": "type:docs"}]}' > "$T/gh/issues-42.json"
    run_check
    expect "status with $f" "$(result .status)" needs-person
    contains "reason with $f" "$(result '.reasons[0]')" "no valid .agent-works/config.json"
  done
}

test_head_moved() {
  branch agent/42 && add_sub && commit "Add sub" && open_pr
  jq '.head.sha = "1111111111111111111111111111111111111111"' "$T/gh/pulls-57.json" > "$T/gh/pulls-57.2.json"
  run_check
  expect status "$(result .status)" recheck
  expect commit "$(result .commit)" "$(head_sha)"
  contains reasons "$(result '.reasons[0]')" "moved"
  expect "commit status" "$(posted "$(head_sha)")" ""
}

test_base_conflict() {
  branch agent/42 && put math.sh 'add() { expr "$1" + "$2"; }' && commit "Use expr" && open_pr
  local pr_head; pr_head=$(head_sha)
  git -C "$T/work" checkout -q main
  put math.sh 'add() { echo $(( $1 + $2 )); }' && commit "Add spaces" && git -C "$T/work" push -q origin main
  run_check
  expect status "$(result .status)" rebuild
  contains reasons "$(result '.reasons[0]')" "math.sh"
  expect checks "$(result '.checks | length')" 0
  expect "commit status" "$(posted "$pr_head")" failure
}

test_wrong_base() {
  git -C "$T/work" push -q origin main:release
  branch agent/42 && add_sub && commit "Add sub" && open_pr release && run_check
  expect status "$(result .status)" needs-person
  contains reasons "$(result '.reasons[0]')" "release"
  expect checks "$(result '.checks | length')" 0
}

test_github_down() {
  branch agent/42 && add_sub && commit "Add sub" && open_pr
  rm "$T/gh/pulls-57.json"
  run_check
  expect "exit code" "$rc" 0
  expect status "$(result .status)" retry-later
  expect commit "$(result .commit)" null
  expect "status posts" "$(grep -c statuses "$T/gh/calls.log")" 0
}

test_status_post_fails() {
  branch agent/42 && add_sub && commit "Add sub" && open_pr
  touch "$T/gh/fail-writes"
  run_check
  expect status "$(result .status)" retry-later
  contains reasons "$(result '.reasons[-1]')" "commit status"
}

test_usage_error() {
  (cd "$T/clone" && "$CHECK") > /dev/null 2>&1; rc=$?
  expect "exit code" "$rc" 2
  [ ! -e "$T/out" ] || fail "an output directory was made"
}

test_example_config_has_the_keys_check_reads() {
  jq -e '(.branch.base | type == "string") and (.checks.verify | length > 0)
    and (.checks.fail_first.test_globs | length > 0) and (.merge.protected_paths | length > 0)' \
    "$TESTS_DIR/../config.example.json" > /dev/null || fail "config.example.json is not valid"
}

run_tests
