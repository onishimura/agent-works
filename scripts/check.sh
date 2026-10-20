#!/bin/bash
# check.sh: the fixed checks for one agent PR. See docs/design.md, "Check script".
# Usage: check.sh ISSUE PR OUT_DIR   (run it in a clone of the target repo)
# It writes OUT_DIR/result.json, prints it, and posts a commit status.
# Exit 0: a result was written. Exit 2: usage error. The "status" field is the decision.
set -uo pipefail

usage() { echo "usage: check.sh ISSUE PR OUT_DIR (in a clone of the target repo)" >&2; exit 2; }
[ $# -eq 3 ] && git rev-parse --git-dir > /dev/null 2>&1 || usage
issue=$1 pr=$2 head= failed=
for n in "$issue" "$pr"; do case $n in '' | *[!0-9]*) usage ;; esac; done
mkdir -p "$3" && out=$(cd "$3" && pwd) && : > "$out/checks.jsonl" && : > "$out/reasons.jsonl" || usage
tmp=$(mktemp -d "${TMPDIR:-/tmp}/check.XXXXXX") || exit 1
trap 'rm -rf "$tmp"; git worktree prune' EXIT
ref=refs/agent-works/pr-$pr

api() { local path=$1; shift; gh api "repos/{owner}/{repo}/$path" "$@"; }
reason() { jq -n --arg r "$1" '$r' >> "$out/reasons.jsonl"; }

check() { # NAME RESULT [DETAIL]: add a check to the result; a failed check is also a reason
  jq -cn --arg n "$1" --arg r "$2" --arg d "${3:-}" \
    '{name: $n, result: $r} + if $d == "" then {} else {detail: $d} end' >> "$out/checks.jsonl"
  [ "$2" != fail ] || reason "$1: ${3:-}"
}

finish() { # STATUS [REASON]: post the commit status, write the result and exit
  local status=$1 state=
  [ -z "${2:-}" ] || reason "$2"
  case $status in proposed) state=success ;; rebuild | needs-person) state=failure ;; esac
  if [ -n "$state" ] && ! api "statuses/$head" -X POST -f state="$state" -f context=agent-works/checks \
    -f description="$(jq -rs '.[0] // "all checks pass"' "$out/reasons.jsonl" | cut -c1-140)" > /dev/null; then
    status=retry-later
    reason "could not post the commit status"
  fi
  jq -n --arg issue "$issue" --arg pr "$pr" --arg commit "$head" --arg status "$status" \
    --slurpfile checks "$out/checks.jsonl" --slurpfile reasons "$out/reasons.jsonl" \
    '{issue: ($issue | tonumber), pr: ($pr | tonumber), commit: (if $commit == "" then null else $commit end),
      status: $status, checks: $checks, reasons: $reasons}' | tee "$out/result.json"
  exit 0
}

head_now() { api "pulls/$pr" > "$tmp/pr.json" && jq -er .head.sha "$tmp/pr.json"; }

changed() { # CONFIG_PATH DIFF_OPTION: diff the PR, only the files that match the globs at CONFIG_PATH
  local specs=() g
  while IFS= read -r g; do specs+=(":(glob)$g"); done < <(jq -r "($1 // [])[]" "$cfg")
  [ ${#specs[@]} -eq 0 ] || git diff-tree -r "$2" "$mb" "$head" -- "${specs[@]}"
}

run_verify() { # DIR LOG: run the verify commands in DIR; at the first failure, set $failed
  local cmd
  : > "$2"
  while IFS= read -r cmd; do
    echo "\$ $cmd" >> "$2"
    (cd "$1" && bash -c "$cmd") < /dev/null >> "$2" 2>&1 || { failed=$cmd; return 1; }
  done < <(jq -r '.checks.verify[]' "$cfg")
}

# Read the PR and fetch its head, its base and the default branch.
head=$(head_now) || { head=; finish retry-later "could not read PR #$pr from GitHub"; }
base=$(jq -r .base.ref "$tmp/pr.json") default=$(jq -r .base.repo.default_branch "$tmp/pr.json")
git fetch -q origin "+refs/heads/$default:$ref/default" "+refs/heads/$base:$ref/base" \
  "+refs/pull/$pr/head:$ref/head" && git cat-file -e "$head^{commit}" \
  || finish retry-later "could not fetch PR #$pr and its base from origin"

# The config comes from the default branch, never from the PR.
cfg=$tmp/config.json
git show "$ref/default:.agent-works/config.json" > "$cfg" 2> /dev/null \
  && jq -e '.checks.verify | length > 0' "$cfg" > /dev/null 2>&1 \
  || finish needs-person "no valid .agent-works/config.json on $default"
want=$(jq -r .branch.base "$cfg")
[ "$base" = "$want" ] || finish needs-person "the PR targets $base, not $want"

base_sha=$(git rev-parse "$ref/base")
git merge-tree --write-tree --name-only --no-messages "$base_sha" "$head" > "$tmp/merge.txt" \
  || finish rebuild "the base does not merge in; conflicts: $(tail -n +2 "$tmp/merge.txt" | paste -sd ' ' -)"
mb=$(git merge-base "$base_sha" "$head")
changed .merge.protected_paths --name-only > "$tmp/protected.txt"
changed .checks.fail_first.test_globs --binary > "$out/tests.diff"

# Fail-first: the PR's test changes, without the rest of the PR, must make a verify command fail.
# A docs or chore issue adds no behavior (it can even remove tests), so it skips this check.
api "issues/$issue" > "$tmp/issue.json" || finish retry-later "could not read issue #$issue from GitHub"
if jq -e '[.labels[].name] | any(. == "type:docs" or . == "type:chore")' "$tmp/issue.json" > /dev/null; then
  check fail-first skipped "the issue has the label type:docs or type:chore"
elif [ ! -s "$out/tests.diff" ]; then
  check fail-first fail "the PR changes no test files"
else
  git worktree add -q --detach "$tmp/base" "$mb" && git -C "$tmp/base" apply "$out/tests.diff" \
    || finish needs-person "could not apply the test changes at the merge base"
  if run_verify "$tmp/base" "$out/fail-first.log"; then
    check fail-first fail "the new tests pass without the change"
  else
    check fail-first pass "without the change, '$failed' fails"
  fi
fi

# Verify: all verify commands pass at the PR head.
git worktree add -q --detach "$tmp/head" "$head" || finish retry-later "could not check out the PR head"
if run_verify "$tmp/head" "$out/verify.log"; then
  n=$(jq '.checks.verify | length' "$cfg")
  check verify pass "$n/$n verify commands pass"
else
  check verify fail "'$failed' fails; see verify.log"
fi

if [ -s "$tmp/protected.txt" ]; then
  check protected-paths fail "$(paste -sd ' ' - < "$tmp/protected.txt")"
else
  check protected-paths pass
fi

now=$(head_now) || finish retry-later "could not read PR #$pr from GitHub"
[ "$now" = "$head" ] || finish recheck "the PR head moved during the check"
if [ -s "$tmp/protected.txt" ]; then finish needs-person; fi
if jq -se 'any(.result == "fail")' "$out/checks.jsonl" > /dev/null; then finish rebuild; fi
finish proposed
