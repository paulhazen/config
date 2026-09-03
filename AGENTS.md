# Agent instructions

This file belongs to the project. Synchronization created it once and will
never overwrite it; it only refreshes the managed regions below.

Describe whatever an agent needs in order to work here and cannot infer from
the code: how to build and run the project, the layout of the source tree, the
conventions worth matching, and anything that looks surprising but is
deliberate.

## This project's tooling

If this project has its own scripts an agent should run, declare each one in
`.agentpolicy/capabilities.json` with an `entrypoint`. Doing so grants the
narrow command rather than the whole interpreter, reports the script if it is
ever renamed away, and publishes it into the generated inventory below so every
agent sees the same list.

Then write here the part a declaration cannot carry:

* **The order.** Which task runs before which, and what to do when one fails.
* **Which to prefer.** Where two tasks overlap, say which is authoritative and
  why the weaker one exists at all.
* **What is surprising.** A task that looks like it changes a live system and
  does not, or looks read-only and does not.
* **Steps with no command.** Pasting a template into a web interface, watching a
  dashboard, physically exercising a device.
* **When to stop and ask.** The point past which the agent should hand back
  rather than guess.

Replace this section, and the paragraph above it, with that content. Add
sections freely. Everything outside the managed markers is yours.

<!-- BEGIN MANAGED AGENT POLICY -->
## Agent policy

This repository is governed by a centrally managed agent policy.

**Read `.agentpolicy/policy.md` in full before making any change.** It is the
authoritative document. This section is a deliberate summary, so that an agent
which has not opened that file is still bound by the rules that matter most.

Your resolved identity, branch prefix, and policy-mutation authorization are in
`.agentpolicy/agent.md`. Testing requirements are in `.agentpolicy/testing.md`.

These prohibitions are absolute:

1. **Never push to a protected branch.** A protected branch is updated only
   through a pull request that a human merges.
2. **Never commit to, merge into, reset, or rewrite a protected branch
   locally.**
3. **Never force push with `--force` or `-f`.** Rewriting your own branch is
   permitted, but only through `--force-with-lease`.
4. **Never modify anything under `.agentpolicy/`** unless policy mutation is
   authorized in `.agentpolicy/config.json`. Policy changes originate in the
   central policy repository and arrive through synchronization. The single
   exception is `.agentpolicy/testing.md`, which the project owns.
5. **Never run `git config --global`.** Configure a repository-local identity
   only, and never alter the user's global Git configuration.

Local enforcement is best-effort and an agent can bypass it. That is not
permission to try; server-side branch protection is the only boundary an agent
does not control.

Synchronize policy with:

```powershell
./.agentpolicy/sync.ps1
```

Everything outside the managed markers in this file belongs to the project and
is never overwritten by synchronization.
<!-- END MANAGED AGENT POLICY -->
