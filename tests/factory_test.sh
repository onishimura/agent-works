#!/bin/bash
# Offline tests for scripts/factory.sh. build.sh, check.sh and verify.sh run for
# real. The claude stub plays the builder and the verifier. The gh stub keeps
# labels and PRs with the handler scripts below. Helpers: tests/lib.sh.

. "$(dirname "$0")/lib.sh"
FACTORY=$TESTS_DIR/../scripts/factory.sh

setup() { # NAME: a small shell project on main, a builder that adds a tested change, a verifier that passes
  init_test_dir "$root/$1"
  export CLAUDE_STUB_DIR=$T/claude
  mkdir -p "$CLAUDE_STUB_DIR"
  make_repos
  # As GitHub does, a push to agent/N moves refs/pull/<100+N>/head.
  cat > "$T/origin.git/hooks/post-receive" << 'EOF'
while read -r old new ref; do
  case $ref in refs/heads/agent/*) git update-ref "refs/pull/$((100 + ${ref#refs/heads/agent/}))/head" "$new" ;; esac
done
EOF
  chmod +x "$T/origin.git/hooks/post-receive"
  config 3
  put run-tests.sh 'for t in tests/*.test.sh; do sh "$t" || { echo "FAIL $t"; exit 1; }; echo "ok $t"; done'
  put tests/math.test.sh '[ $((2 + 3)) = 5 ]'
  commit "Base" && git -C "$T/work" push -q origin main
  git clone -q "$T/origin.git" "$T/clone"
  github
  builder 'echo "sub() { echo \$((\$1 - \$2)); }" > sub.sh && echo ". ./sub.sh && [ \"\$(sub 5 3)\" = 2 ]" > tests/sub.test.sh && git add -A && git commit -qm "Add sub"'
  echo '{"status": "done", "title": "Add sub", "summary": "## Summary\n- Added sub."}' > "$CLAUDE_STUB_DIR/builder.json"
  verdict pass true "test: tests/sub.test.sh" > "$CLAUDE_STUB_DIR/verifier.json"
}

config() { # ATTEMPTS: write the config on main
  put .agent-works/config.json "{
  \"branch\": {\"base\": \"main\", \"prefix\": \"agent/\"},
  \"checks\": {\"verify\": [\"sh run-tests.sh\"], \"fail_first\": {\"test_globs\": [\"tests/**\"]}},
  \"limits\": {\"concurrent_issues\": 2, \"attempts_per_issue\": $1},
  \"merge\": {\"mode\": \"propose\", \"protected_paths\": [\".agent-works/**\"]}
}"
}

github() { # gh stub handlers: labels, the issue list and PRs (issue N gets PR 100+N)
  local g=$T/gh
  cat > "$g/issues-state-open-per_page-100.sh" << EOF
for n in \$(cat "$g/issue-list" 2> /dev/null); do
  jq -n --argjson n "\$n" --argjson l "\$(bash "$g/issues-\$n-labels.sh")" '{number: \$n, title: "Issue \(\$n)", labels: \$l}'
done | jq -s .
EOF
  cat > "$g/pulls.write.sh" << EOF
for a in "\$@"; do case \$a in head=*) b=\${a#head=} ;; esac; done
echo "\$b" > "$g/pr-\$((100 + \${b#agent/}))"
echo "{\"number\": \$((100 + \${b#agent/}))}"
EOF
  cat > "$g/pulls-state-open-per_page-100.sh" << EOF
for f in "$g"/pr-*; do [ -f "\$f" ] && jq -n --argjson n "\${f##*-}" --arg b "\$(cat "\$f")" '{number: \$n, head: {ref: \$b}}'; done | jq -s .
EOF
}

add_issue() { # N [BODY]: an open issue with the label agent:ready
  local g=$T/gh
  echo "$1" >> "$g/issue-list"
  jq -n --argjson n "$1" --arg body "${2:-## Goal
Subtract.

## Acceptance criteria
- [ ] sub 5 3 prints 2}" '{number: $n, title: "Issue \($n)", body: $body, labels: []}' > "$g/issues-$1.json"
  cat > "$g/issues-$1-labels.sh" << EOF
if [ -f "$g/issues-$1-labels.input" ]; then jq '[.labels[] | {name: .}]' "$g/issues-$1-labels.input"
else echo '[{"name": "agent:ready"}, {"name": "bug"}]'; fi
EOF
  cat > "$g/pulls-$((100 + $1)).sh" << EOF
jq -n --arg sha "\$(git -C "$T/origin.git" rev-parse refs/heads/agent/$1)" \\
  '{number: $((100 + $1)), body: "## Summary\n- Added sub.", head: {sha: \$sha, ref: "agent/$1"},
    base: {ref: "main", repo: {default_branch: "main"}}}'
EOF
}

builder() { printf '%s\n' "$1" > "$CLAUDE_STUB_DIR/builder.sh"; }
verdict() { # RESULT MET EVIDENCE [CONCERN]: a criteria map
  jq -n --arg r "$1" --argjson met "$2" --arg e "$3" --arg c "${4:-}" \
    '{result: $r, criteria: [{criterion: "sub 5 3 prints 2", met: $met, evidence: $e}],
      concerns: (if $c == "" then [] else [$c] end)}'
}
factory() { (cd "$T/clone" && "$FACTORY" "$@") > "$T/stdout" 2> "$T/stderr"; rc=$?; }
labels_of() { bash "$T/gh/issues-$1-labels.sh" | jq -r '[.[].name] | join(",")'; }
ledger() { jq -sc "$1" "$T/clone/.agent-works/ledger.jsonl"; }
status_of() { grep "statuses/.* context=$1" "$T/gh/calls.log" | sed -n 's/.*state=\([a-z]*\).*/\1/p' | tail -1; }

# --- Tests -------------------------------------------------------------------

test_issue_reaches_proposed() {
  add_issue 42 && factory issue 42
  expect labels "$(labels_of 42)" bug,agent:proposed
  expect ledger "$(ledger 'map({attempts, status, checks, verdicts, pr, tokens, cost_usd})')" \
    '[{"attempts":1,"status":"proposed","checks":["proposed"],"verdicts":["pass"],"pr":142,"tokens":2400,"cost_usd":0.5}]'
  expect "checks status" "$(status_of agent-works/checks)" success
  expect "verifier status" "$(status_of agent-works/verifier)" success
  grep -q '^pr ready 142$' "$T/gh/calls.log" || fail "the PR was not marked ready"
  contains evidence "$(cat "$T/gh/issues-142-comments.input")" "| sub 5 3 prints 2 | true | test: tests/sub.test.sh |"
  contains stdout "$(cat "$T/stdout")" "#42: attempt 1: proposed"
}

test_verifier_fail_rebuilds_with_feedback() {
  add_issue 42
  verdict fail false "no test for 5 3" "false claim: the README changed" > "$CLAUDE_STUB_DIR/verifier.1.json"
  factory run
  expect labels "$(labels_of 42)" bug,agent:proposed
  expect ledger "$(ledger 'map({attempts, status, verdicts})')" \
    '[{"attempts":1,"status":"rebuild","verdicts":["fail"]},{"attempts":2,"status":"proposed","verdicts":["fail","pass"]}]'
  expect "same record" "$(ledger 'map(.started) | unique | length')" 1
  contains feedback "$(cat "$CLAUDE_STUB_DIR/calls.log")" $'<feedback>\ncriterion not met: sub 5 3 prints 2 (no test for 5 3)\nfalse claim: the README changed\n</feedback>'
  grep -q '^api repos/{owner}/{repo}/pulls/142 -X PATCH' "$T/gh/calls.log" || fail "the rebuild did not update PR #142"
}

test_attempt_limit_goes_to_a_person() {
  config 2 && commit "Two attempts" && git -C "$T/work" push -q origin main
  add_issue 42
  verdict fail false "missing" > "$CLAUDE_STUB_DIR/verifier.json"
  factory run
  expect labels "$(labels_of 42)" bug,agent:needs-person
  expect ledger "$(ledger 'map(.status)')" '["rebuild","needs-person"]'
  contains comment "$(cat "$T/gh/issues-42-comments.input")" $'Attempt 1:\n- criterion not met: sub 5 3 prints 2 (missing)'
  contains comment "$(cat "$T/gh/issues-42-comments.input")" $'Attempt 2:\n- criterion not met: sub 5 3 prints 2 (missing)\n- the attempt limit (2) is reached'
  expect "verifier status" "$(status_of agent-works/verifier)" failure
}

test_unsure_goes_to_a_person() {
  add_issue 42
  verdict unsure null "no evidence either way" "regression: maybe" > "$CLAUDE_STUB_DIR/verifier.json"
  factory issue 42
  expect labels "$(labels_of 42)" bug,agent:needs-person
  contains comment "$(cat "$T/gh/issues-42-comments.input")" "the verifier result is unsure"
  contains comment "$(cat "$T/gh/issues-42-comments.input")" "regression: maybe"
}

test_invalid_verdict_goes_to_a_person() {
  add_issue 42
  verdict pass true " " > "$CLAUDE_STUB_DIR/verifier.json"
  factory issue 42
  expect labels "$(labels_of 42)" bug,agent:needs-person
  expect verdicts "$(ledger 'map(.verdicts)')" '[["invalid"]]'
  expect "verifier status" "$(status_of agent-works/verifier)" failure
}

test_check_failure_skips_the_verifier() {
  add_issue 42
  builder 'echo x > code.sh && git add -A && git commit -qm "Code without tests"'
  factory issue 42
  expect labels "$(labels_of 42)" bug,agent:ready
  expect ledger "$(ledger 'map({status, checks, verdicts})')" '[{"status":"rebuild","checks":["rebuild"],"verdicts":[null]}]'
  [ ! -f "$CLAUDE_STUB_DIR/verifier.count" ] || fail "the verifier ran"
}

test_issue_without_criteria_goes_to_a_person() {
  add_issue 42 "Make it better."
  factory issue 42
  expect labels "$(labels_of 42)" bug,agent:needs-person
  contains comment "$(cat "$T/gh/issues-42-comments.input")" "no acceptance criteria"
}

test_two_issues_run_in_parallel() {
  add_issue 42 && add_issue 43
  builder "echo start \$(date +%s) >> '$T/times' && sleep 2 && echo end \$(date +%s) >> '$T/times' && $(cat "$CLAUDE_STUB_DIR/builder.sh")"
  factory run
  expect labels "$(labels_of 42) $(labels_of 43)" "bug,agent:proposed bug,agent:proposed"
  expect issues "$(ledger 'map(.issue) | sort')" '[42,43]'
  # Both builders started before the first one ended.
  expect overlap "$(sed -n 2p "$T/times" | cut -d' ' -f1)" start
}

test_stop_and_resume() {
  add_issue 42
  local fast; fast=$(cat "$CLAUDE_STUB_DIR/builder.sh")
  builder "touch '$T/started' && sleep 30"
  (cd "$T/clone" && "$FACTORY" run > "$T/run1.log" 2>&1) &
  local job=$! i=0
  while [ ! -f "$T/started" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  factory stop
  contains stop "$(cat "$T/stdout")" "Stopped"
  wait "$job"
  expect "label after stop" "$(labels_of 42)" bug,agent:working
  expect "ledger after stop" "$(ledger length)" 0
  [ ! -f "$T/clone/.git/agent-works.pid" ] || fail "the pid file is still there"
  builder "$fast"
  factory run
  expect "label after resume" "$(labels_of 42)" bug,agent:proposed
  expect "ledger after resume" "$(ledger 'map({attempts, status})')" '[{"attempts":1,"status":"proposed"}]'
}

test_status_shows_labels_and_ledger() {
  add_issue 42 && factory issue 42 && factory status
  contains status "$(cat "$T/stdout")" "No run is active."
  contains status "$(cat "$T/stdout")" $'#42\tagent:proposed\tIssue 42'
  contains status "$(cat "$T/stdout")" "#42: proposed after 1 attempts, PR 142"
}

test_only_one_run_at_a_time() {
  sleep 30 & local other=$!
  echo "$other" > "$T/clone/.git/agent-works.pid"
  factory run
  kill "$other"
  expect "exit code" "$rc" 1
  contains error "$(cat "$T/stderr")" "a run is active"
}

test_usage_error() {
  factory issue
  expect "exit code" "$rc" 2
}

run_tests
