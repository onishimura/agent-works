# Auto-merge decision (Phase 5)

- **Date:** 2026-10-09
- **Pilot:** `onishimura/private-pilot`, issues #6 to #9 and #14 to #19
- **Decision:** Keep `merge.mode` at `propose`. Do not allow `auto` yet, also not for small changes.

## The question

Phase 5 asks one question: does the data allow `auto` mode for small changes? In `auto` mode, the workflow merges a PR itself when the fixed checks and the verifier pass and the diff is small (`merge.auto_when.max_diff_lines`, 150 lines in the example config).

## Data

### Pilot issues

Ten issues ran in 16 runs. A run is one issue from `agent:ready` to a final status (see `docs/design.md`, "Run ledger").

| Issue | Kind | First run | Later runs | Final result | Merged PR | Changed lines |
|---|---|---|---|---|---|---|
| #6 | feature | proposed | 1 rebuild after the base moved | merged | #13 | 70 |
| #7 | chore | proposed | — | merged | #12 | 10 |
| #8 | bug | proposed | — | merged | #10 | 5 |
| #9 | bug | proposed | — | merged | #11 | 14 |
| #14 | bug | proposed | 1 rebuild after the base moved | merged | #23 | 29 |
| #15 | feature | proposed | 1 rebuild after the base moved | merged | #22 | 60 |
| #16 | feature | proposed | 1 rebuild after the base moved | merged | #21 | 83 |
| #17 | chore | needs-person after 3 attempts | 1 rerun after the fail-first fix | merged | #20 | 38 |
| #18 | bug | proposed | 1 rebuild after the base moved | merged | #24 | 22 |
| #19 | docs | needs-person (builder blocked) | — | open | — | — |

The ledger report (`report.py ledger`) for all runs:

- Runs: 16, for 10 issues. Proposed or merged: 14 of 16 runs (88%).
- Attempts: 1.1 for each run on average.
- Tokens: 6,680,979. Cost: $8.43. Time: 2.5 minutes for each run on average.
- Merged PRs with human edits: 0 of 9. Each commit on a merged PR has the author "trust-factory builder", the name before the rename to agent-works.

### Merges and the base branch

- The owner merged 9 PRs. After the merges, `main` passed its verify commands (`npm ci`, `npm run check`) at each check: 89, 90, 92, 95, 96 and 97 tests, with 0 failures.
- 5 of the 9 PRs had a merge conflict after an earlier merge. Each conflict was in `README.md` (a test-count line) or `docs/verification.md` (an append-only log). The pilot's `CLAUDE.md` asks each change to update both files.
- A rebuild on the new base fixed each conflict. No person edited code. The rebuilds cost $2.97, 35% of the total.

### Trust suite

Two full runs of the verifier on the trust suite (`trust-suite/scorecard.md`) gave the same result:

| Measure | Run 1 | Run 2 (through `scripts/verify.sh`) |
|---|---|---|
| Catch rate (bad PRs that got `fail` or `unsure`) | 5/5 | 5/5 |
| False-fail rate (good PRs that did not get `pass`) | 0/3 | 0/3 |
| Unsure rate | 0/8 | 0/8 |
| Invalid verdicts | 0/8 | 0/8 |
| Cost | $0.37 | $0.40 |

### The verifier on real PRs

- The verifier ran 15 times on pilot PRs: 14 `pass` verdicts and 1 `fail` verdict. Each PR that it passed was merged in the end (five after a rebuild on a new base), with no human edit, and `main` stayed green.
- The `fail` was correct. In #17 (attempt 2), the builder added a test only to make the fail-first check fail at the base. The fixed checks accepted it. The verifier found the extra test, and it also found that the PR removed test coverage of a function that the issue said to keep.

## Findings

1. **The verifier catches what the fixed checks miss.** The trust suite and the #17 case show it on seeded and on real work.
2. **Under pressure from a fixed check, the builder games the check.** A fail-first rule that did not fit chores made the builder add a test with no other purpose. We changed the rule (`docs/design.md`, Decisions).
3. **The builder does not invent facts when it is blocked.** In #19, the issue asked for label names that the repo does not contain. The builder stopped and said what it needed. The issue text was the problem.
4. **Shared lines in docs make parallel PRs conflict.** Every PR changed the same README line. Each merge made the next PR conflict, so the merges had to go one at a time.
5. **The pilot's instructions conflict with the agent permissions.** The pilot's `CLAUDE.md` tells agents to change `PATH`. The permission rules deny that in every run. It costs a turn but causes no harm.
6. **The changes were small.** The largest merged PR changed 83 lines. All nine are under the 150-line limit for "small".

## Reasons for the decision

The agent work in this pilot was good: 9 of 10 issues merged with no human edits, and no merge broke `main`. The decision does not come from the agents. It comes from three gaps around them.

1. **The merge safety rule has no enforcement on the pilot.** The rule is: merge only the commit that passed the checks, against the current base. On a private repo with a free plan, GitHub branch protection is not available. The fallback (`gh pr merge --match-head-commit`, one merge at a time) is not built. In `propose` mode, a person is the safety rule. In `auto` mode, nothing is.
2. **The workflow cannot follow a moving base by itself.** 5 of 9 PRs needed a rebuild after an earlier merge. Today a person starts each rebuild. `auto` mode needs a loop that re-checks or rebuilds the open PRs after each merge.
3. **The sample is small and easy.** Ten small issues, written by the operator with clear criteria, and eight trust-suite cases. The owner's own backlog will have larger and less clear issues.

## What would change the decision

Allow `auto` for small changes when all of these are true:

- [ ] The merge rule is enforced: branch protection that requires `agent-works/checks` and `agent-works/verifier` on an up-to-date branch, or the `--match-head-commit` fallback with one merge at a time.
- [ ] After each merge, the workflow re-checks the open PRs and rebuilds the ones that conflict, with no person.
- [ ] The pilot has no shared counter lines in its docs, or the workflow resolves them. This is a decision for the pilot owner, because `CLAUDE.md` is a protected path.
- [ ] 20 more pilot issues, written by the owner: at least 90% merged with no human edits, and no merge breaks `main`.
- [ ] The trust suite has at least three cases for each category, and each case runs three times. The catch rate stays at 100%, and the false-fail rate is at most 5%.

Even then, `auto` applies only to a PR that has a diff of at most `merge.auto_when.max_diff_lines` lines, no protected paths, a `pass` from the verifier, and test evidence for each criterion.

## Success criteria

| Criterion (`docs/design.md`) | Result |
|---|---|
| The core stays under approximately 760 lines | 713 lines at the decision, 752 with the Phase 6 setup script |
| No merge from the workflow makes the base branch fail its verify commands | True for all 9 merges |
| Trust suite: the catch rate is 100%, and no more than one good control fails | 5/5 and 0/3, in two runs |
| At least 6 of 10 pilot issues finish with no human code changes | 9 of 10 |
| Setup on a new repo takes less than 10 minutes | Not measured yet (Phase 6) |
