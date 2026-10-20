#!/bin/bash
# factory.sh: the agent-works orchestrator. See docs/design.md, "Orchestrator".
# Usage: factory.sh run | status | stop | issue ISSUE
# Run it in a clone of the target repo, with the verify tools on PATH.
#   run     Builds the issues with agent:ready, limits.concurrent_issues at a time, until none is left.
#           First it continues the issues that a stopped run left in agent:working or agent:checking.
#   status  Shows the agent:* issues and the last ledger record of each issue.
#   stop    Stops the active run and its agents. The labels stay as they are.
#   issue   Runs one attempt for one issue (run uses it).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
usage() { echo "usage: factory.sh run | status | stop | issue ISSUE (in a clone of the target repo)" >&2; exit 2; }
top=$(git rev-parse --show-toplevel 2> /dev/null) && cd "$top" || usage
ledger=.agent-works/ledger.jsonl pidfile=$(git rev-parse --absolute-git-dir)/agent-works.pid
mkdir -p .agent-works && touch "$ledger"

api() { local path=$1; shift; gh api "repos/{owner}/{repo}/$path" "$@"; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
alive() { [ -f "$pidfile" ] && kill -0 "$(cat "$pidfile")" 2> /dev/null; }
tree() { local c; echo "$1"; for c in $(pgrep -P "$1"); do tree "$c"; done; }
config() {
  local d; d=$(git ls-remote --symref origin HEAD | awk '$1 == "ref:" { sub("refs/heads/", "", $2); print $2 }')
  git fetch -q origin "+refs/heads/$d:refs/agent-works/default" && git show refs/agent-works/default:.agent-works/config.json
}
label() { # ISSUE LABEL: replace the agent:* label of the issue
  api "issues/$1/labels" | jq '{labels: ([.[].name | select(startswith("agent:") | not)] + [$l])}' --arg l "$2" \
    | api "issues/$1/labels" -X PUT --input - > /dev/null
}
issues() { # LABEL...: the open issues with one of these labels
  api "issues?state=open&per_page=100" \
    | jq -r '.[] | select(.pull_request | not) | select(any(.labels[].name; IN($ARGS.positional[]))) | .number' --args "$@"
}

done_attempt() { # STATUS: write the ledger line and set the label. The reasons are in $dir/reasons.txt.
  record=$(jq -c --arg st "$1" --arg t "$(now)" --arg pr "${pr:-}" --arg ch "${s:-}" --arg v "${verdict:-}" \
    --slurpfile c "$dir/config.json" --slurpfile b "$dir/build.json" --slurpfile vr "$dir/verify/verifier.raw.json" \
    --rawfile why "$dir/reasons.txt" '($c[0].limits.attempts_per_issue // 3) as $limit
    | .attempts += 1 | .finished = $t | .pr = (if $pr == "" then .pr else ($pr | tonumber) end)
    | .tokens += ($b[0].tokens // 0) + ([$vr[0].usage // {} | .input_tokens, .output_tokens,
        .cache_read_input_tokens, .cache_creation_input_tokens | . // 0] | add)
    | .cost_usd += ($b[0].cost_usd // 0) + ($vr[0].total_cost_usd // 0)
    | .checks += [if $ch == "" then null else $ch end] | .verdicts += [if $v == "" then null else $v end]
    | .reasons = ($why | split("\n") | map(select(. != "")))
    | if $st == "rebuild" and .attempts >= $limit
      then .status = "needs-person" | .reasons += ["the attempt limit (\($limit)) is reached"] else .status = $st end' \
    <<< "$record")
  echo "$record" >> "$ledger"
  echo "#$n: attempt $(jq .attempts <<< "$record"): $(jq -r .status <<< "$record")"
  case $(jq -r .status <<< "$record") in
    rebuild) label "$n" agent:ready ;;
    proposed) label "$n" agent:proposed ;;
    *) label "$n" agent:needs-person
      jq -sr --argjson n "$n" --arg s "$(jq -r .started <<< "$record")" '"agent-works needs a person for this issue.\n"
        + (map(select(.issue == $n and .started == $s) | "\nAttempt \(.attempts):\n" + (.reasons | map("- " + .) | join("\n")))
        | join("\n"))' "$ledger" | api "issues/$n/comments" -X POST -F body=@- > /dev/null ;;
  esac
}

evidence() { # post the check result and the criteria map on the PR
  jq -rn --slurpfile c "$dir/check/result.json" --slurpfile v "$dir/verify/verdict.json" --arg r "$verdict" '
    def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
    "### agent-works evidence for \($c[0].commit[0:7])\n\n" + ($c[0].checks | map("- \(.name): \(.result)"
      + (if .detail then " (\(.detail))" else "" end)) | join("\n")) + "\n\n**Verifier: \($r)**\n\n"
    + "| Criterion | Met | Evidence |\n|---|---|---|\n" + ($v[0].criteria // [] | map("| \(.criterion | cell) | "
      + "\(.met | cell) | \(.evidence | cell) |") | join("\n")) + ($v[0].concerns // [] | if length > 0
      then "\n\nConcerns:\n" + (map("- " + .) | join("\n")) else "" end)' \
    | api "issues/$pr/comments" -X POST -F body=@- > /dev/null
}

issue() { # ISSUE: one attempt: build, check, verify, decide
  n=$1 pr= s= verdict=
  dir=$(mktemp -d "${TMPDIR:-/tmp}/factory-$n.XXXXXX") && mkdir "$dir/verify" || return 1
  echo '{}' > "$dir/build.json" && echo '{}' > "$dir/verify/verifier.raw.json" && : > "$dir/reasons.txt"
  { [ -n "${CONFIG:-}" ] && cat "$CONFIG" || config; } > "$dir/config.json" || return 1
  record=$(jq -c --argjson n "$n" 'select(.issue == $n)' "$ledger" | tail -1)
  [ "$(jq -r .status <<< "${record:-null}")" = rebuild ] || record=$(jq -cn --argjson n "$n" --arg t "$(now)" \
    '{issue: $n, started: $t, attempts: 0, tokens: 0, cost_usd: 0, checks: [], verdicts: [], reasons: [], pr: null}')
  jq -r '.reasons[]' <<< "$record" > "$dir/feedback.txt"
  label "$n" agent:working || return 1
  "$here/build.sh" "$n" "$dir/feedback.txt" > "$dir/build.json"
  pr=$(jq -r '.pr // empty' "$dir/build.json")
  case $(jq -r .status "$dir/build.json") in
    opened) ;;
    needs-person) jq -r .reason "$dir/build.json" > "$dir/reasons.txt"; done_attempt needs-person; return ;;
    *) echo "#$n: build: retry later"; return 0 ;;
  esac
  label "$n" agent:checking || return 1
  for _ in 1 2 3; do
    "$here/check.sh" "$n" "$pr" "$dir/check" > /dev/null
    s=$(jq -r .status "$dir/check/result.json")
    [ "$s" = recheck ] || break
  done
  case $s in
    proposed) ;;
    rebuild | needs-person) jq -r '.reasons[]' "$dir/check/result.json" > "$dir/reasons.txt"; done_attempt "$s"; return ;;
    *) echo "#$n: check: $s"; return 0 ;;
  esac

  # The verifier reads the checked commit, the diff against the base and the test output.
  local commit cmds=() c
  commit=$(jq -r .commit "$dir/check/result.json")
  api "issues/$n" | jq -r '"# \(.title)\n\n\(.body // "")"' > "$dir/issue.md" && api "pulls/$pr" | jq -r '.body // ""' \
    > "$dir/summary.md" && git worktree add -q --detach "$dir/head" "$commit" || { echo "#$n: verify: retry later"; return 0; }
  while IFS= read -r c; do cmds+=("$c"); done < <(jq -r '.checks.verify[]' "$dir/config.json")
  (cd "$dir/head" && "$here/verify.sh" "$dir/verify" "refs/agent-works/pr-$pr/base" "$dir/check/verify.log" \
    "$dir/issue.md" "$dir/summary.md" "${cmds[@]}")
  git worktree remove --force "$dir/head"
  verdict=invalid
  python3 "$here/report.py" verdict "$dir/verify/verdict.json" 2> /dev/null && verdict=$(jq -r .result "$dir/verify/verdict.json")
  api "statuses/$commit" -X POST -f state="$([ "$verdict" = pass ] && echo success || echo failure)" \
    -f context=agent-works/verifier -f description="verifier: $verdict" > /dev/null
  evidence
  jq -r '((.criteria // [])[] | select(.met != true) | "criterion not met: \(.criterion) (\(.evidence))"),
    (.concerns // [])[] | gsub("\\s*\n\\s*"; " ")' "$dir/verify/verdict.json" > "$dir/reasons.txt" 2> /dev/null
  case $verdict in
    pass) gh pr ready "$pr" > /dev/null 2>&1; done_attempt proposed ;;
    fail) done_attempt rebuild ;;
    *) echo "the verifier result is $verdict" >> "$dir/reasons.txt"; done_attempt needs-person ;;
  esac
}

run() {
  alive && { echo "factory.sh: a run is active (pid $(cat "$pidfile"))" >&2; exit 1; }
  echo $$ > "$pidfile"
  local max limit list batch n labels="agent:ready agent:working agent:checking"
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/factory-run.XXXXXX") || exit 1
  trap 'rm -rf "$tmp" "$pidfile"' EXIT
  config > "$tmp/config.json" && export CONFIG=$tmp/config.json || exit 1
  max=$(jq -r '.limits.concurrent_issues // 2' "$CONFIG") limit=$(jq -r '.limits.attempts_per_issue // 3' "$CONFIG")
  while list=$(issues $labels); do
    # One run starts each issue at most "limit" times, so an issue that keeps failing cannot loop.
    batch=$(for n in $list; do [ "$(cat "$tmp/picks-$n" 2> /dev/null | wc -l)" -lt "$limit" ] && echo "$n"; done \
      | awk -v max="$max" 'NR <= max')
    [ -n "$batch" ] || break
    for n in $batch; do echo x >> "$tmp/picks-$n"; issue "$n" & done
    wait
    labels=agent:ready
  done
}

case "${1:-} $#" in
  "run 1") run ;;
  "issue 2") issue "$2" ;;
  "stop 1")
    if alive; then kill $(tree "$(cat "$pidfile")") 2> /dev/null; rm -f "$pidfile"; echo "Stopped. The labels stay as they are."
    else echo "No run is active."; fi ;;
  "status 1")
    alive && echo "A run is active (pid $(cat "$pidfile"))." || echo "No run is active."
    api "issues?state=open&per_page=100" | jq -r '.[] | select(.pull_request | not)
      | (first(.labels[].name | select(startswith("agent:"))) // empty) as $l | "#\(.number)\t\($l)\t\(.title)"'
    jq -sr 'group_by(.issue)[] | last | "#\(.issue): \(.status) after \(.attempts) attempts, PR \(.pr // "-")"' "$ledger" ;;
  *) usage ;;
esac
