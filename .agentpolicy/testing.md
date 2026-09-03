# Testing

Testing requirements for this project.

This file is project-owned. Synchronization creates it once and never overwrites it. Replace the placeholder content below with the real requirements for this repository.

## Required before opening a pull request

Describe the commands an agent must run and pass before opening a pull request. For example:

```text
<build command>
<unit test command>
<lint command>
```

Every required command must pass. If a required check fails, the agent must investigate before opening a pull request, as described in `.agentpolicy/policy.md`.

## Areas requiring extra care

List the parts of this project where automated coverage is thin and manual verification is expected.

## Verifying agent policy enforcement

Synchronization installs Git hooks that refuse pushes to a protected branch. Confirm they are active:

```powershell
git config --get core.hooksPath
```

This should report `.agentpolicy/hooks`. If it reports nothing, re-run:

```powershell
./.agentpolicy/sync.ps1
```

## If this file is left unmodified

`.agentpolicy/policy.md` requires an agent to perform reasonable inferred validation when testing requirements are absent or incomplete, and to state in the pull request what was validated and what the gaps were.
