[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$CapabilitySpecPath,
    [AllowNull()][string]$ProjectCapabilitiesPath,
    [AllowNull()][string]$PolicyMutationMode
)

# Emits Codex CLI configuration from the agent-neutral capability
# specification.
#
# Codex enforces capability through an operating-system sandbox
# (sandbox_mode) plus an approval gate (approval_policy). It has no notion of
# denying an individual command by its text, so most rules in the capability
# specification have no direct Codex representation and are carried by the Git
# hooks and by AGENTS.md instead. Those rules are written into the generated
# file as comments so the gap is visible rather than silent.
#
# Codex loads a project-scoped .codex/config.toml only for trusted projects,
# and a project configuration cannot grant broader permission than the user's
# own configuration allows. This file can therefore tighten Codex's posture
# but never loosen it.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "capability-spec.ps1")

$central = Import-CapabilitySpec -Path $CapabilitySpecPath

if ([string]::IsNullOrWhiteSpace($ProjectCapabilitiesPath)) {
    $ProjectCapabilitiesPath = Join-Path $RepositoryRoot ".agentpolicy/capabilities.json"
}

$project = Import-ProjectCapabilities -Path $ProjectCapabilitiesPath

$spec = Merge-Capabilities -Central $central -Project $project

$mutationAuthorized = Test-PolicyMutationAuthorized -PolicyMutationMode $PolicyMutationMode

$beginMarker = "# BEGIN MANAGED AGENT POLICY"
$endMarker = "# END MANAGED AGENT POLICY"

$sandboxMode =
    switch ($spec.Sandbox.filesystemWrite) {
        "workspace" { "workspace-write" }
        "none"      { "read-only" }
        default {
            throw "Codex emitter does not understand sandbox.filesystemWrite value '$($spec.Sandbox.filesystemWrite)'."
        }
    }

$networkAccess =
    if ($spec.Sandbox.networkAccess) {
        "true"
    }
    else {
        "false"
    }

$lines = [System.Collections.Generic.List[string]]::new()

$lines.Add($beginMarker)
$lines.Add("#")
$lines.Add("# Generated from .agentpolicy/capability-spec.json by .agentpolicy/emitters/codex.ps1.")
$lines.Add("# Edits inside this block are overwritten by ./.agentpolicy/sync.ps1.")
$lines.Add("# Place project-owned Codex settings outside this block.")
$lines.Add("#")

$lines.Add("")
$lines.Add("approval_policy = `"on-request`"")
$lines.Add("sandbox_mode = `"$sandboxMode`"")
$lines.Add("")
$lines.Add("[sandbox_workspace_write]")
$lines.Add("network_access = $networkAccess")

if ($spec.Sandbox.PSObject.Properties.Name -contains "networkAccessJustification") {
    $lines.Add("# $($spec.Sandbox.networkAccessJustification)")
}

#
# Project capability grants.
#
# A write grant maps onto writable_roots, which Codex enforces through
# platform-native mechanisms rather than by inspecting commands. That makes it
# the strongest representation of a grant available in either agent.
#
# A read grant needs no entry: workspace-write already permits reads, and
# omitting a path from writable_roots is what makes it read-only.
#
# A tool grant has no Codex representation at all. Execution is governed by
# the sandbox and the approval policy, not by command identity.
#

$writableRoots = [System.Collections.Generic.List[string]]::new()
$readGrants = [System.Collections.Generic.List[string]]::new()
$toolGrants = [System.Collections.Generic.List[string]]::new()
$mcpGrants = [System.Collections.Generic.List[string]]::new()

foreach ($grant in $spec.Grants) {

    switch ($grant.Kind) {

        "tool" {
            foreach ($command in $grant.Commands) {
                $toolGrants.Add($command)
            }
        }

        "mcp" {
            foreach ($tool in $grant.Tools) {
                $mcpGrants.Add($tool)
            }
        }

        "path" {
            foreach ($granted in $grant.Paths) {
                if ($grant.Access -eq "write") {
                    $writableRoots.Add($granted)
                }
                else {
                    $readGrants.Add($granted)
                }
            }
        }

        default {
            throw "Codex emitter does not understand grant kind '$($grant.Kind)' (grant '$($grant.Id)')."
        }
    }
}

if ($writableRoots.Count -gt 0) {
    $quoted = $writableRoots | ForEach-Object { '"' + ($_ -replace '\\', '\\\\') + '"' }

    $lines.Add("")
    $lines.Add("# Write grants from .agentpolicy/capabilities.json.")
    $lines.Add("writable_roots = [" + ($quoted -join ", ") + "]")
}

if ($readGrants.Count -gt 0) {
    $lines.Add("")
    $lines.Add("# Read grants need no entry: workspace-write permits reads, and")
    $lines.Add("# absence from writable_roots is what makes a path read-only.")

    foreach ($path in $readGrants) {
        $lines.Add("#   - $path")
    }
}

if ($toolGrants.Count -gt 0) {
    $lines.Add("")
    $lines.Add("# Tool grants have no Codex equivalent; the sandbox governs")
    $lines.Add("# execution rather than command identity:")

    foreach ($command in ($toolGrants | Select-Object -Unique)) {
        $lines.Add("#   - $command")
    }
}

if ($mcpGrants.Count -gt 0) {
    $lines.Add("")
    $lines.Add("# MCP grants have no Codex equivalent; MCP servers are configured")
    $lines.Add("# per client rather than through this sandbox policy:")

    foreach ($tool in ($mcpGrants | Select-Object -Unique)) {
        $lines.Add("#   - $tool")
    }
}

#
# Record the rules Codex cannot express, so the gap is auditable.
#

$unrepresented = [System.Collections.Generic.List[string]]::new()

foreach ($rule in $spec.Rules) {

    if ($rule.Kind -eq "file-write" -and $mutationAuthorized) {
        continue
    }

    $detail =
        switch ($rule.Kind) {
            "git-push"   { "branches: " + ($rule.Targets -join ", ") }
            "git-mutate" { "branches: " + ($rule.Targets -join ", ") }
            "command"    { "commands: " + ($rule.Patterns -join ", ") }
            "file-write" { "paths: " + ($rule.Paths -join ", ") }
            default {
                throw "Codex emitter does not understand capability rule kind '$($rule.Kind)' (rule '$($rule.Id)')."
            }
        }

    $unrepresented.Add("#   - $($rule.Id) [$detail]")
}

if ($unrepresented.Count -gt 0) {
    $lines.Add("")
    $lines.Add("# The following policy rules have no Codex configuration equivalent.")
    $lines.Add("# They are enforced by .agentpolicy/hooks and by AGENTS.md:")
    $lines.Add("#")

    foreach ($entry in $unrepresented) {
        $lines.Add($entry)
    }
}

$lines.Add("")
$lines.Add($endMarker)

$managedBlock = $lines -join [Environment]::NewLine

$configPath = Join-Path $RepositoryRoot ".codex/config.toml"

$content = $managedBlock + [Environment]::NewLine

if (Test-Path $configPath -PathType Leaf) {
    $existing = Get-Content $configPath -Raw

    $pattern =
        [regex]::Escape($beginMarker) +
        "[\s\S]*?" +
        [regex]::Escape($endMarker)

    if ($existing -match $pattern) {
        # Replace only the managed region, preserving project-owned settings.
        $content = [regex]::Replace(
            $existing,
            $pattern,
            { param($m) $managedBlock },
            [System.Text.RegularExpressions.RegexOptions]::None
        )
    }
    else {
        # Preserve existing project-owned settings beneath the managed block.
        $content =
            $managedBlock +
            [Environment]::NewLine +
            [Environment]::NewLine +
            $existing
    }
}

Write-GeneratedFile -Path $configPath -Content $content

Write-Host "  .codex/config.toml (sandbox_mode = $sandboxMode; $($writableRoots.Count) writable roots; $($unrepresented.Count) rules delegated to hooks)"
