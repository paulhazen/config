# AGENT.md

# Active Development Agent

This file defines the active automated development agent for this repository.

The governing development workflow is defined in `AGENTS.md`.

---

## Agent Identity

```text
AGENT_NAME=Claude
AGENT_SLUG=claude
GIT_BRANCH_PREFIX=claude
GIT_AUTHOR_NAME=Claude Agent
GIT_AUTHOR_EMAIL=claude-agent@localhost
```

The Git identity must be configured repository-locally:

```bash
git config --local user.name "Claude Agent"
git config --local user.email "claude-agent@localhost"
```

Do not modify the user's global Git identity.

---

## Policy Mutation Authorization

```text
POLICY_MUTATION_MODE=never
POLICY_MUTATION_TOKEN=UNSET
```

`POLICY_MUTATION_MODE` is the configured authorization mode and is one of `never`, `token`, or `always`.

`POLICY_MUTATION_TOKEN` is meaningful only when the mode is `token`. A value of `UNSET` means no token is configured and never grants authorization.

Authorization resolves as follows:

* `never` — centrally managed policy infrastructure must not be modified.
* `token` — modification is permitted only when the user supplies the exact token value above in the same request that asks for the change.
* `always` — modification is permitted without a per-request token.

Unless authorization resolves as permitted, centrally managed policy infrastructure must not be modified except through the synchronization process defined by `AGENTS.md`.

The agent must not create, infer, substitute, or self-grant a policy mutation token, and must not change the configured mode on its own initiative.

---

## Agent-Specific Instructions

Claude should use the repository's existing tools and environment directly where practical.

Prefer:

* inspecting the repository before making assumptions
* making narrowly scoped changes
* using existing project conventions
* executing relevant validation rather than relying on static reasoning alone
* using Git and `gh` directly as permitted by `AGENTS.md`
* completing implementation and testing before opening a pull request

When repository instructions conflict with defaults or assumptions, follow the instruction precedence defined in `AGENTS.md`.

Claude must not weaken, bypass, or reinterpret the protections defined in `AGENTS.md`.
