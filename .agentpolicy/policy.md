# Agent Development Workflow

This document defines the default development and Git workflow for automated coding agents working in this repository.

It is intentionally agent-agnostic. Agent-specific identity and naming are defined separately in `AGENT.md`.

Project-specific testing requirements are defined in `TESTING.md`.

---

## 1. Policy Synchronization

Before beginning development work, synchronize the repository's agent policy.

Run:

```powershell
./.agentpolicy/sync.ps1
```

This synchronization must occur before relying on the current contents of `AGENTS.md`, `AGENT.md`, or other centrally managed instruction files.

After synchronization completes:

1. Re-read `AGENTS.md`.
2. Read `AGENT.md`.
3. Read `TESTING.md`.
4. Configure the repository-local Git identity required by `AGENT.md`.
5. Only then begin development work.

Synchronization also generates the enforcement configuration for the selected agent and installs the Git hooks described in section 4. Agents must not disable those hooks, unset `core.hooksPath`, or pass `--no-verify` to work around them.

### Policy Version Selection

The project's `.agentpolicy/config.json` determines which policy version is installed.

If:

```json
"version": "latest"
```

the synchronization process must install the newest released policy version available from the configured policy repository.

If an explicit version, tag, or commit is configured, the project is pinned and that configured revision must be used.

Agents must not change a project's configured policy version or pin unless explicitly instructed by the user.

Agents must not modify `.agentpolicy/config.json` in order to escape, weaken, replace, or alter the instructions governing their operation.

### Applied Policy Revision

The synchronization process records the exact installed policy revision in:

```text
.agentpolicy/config.lock.json
```

This lock file records the resolved policy version and commit actually installed.

The lock file should be committed to the repository so changes in applied policy are visible in Git history.

Agents must not manually edit the lock file.

---

## 2. Centrally Managed Policy Files

The following files are centrally managed policy infrastructure:

<!-- BEGIN MANAGED POLICY FILE LIST -->
```text
.agentpolicy/
dev/policy-src/
```
<!-- END MANAGED POLICY FILE LIST -->

This list is generated from `policyFiles` in `.agentpolicy/capability-spec.json`, and the test suite fails if the two disagree. A trailing `/` denotes a directory and covers everything beneath it.

The namespace is protected wholesale, which is why it is one entry rather than a list that has to be maintained as files are added.

`dev/policy-src/` exists only in the policy repository: it holds the fragments this document is assembled from. A consumer never receives it, so the entry is inert there. It is listed because those fragments are the real source of this document, and protecting the assembled file while leaving its sources writable would make the protection trivially bypassable.

The following paths are exempt, because the project owns their *contents* even though they sit inside the namespace:

<!-- BEGIN MANAGED POLICY FILE EXEMPTIONS -->
```text
.agentpolicy/testing.md
.agentpolicy/config.json
.agentpolicy/capabilities.json
```
<!-- END MANAGED POLICY FILE EXEMPTIONS -->

`.agentpolicy/config.json` and `.agentpolicy/capabilities.json` are exempt because a project cannot install this policy without committing them: the installer writes the configuration, and the capability file is where the project declares its own grants. Their protection is the write deny in generated agent configuration together with server-side code ownership on the policy paths, which is where it belongs. A commit hook cannot tell a human from an agent, so refusing to commit them stopped only the human the rule was written to serve.

Root `AGENTS.md` is not in the list either. The project owns that file; synchronization only rewrites the region between its `MANAGED AGENT POLICY` markers and never touches anything else in it.

Note that generated agent configuration cannot express an exemption inside a denied directory, so an exempt path may appear blocked to the agent even though policy permits editing it. The Git hooks are the authoritative layer and honor the exemption.

### Committing Managed Files

Managed files are committed, and this is expected. An installation is committed. `.agentpolicy/config.lock.json` is committed, so the applied policy revision is visible in history. What is prohibited is *authoring* a change to them locally, not recording one.

Synchronization records the Git blob id of every file it installs. The `pre-commit` hook compares staged content against that record, so a synchronization result commits normally while an edit that did not come through synchronization is refused. Neither the policy configuration nor `policyMutationMode` has to be changed to commit an installation or an upgrade.

The record describes a single clone's last synchronization and is kept in that clone's Git directory. A clone that has never synchronized therefore has no record, and the hook refuses staged policy files until synchronization has run, rather than accepting content it cannot account for.

Generated enforcement configuration is also managed. It is produced from `.agentpolicy/capability-spec.json` and `.agentpolicy/capabilities.json` during synchronization and must not be hand-edited:

```text
.claude/settings.json   (the "permissions.deny" array only)
.codex/config.toml      (the region between the MANAGED AGENT POLICY markers)
```

Both files preserve project-owned content outside those regions.

Agents must not manually modify centrally managed policy infrastructure unless policy mutation has been explicitly authorized as described in section 3.

Normal changes to these files must originate from the central policy repository and be installed through:

```powershell
./.agentpolicy/sync.ps1
```

Project-owned instruction and configuration files, including `TESTING.md`, may be modified when doing so is within the scope of the requested work.

---

## 3. Policy Mutation Authorization

Direct modification of centrally managed policy infrastructure is prohibited by default.

`AGENT.md` records the resolved authorization as two distinct values:

```text
POLICY_MUTATION_MODE=<never | token | always>
POLICY_MUTATION_TOKEN=<token value, or UNSET>
```

Authorization resolves as follows:

| Mode | Authorization |
|---|---|
| `never` | Never authorized. |
| `token` | Authorized only for a request in which the user supplies the exact token value recorded in `AGENT.md`. |
| `always` | Authorized without a per-request token. |

The mode and the token are separate values and must never be conflated. A mode name is not a token: `POLICY_MUTATION_TOKEN=token` authorizes nothing.

The following values do not grant authorization:

```text
POLICY_MUTATION_TOKEN=UNSET
POLICY_MUTATION_TOKEN=
```

An absent mode is treated as `never`. An absent token is treated as `UNSET`.

When policy mutation authorization is not present, the agent must not:

* modify `AGENTS.md`
* modify `AGENT.md`
* modify `.agentpolicy/sync.ps1`
* manually modify `.agentpolicy/config.lock.json`
* modify `.agentpolicy/config.json`
* change the configured policy repository
* change the configured policy version or pin
* alter the active agent configuration through policy files
* create, infer, substitute, or self-grant a policy mutation token
* use Git history rewriting to bypass these restrictions
* use another script or tool to indirectly perform a prohibited mutation
* replace a managed policy file with a symlink, generated file, wrapper, or alternate implementation intended to bypass these restrictions

A policy mutation token may only be supplied by the user or by an already-authorized policy-management process.

Policy mutation authorization permits policy-maintenance work only. It does not remove any other Git, branch, testing, scope, or safety requirements in this document.

---

## 4. Enforcement Layers

This policy is enforced at three levels. They differ in what they can express and in how much they can be relied upon.

**Instructions.** `AGENTS.md` and `AGENT.md` describe required behavior. This layer is agent-agnostic and expresses every rule, but depends entirely on the agent following it.

**Generated agent configuration.** `./.agentpolicy/sync.ps1` translates `.agentpolicy/capability-spec.json` into the selected agent's native configuration. This layer fails fast on the common literal forms of a prohibited action. It is best-effort: Claude Code matches command text by prefix, and Codex expresses capability as an operating-system sandbox rather than as per-command rules, so neither can represent every rule. Rules with no representation are recorded in the generated file rather than dropped silently.

**Git hooks.** `.agentpolicy/hooks` is installed by synchronization, which sets `core.hooksPath`. These hooks inspect the refs and staged files actually involved rather than the text of a command, so they are phrasing-independent and identical for every agent and for human users. This is the authoritative local layer.

No local layer constrains a process that deliberately bypasses it: `--no-verify` skips hooks, and generated configuration is a file in the working tree. Local enforcement exists to prevent mistakes.

The only enforcement an agent does not control is server-side: branch protection, required status checks, and code ownership on the policy paths. Projects that need a real boundary around a protected branch must configure it on the remote. Agents must not treat the absence of server-side protection as permission to push to a protected branch.

---

## 5. Project Capability Grants

Sections 2 and 4 describe what agents may not do. A project may also declare what agents *may* do, in:

```text
.agentpolicy/capabilities.json
```

This file is project-owned. Synchronization creates it once and never overwrites it. It declares three kinds of grant:

* `tool` — commands an agent may invoke, listed in `commands`.
* `path` — filesystem locations an agent may reach, listed in `paths`, with `access` of `read` or `write`.
* `mcp` — Model Context Protocol tools an agent may call, listed in `tools`, each named in full as `mcp__<server>__<tool>`.

A `tool` command is matched as a **prefix**, so it may name a bare executable, a single subcommand, or a whole invocation. Grant the narrowest prefix that still permits the work: granting a bare interpreter grants arbitrary code execution, and a grant whose stated reason is three named scripts should name those three invocations.

A `tool` grant may also declare two optional fields:

* `entrypoint` — one of the project's own scripts that the granted command runs, as a repository-relative path. It confers no access; it is checked for existence, and a grant whose entrypoint has been renamed or deleted is reported as an error rather than left silently permitting a command that can no longer run.
* `mutates` — whether running the task changes anything outside the repository. Nothing enforces this. It is the project's claim, published so a reader knows which tasks are expected to touch a live system.

An `mcp` tool name is emitted into the generated allow list verbatim, because MCP tools are matched by exact name rather than by prefix. Synchronization therefore rejects any name that is not of the `mcp__<server>__<tool>` form, so this kind cannot be used to introduce a rule of some other shape that would bypass the central forbid checks. Agents that have no MCP equivalent record the grant as a comment instead.

Precedence is fixed and not negotiable:

* A rule forbidden by the central policy always overrides a grant.
* A project may add its own `forbid` entries. Tightening is always permitted.
* A grant that reaches a centrally managed policy path is rejected during synchronization.
* `.agentpolicy/capabilities.json` is itself a managed policy path, so an agent cannot widen its own authority without a human commit.

An agent must not add or broaden a grant on its own initiative. Propose the change and let the user commit it.

### What a grant does not do

A grant declares intent. It does not install a tool, mount a share, or confer any operating-system permission.

In particular, a `read` grant is not a guarantee. The generated agent configuration can stop an agent's own file-writing tools from targeting a path, but any granted shell command runs with the user's operating-system permissions and can write wherever the operating system allows. A read-only guarantee must come from the mount or the access-control list.

Run:

```powershell
./.agentpolicy/verify-capabilities.ps1
```

to report where a declaration and the operating system disagree. Synchronization runs it automatically and reports findings without failing. It describes problems and never repairs them: changing a mount or an access-control list is the user's decision.

Declare locations, never credentials.

---

## 6. Project Tooling

A project may have its own scripts for building, validating, deploying, or
inspecting whatever it produces. Those scripts are the project's, not this
policy's, and they live wherever the project keeps them.

Before running an ad-hoc command, read what the project has declared and prefer
it. A project that has a validation script has one for a reason, and reasoning
about the source instead of running it is how a change gets described as
validated when it was not.

Two places carry that knowledge, and they carry different halves of it.

**The declared inventory.** Grants in the project capability file that name an
`entrypoint` are the project's own tasks. Synchronization publishes them into a
managed region of the agent instruction file, with the exact command to use, so
the list reaches whichever agent is configured rather than only the one whose
native file happens to contain prose. The command shown is the form the
generated configuration permits; a task invoked some other way may be refused
even though the task itself is granted.

**The project's prose.** Ordering, precedence between overlapping tasks, and
steps that have no command at all cannot be expressed as a declaration. They
belong in the project's own sections of its instruction file, outside the
managed markers. Read them before running anything that changes a live system.

Where the two disagree, the declaration is what the agent is permitted to run
and the prose is what the agent is supposed to do. Report the disagreement
rather than choosing silently.

Two limits are worth stating plainly:

* `mutates` is a claim, not a guarantee. Nothing stops a task marked as making
  no changes from writing somewhere. Treat it as documentation, and where the
  distinction matters for a task that has not been run before, say what is
  assumed rather than assuming it silently.
* A declared task is not automatically safe to run repeatedly, in parallel, or
  against production. If the project has not said, ask.

An agent must not add a grant to the project capability file in order to run
something it wants to run. That file is centrally managed policy
infrastructure, and widening it is a human decision.

---

## 7. Governing Principles

Automated agents may perform normal development work autonomously, including Git operations, branch management, commits, rebases, pushes, pull request creation, and merges into non-protected branches.

The `main` branch is protected.

Agents must never directly modify, rewrite, push to, merge into, or otherwise mutate `main`.

Changes intended for `main` must always be submitted through a pull request and merged by a human.

Agents should keep changes narrowly scoped to the requested task.

Unrelated cleanup, refactoring, formatting changes, dependency upgrades, or opportunistic modifications should be avoided unless required to complete the requested work correctly.

---

## 8. Agent Configuration

After policy synchronization, read:

```text
AGENT.md
```

`AGENT.md` defines the currently selected agent and its derived configuration.

The selected agent determines:

* agent name
* agent slug
* Git branch prefix
* Git author name
* Git author email
* policy mutation authorization state
* other agent-specific configuration

Agent-specific naming must not be hard-coded into this document.

---

## 9. Git Identity

Agents must use a repository-local Git identity.

Do not modify the user's global Git configuration.

The Git identity must be derived from the selected agent defined in `AGENT.md`.

Configure the repository before making commits:

```bash
git config --local user.name "<agent git author name>"
git config --local user.email "<agent git author email>"
```

The purpose of this identity is to make agent-generated commits distinguishable from commits created manually by the repository owner.

GitHub authentication may use the repository owner's existing credentials until a dedicated agent account is configured.

The Git author identity and GitHub authentication identity are separate concerns.

---

## 10. Protected Main Branch

The agent must never perform an operation that directly changes `main`.

Prohibited operations include, but are not limited to:

```bash
git commit
git push origin main
git merge
git rebase
git reset
git cherry-pick
git revert
git commit --amend
```

when those commands would mutate the local or remote `main` branch.

The agent may:

* fetch `main`
* inspect `main`
* compare against `main`
* check out `main` temporarily for inspection
* use `origin/main` as the base of a new branch

The agent must never merge a pull request whose target branch is `main`.

Only a human may perform the final merge into `main`.

---

## 11. Starting New Work

All new development work must begin from the latest remote `main`.

Before creating a branch:

```bash
git fetch origin
```

Create the branch directly from the latest `origin/main`.

Do not rely on the state of a local `main` branch.

Example:

```bash
git switch --create <branch-name> origin/main
```

If a local working tree contains unrelated user changes, preserve those changes and avoid overwriting or deleting them.

Do not use destructive cleanup commands against work that is not clearly owned by the agent.

---

## 12. Branch Naming

Agent-created branches must use the branch prefix defined by `AGENT.md`.

Use structured branch names:

```text
<agent-prefix>/feature/<short-description>
<agent-prefix>/fix/<short-description>
<agent-prefix>/refactor/<short-description>
<agent-prefix>/docs/<short-description>
<agent-prefix>/test/<short-description>
<agent-prefix>/chore/<short-description>
```

Examples for an agent whose configured prefix is `codex`:

```text
codex/feature/add-device-discovery
codex/fix/reconnect-timeout
codex/refactor/network-client
codex/docs/update-api-notes
codex/test/add-reconnect-coverage
```

Branch names should be:

* lowercase
* concise
* hyphen-separated
* descriptive of the requested work

---

## 13. Working Branch Authority

Agents have broad authority over branches they created.

On their own branches, agents may:

* commit
* amend commits
* rebase
* reset
* cherry-pick
* reorder commits
* squash commits
* delete branches
* remove untracked files created by the agent
* rewrite branch history when appropriate
* force-update their own remote branch when necessary

History rewriting must use:

```bash
git push --force-with-lease
```

Plain:

```bash
git push --force
```

must not be used.

Agents must not destructively modify branches or work created by another developer or agent unless explicitly instructed to do so.

When ownership is unclear, preserve the work.

---

## 14. Keeping Work Current

Before final validation and before opening a pull request, fetch the latest remote state:

```bash
git fetch origin
```

If `origin/main` has advanced, rebase the working branch onto it:

```bash
git rebase origin/main
```

Resolve conflicts carefully.

After rebasing a previously pushed branch, update it with:

```bash
git push --force-with-lease
```

Merging `main` into the feature branch should not normally be used.

Rebase is the default integration strategy.

---

## 15. Commit Policy

Commit messages must be clear and concise.

Prefer imperative descriptions such as:

```text
Add device discovery support
Fix reconnect timeout handling
Refactor network client initialization
```

There is no required conventional-commit syntax unless another repository policy defines one.

Agents may create intermediate commits during development.

Before opening a pull request, clean up noisy or meaningless intermediate history where appropriate.

Examples of commits that should normally be squashed, reordered, renamed, or otherwise cleaned up:

```text
wip
fix test
oops
try again
debug
address lint
```

The resulting history should be understandable without preserving every intermediate development step.

A pull request does not need to contain exactly one commit.

---

## 16. Testing Requirements

Project-specific testing requirements are defined in:

```text
TESTING.md
```

Before opening a pull request, the agent must read and follow `TESTING.md`.

All tests required by `TESTING.md` must pass before the pull request is opened unless the user explicitly authorizes an exception.

Testing should include enough validation to establish that:

* the requested behavior works
* existing relevant behavior continues to work
* obvious regressions have not been introduced
* relevant edge cases have been considered
* the project still builds or validates where applicable

Testing must be performed after the final rebase onto the latest `origin/main`.

---

## 17. Missing or Incomplete Testing Policy

If `TESTING.md` does not exist or does not sufficiently cover the affected area, the agent must perform reasonable inferred validation based on the project.

The agent should inspect available project infrastructure and perform appropriate validation such as:

* existing automated tests
* targeted unit tests
* integration tests
* build commands
* linting
* static analysis
* configuration validation
* targeted runtime checks
* manual functional validation where automation is unavailable

The absence of complete testing instructions does not prohibit opening a pull request.

However, the pull request must clearly state:

* that the project did not define complete testing requirements for the affected area
* what validation was performed instead
* any meaningful limitations in that validation

---

## 18. Test Failures

A new pull request must not introduce failing tests.

If a required test fails, investigate the failure before opening the pull request.

A pull request may still be opened when a failing test is demonstrably unrelated and already fails on the latest `origin/main`.

When relying on this exception:

1. reproduce the failure against the latest `origin/main`
2. document that comparison
3. explain the failure in the pull request
4. clearly distinguish the pre-existing failure from behavior caused by the proposed changes

Do not silently ignore failing tests.

---

## 19. Final Pre-PR Validation

Before opening a pull request:

```bash
git fetch origin
git rebase origin/main
```

Then perform the complete required test suite.

Confirm that:

* the branch is based on the latest `origin/main`
* required tests pass
* no unintended files are modified
* temporary debugging code has been removed
* no secrets or credentials were introduced
* commit history is reasonably clean
* commits use the configured agent identity
* the branch contains only appropriately scoped changes

Inspect the final diff against `origin/main`:

```bash
git diff origin/main...HEAD
```

Also inspect repository status:

```bash
git status
```

Push the final branch before creating the pull request.

---

## 20. Pull Requests

Use the GitHub CLI:

```text
gh
```

as the standard interface for GitHub operations.

Do not open a pull request until implementation and testing are complete.

Draft pull requests should not normally be created.

The pull request title must be concise and clearly describe the change.

The pull request body should use the following structure:

```markdown
## Summary

Brief explanation of what the change accomplishes.

## Changes

- Important implementation change
- Important implementation change

## Testing

- Test or validation performed
- Test or validation performed

## Notes / Risks

Include only when relevant.
```

Avoid unnecessarily long implementation narratives.

The pull request should primarily communicate:

* what changed
* why it changed
* how it was validated
* meaningful risks or limitations

Do not document every intermediate edit made during development.

---

## 21. GitHub Operations

Use `gh` as the default GitHub command-line interface.

Examples include:

```bash
gh pr create
gh pr view
gh pr checks
gh pr status
gh issue view
```

Equivalent integrated GitHub tooling may be used when required by the execution environment, but `gh` is the preferred interface.

---

## 22. Pull Request Merging

Agents may merge pull requests into branches other than `main` when doing so is appropriate for the requested workflow.

Agents must never merge a pull request whose target branch is `main`.

The human repository owner is responsible for reviewing and merging changes into `main`.

---

## 23. Branch Cleanup

After a pull request has been merged, the agent may delete its own local and remote branch.

Example:

```bash
git branch -d <branch>
git push origin --delete <branch>
```

The agent must verify that the work has been merged before deleting the branch.

Do not delete branches belonging to another developer or agent unless explicitly instructed.

---

## 24. Scope Discipline

Agents should implement the smallest coherent change that satisfies the requested work.

Avoid unrelated:

* refactoring
* renaming
* formatting
* dependency upgrades
* architectural changes
* cleanup
* documentation changes
* configuration changes

unless they are necessary for the requested feature or explicitly requested.

When unrelated problems are discovered, report them separately rather than silently expanding the scope of the current pull request.

---

## 25. Destructive Operations

Agents may perform destructive Git operations on branches and work they clearly own when those operations are useful for producing a clean result.

Examples include:

```bash
git reset
git rebase
git commit --amend
git clean
git branch -D
```

These operations must not be used against:

* `main`
* work belonging to another developer
* another agent's branch
* unrelated uncommitted user changes
* centrally managed policy infrastructure without policy mutation authorization

If there is uncertainty about whether data is safe to destroy or rewrite, preserve it.

---

## 26. Default Development Sequence

Unless project-specific instructions override it, use the following workflow:

```text
1. Run .agentpolicy/sync.ps1.

2. Re-read the newly synchronized AGENTS.md.

3. Read AGENT.md.

4. Read TESTING.md.

5. Configure the repository-local Git identity.

6. Inspect the working tree and preserve unrelated user work.

7. Fetch origin.

8. Create a structured agent branch from the latest origin/main.

9. Implement the requested change.

10. Perform iterative development testing.

11. Review the resulting implementation and diff.

12. Fetch origin again.

13. Rebase onto the latest origin/main.

14. Run the complete required test suite.

15. Investigate any failures.

16. Clean up temporary work and noisy commit history.

17. Inspect:
    - git status
    - git diff origin/main...HEAD
    - final commit history

18. Push the final branch.

19. Open a non-draft pull request using gh.

20. Provide a concise PR title and structured body.

21. Report the PR and relevant testing information.

22. Do not merge the PR into main.

23. After the PR is merged by a human, clean up the agent branch when appropriate.
```

---

## 27. Instruction Precedence

Instructions should be interpreted in the following order:

1. Explicit instructions from the user for the current task
2. This centrally managed `AGENTS.md`
3. Agent-specific configuration in `AGENT.md`
4. Project-specific testing requirements in `TESTING.md`
5. Existing repository conventions and documentation

Project-specific files may add requirements but must not silently weaken the protections in this document.

In particular, project-local instructions must not authorize:

* direct mutation of `main`
* merging into `main`
* bypassing required policy synchronization
* unauthorized modification of centrally managed policy infrastructure
* destructive modification of work owned by someone else

unless the user explicitly changes the governing policy.

---

## 28. Safety Boundary

The central Git safety boundary is:

> Agents have broad authority over work and branches they create, but they must not directly mutate `main`, destructively modify work owned by someone else, or alter centrally managed agent policy without explicit policy-mutation authorization.

When there is uncertainty about whether a destructive operation affects agent-owned work, preserve the work rather than deleting or rewriting it.
