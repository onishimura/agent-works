# Acknowledgments

These projects and articles gave ideas to agent-works. agent-works uses none of their code. Each entry names the idea and the part of the design where agent-works uses it.

## Ideas and where they went

### [super-board](https://github.com/EricTechPro/super-board) by Eric Tech

**Idea:** a board-driven build, check and merge loop, and the rule to verify the exact commit against the current base.

**In agent-works:**

- Labels on GitHub issues are the board: `agent:ready`, `agent:working`, `agent:checking`, `agent:proposed` and `agent:needs-person` ([State](docs/design.md#state)).
- The merge rule: merge only the commit that passed the checks, against the current base. Commit statuses on the checked commit and branch protection with an up-to-date branch enforce it ([Merge safety](docs/design.md#merge-safety)).

### [How to Run a Gauntlet Loop](https://somethingbig.ai/gauntlet-loop) by Matt Shumer

**Idea:** the builder never grades its own work, and the critic inspects the real output.

**In agent-works:**

- The principle "The builder never grades its own work". A separate verifier agent gives the result, and it has no edit tools ([Principles](docs/design.md#principles)).
- The principle "The verifier reads the diff, not the builder's summary". The verifier checks each claim in the summary against the diff and the test output ([Criteria map](docs/design.md#criteria-map-verifier-output)).

### [Harness Engineering for Self-Improvement](https://lilianweng.github.io/posts/2026-07-04-harness/) by Lilian Weng

**Idea:** keep the evaluator outside the editable surface.

**In agent-works:**

- The principle "The checks stay outside the editable surface". The check script reads its config from the default branch, never from the PR ([Check script](docs/design.md#check-script)).
- Protected paths: a PR that changes the workflow files, CI or the check config always goes to a person ([Config](docs/design.md#config)).

### [Grok Ship](https://x.com/kunchenguid/status/2090463366762676732) by Kun Chen

**Idea:** fresh-context adversarial review.

**In agent-works:**

- The verifier runs in a new session with no previous context, and it does not trust the builder's summary ([Orchestrator](docs/design.md#orchestrator)).
- The trust suite tests the reviewer with seeded bad PRs and good controls, and the scorecard publishes the result ([Trust suite](docs/design.md#trust-suite)).

### [AI-native workshop](https://github.com/workos/aie-ai-native-workshop) by WorkOS

**Idea:** goals and verification gates.

**In agent-works:**

- The issue format: a goal, acceptance criteria and items that are out of scope. The workflow does not start an issue without acceptance criteria ([Issue format](docs/design.md#issue-format)).
- Fixed gates before model judgment: the fail-first check, the verify commands and the protected paths ([Fail-first check](docs/design.md#fail-first-check)).

### [ai-tasks](https://github.com/onishimura/ai-tasks)

**Idea:** my earlier plain-file task system for coding agents.

**In agent-works:** agent-works keeps its state in GitHub labels instead. Plain files stay an open question in the design ([Open questions](docs/design.md#open-questions)).

## What agent-works adds

agent-works adds measurement to these ideas: a seeded trust suite with a published scorecard, a fail-first check, a criteria map that links each criterion to evidence, and a run ledger with human edits ([Thesis](docs/design.md#thesis)).
