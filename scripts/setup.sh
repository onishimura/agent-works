#!/bin/bash
# setup.sh: prepare a target repo for agent-works. See README.md, "Quick start".
# Usage: setup.sh   (run it in a clone of the target repo)
# It creates or updates the labels on GitHub, writes .agent-works/config.json from
# config.example.json if it is missing, ignores the ledger, and links the skill into
# ~/.claude/skills. It does not commit or push.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
top=$(git rev-parse --show-toplevel 2> /dev/null) && cd "$top" \
  || { echo "usage: setup.sh (in a clone of the target repo)" >&2; exit 2; }
for tool in git gh jq python3 claude; do command -v "$tool" > /dev/null || echo "setup.sh: $tool is missing" >&2; done

while IFS='|' read -r name color text; do
  gh api "repos/{owner}/{repo}/labels" -X POST -f name="$name" -f color="$color" -f description="$text" > /dev/null 2>&1 \
    || gh api "repos/{owner}/{repo}/labels/$name" -X PATCH -f color="$color" -f description="$text" > /dev/null \
    || { echo "setup.sh: could not create the label $name" >&2; exit 1; }
done << 'EOF'
agent:ready|0E8A16|Ready for the builder. Only a person adds this label
agent:working|FBCA04|A builder has the issue
agent:checking|1D76DB|A draft PR exists; the checks and the verifier run
agent:proposed|5319E7|All checks pass; a person merges the PR
agent:needs-person|B60205|A person must solve a problem; a comment says why
type:docs|C5DEF5|Documentation only; the fail-first check is skipped
type:chore|BFD4F2|Maintenance with no new behavior; the fail-first check is skipped
EOF
echo "Labels: ready."

mkdir -p .agent-works
[ -f .agent-works/config.json ] || cp "$here/../config.example.json" .agent-works/config.json
grep -qx '.agent-works/ledger.jsonl' .gitignore 2> /dev/null || echo '.agent-works/ledger.jsonl' >> .gitignore
mkdir -p "$HOME/.claude/skills"
[ -e "$HOME/.claude/skills/agent-works" ] || ln -s "$(cd "$here/../skills/agent-works" && pwd)" "$HOME/.claude/skills/agent-works"
echo "Next: edit checks.verify and checks.fail_first.test_globs in .agent-works/config.json,"
echo "then commit it and .gitignore to the default branch."
