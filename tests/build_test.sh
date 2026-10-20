#!/bin/bash
# Offline tests for scripts/build.sh. The claude stub acts as the builder: it
# runs $CLAUDE_STUB_DIR/act.sh in the worktree. The gh stub replies for GitHub.
# Helpers: tests/lib.sh.

. "$(dirname "$0")/lib.sh"
BUILD=$TESTS_DIR/../scripts/build.sh

setup() { # NAME: make the repos with a config on main, and an issue with criteria
  init_test_dir "$root/$1"
  export CLAUDE_STUB_DIR=$T/claude
  mkdir -p "$CLAUDE_STUB_DIR"
  make_repos
  put .agent-works/config.json '{
  "branch": {"base": "main", "prefix": "agent/"},
  "checks": {"verify": ["sh run-tests.sh"], "fail_first": {"test_globs": ["tests/**"]}},
  "merge": {"mode": "propose", "protected_paths": [".github/**", ".agent-works/**"]}
}'
  put run-tests.sh 'echo ok'
  commit "Base" && git -C "$T/work" push -q origin main
  git clone -q "$T/origin.git" "$T/clone"
  jq -n '{number: 42, title: "Add a greeting", body: "## Goal\nGreet.\n\n## Acceptance criteria\n- [ ] Prints hello\n"}' \
    > "$T/gh/issues-42.json"
  echo '{"number": 57}' > "$T/gh/pulls.write.json"
  echo '[]' > "$T/gh/pulls-state-open-per_page-100.json"
  echo '{"status": "done", "title": "Add a greeting", "summary": "## Summary\n- Added hello.sh."}' \
    > "$CLAUDE_STUB_DIR/output.json"
  act 'echo hello > hello.sh && mkdir -p tests && echo test > tests/hello.test && git add -A && git commit -qm "Add hello"'
}

act() { printf '%s\n' "$1" > "$CLAUDE_STUB_DIR/act.sh"; }
run_build() { (cd "$T/clone" && "$BUILD" 42) > "$T/stdout" 2> "$T/stderr"; rc=$?; }
field() { jq -r "$@" "$T/stdout"; }
log() { cat "$CLAUDE_STUB_DIR/calls.log" 2> /dev/null; }
pr_posts() { grep -c '^api repos/{owner}/{repo}/pulls -X POST' "$T/gh/calls.log"; }

test_opens_a_draft_pr() {
  run_build
  expect "exit code" "$rc" 0
  expect status "$(field .status)" opened
  expect pr "$(field .pr)" 57
  expect branch "$(field .branch)" agent/42
  expect commit "$(field .commit)" "$(git -C "$T/origin.git" rev-parse agent/42)"
  expect "pushed commit" "$(git -C "$T/origin.git" log -1 --format=%s agent/42)" "Add hello"
  expect author "$(git -C "$T/origin.git" log -1 --format=%an agent/42)" "agent-works builder"
  expect tokens "$(field .tokens)" 1200
  expect denied "$(field -c .denied)" '[]'
  local post; post=$(grep 'pulls -X POST' "$T/gh/calls.log")
  contains "draft PR" "$post" "draft=true"
  contains "PR base" "$post" "base=main"
  contains "PR head" "$post" "head=agent/42"
  contains "PR body" "$(cat "$T/gh/calls.log")" $'- Added hello.sh.\n\nCloses #42'
  contains "PR title" "$post" "title=Add a greeting"
}

test_result_lists_denied_commands() {
  echo '[{"tool_name": "Bash", "tool_input": {"command": "export PATH=/x:$PATH"}}, {"tool_name": "WebFetch", "tool_input": {}}]' \
    > "$CLAUDE_STUB_DIR/denials.json"
  run_build
  expect denied "$(field -c .denied)" '["export PATH=/x:$PATH","WebFetch"]'
}

test_builder_works_only_in_its_worktree() {
  run_build
  local cwd; cwd=$(log | sed -n 's/^cwd: //p')
  case $cwd in "$T/clone" | "$T/clone/"*) fail "the builder ran in the clone: $cwd" ;; esac
  expect "clone status" "$(git -C "$T/clone" status --porcelain)" ""
  expect "worktrees left" "$(git -C "$T/clone" worktree list | wc -l | tr -d ' ')" 1
}

test_prompt_and_permissions() {
  run_build
  local log; log=$(log)
  contains issue "$log" "# Add a greeting"
  contains "verify command" "$log" "- sh run-tests.sh"
  contains "protected path" "$log" "- .agent-works/**"
  contains "allowed verify command" "$log" "arg: Bash(sh run-tests.sh:*)"
  contains "denied push" "$log" "arg: Bash(git push:*)"
  contains "no prompts" "$log" "arg: none"
  case $log in *"arg: Bash(git:*)"* | *"arg: bypassPermissions"*) fail "the builder has too many permissions" ;; esac
  grep -q '^## Output' "$CLAUDE_STUB_DIR/system-prompt.md" || fail "the system prompt is not the builder body"
}

test_rebuild_gets_feedback_and_updates_the_open_pr() {
  echo '[{"number": 3, "head": {"ref": "agent/7"}}, {"number": 57, "head": {"ref": "agent/42"}}]' \
    > "$T/gh/pulls-state-open-per_page-100.json"
  printf '%s\n' "verify: 'sh run-tests.sh' fails" "false claim: the README changed" > "$T/feedback.txt"
  (cd "$T/clone" && "$BUILD" 42 "$T/feedback.txt") > "$T/stdout" 2> "$T/stderr"
  expect status "$(field .status)" opened
  expect pr "$(field .pr)" 57
  expect "PR posts" "$(pr_posts)" 0
  grep -q '^api repos/{owner}/{repo}/pulls/57 -X PATCH' "$T/gh/calls.log" || fail "the open PR was not updated"
  contains feedback "$(log)" $'<feedback>\nverify: \'sh run-tests.sh\' fails\nfalse claim: the README changed\n</feedback>'
}

test_summary_with_escaped_line_breaks_is_fixed() {
  echo '{"status": "done", "title": "t", "summary": "## Summary\\n- Added hello.sh.\\n\\n## Tests\\n- ok"}' > "$CLAUDE_STUB_DIR/output.json"
  run_build
  contains "PR body" "$(cat "$T/gh/calls.log")" $'body=## Summary\n- Added hello.sh.\n\n## Tests\n- ok\n\nCloses #42'
}

test_summary_with_line_breaks_is_kept() {
  echo '{"status": "done", "title": "t", "summary": "## Summary\n- Split on `\\n` now."}' > "$CLAUDE_STUB_DIR/output.json"
  run_build
  contains "PR body" "$(cat "$T/gh/calls.log")" $'body=## Summary\n- Split on `\\n` now.'
}

test_first_attempt_has_no_feedback() {
  run_build
  case $(log) in *"<feedback>"*) fail "the first attempt got feedback" ;; esac
}

test_issue_without_criteria() {
  jq -n '{number: 42, title: "Vague", body: "Make it better."}' > "$T/gh/issues-42.json"
  run_build
  expect status "$(field .status)" needs-person
  contains reason "$(field .reason)" "no acceptance criteria"
  [ ! -s "$CLAUDE_STUB_DIR/calls.log" ] || fail "the builder ran"
}

test_builder_blocked() {
  echo '{"status": "blocked", "title": "x", "summary": "## Summary\nA criterion needs a protected path.\n\n## How to unblock\n- Allow it."}' \
    > "$CLAUDE_STUB_DIR/output.json"
  run_build
  expect status "$(field .status)" needs-person
  expect reason "$(field .reason)" "the builder is blocked: Summary A criterion needs a protected path. How to unblock - Allow it."
  git -C "$T/origin.git" rev-parse -q --verify agent/42 > /dev/null && fail "the branch was pushed"
  expect "PR posts" "$(pr_posts)" 0
}

test_no_commits() {
  act 'true'
  run_build
  expect status "$(field .status)" needs-person
  contains reason "$(field .reason)" "no commits"
}

test_uncommitted_changes() {
  act 'echo hello > hello.sh'
  run_build
  expect status "$(field .status)" needs-person
  contains reason "$(field .reason)" "uncommitted changes"
  expect "PR posts" "$(pr_posts)" 0
}

test_builder_changed_branch() {
  act 'git checkout -q -b other && echo x > x && git add -A && git commit -qm x'
  run_build
  expect status "$(field .status)" needs-person
  contains reason "$(field .reason)" "left the branch"
}

test_github_down() {
  rm "$T/gh/issues-42.json"
  run_build
  expect "exit code" "$rc" 0
  expect status "$(field .status)" retry-later
}

test_usage_error() {
  (cd "$T/clone" && "$BUILD" abc) > /dev/null 2>&1; rc=$?
  expect "exit code" "$rc" 2
}

run_tests
