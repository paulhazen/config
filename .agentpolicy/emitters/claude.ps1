[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$CapabilitySpecPath,
    [AllowNull()][string]$ProjectCapabilitiesPath,
    [AllowNull()][string]$PolicyMutationMode
)

# Emits Claude Code configuration from the agent-neutral capability
# specification.
#
# Claude Code enforces permissions by matching individual tool calls against
# allow/deny/ask rules. Bash matching is prefix based, so a deny rule catches
# the common literal spellings of a prohibited command but not every possible
# rearrangement of its arguments. The Git hooks installed alongside this file
# inspect the refs actually being pushed and are therefore the authoritative
# local layer.
#
# This emitter owns the "permissions.deny" array of .claude/settings.json and
# preserves every other key, so a project may keep unrelated Claude Code
# settings in the same file. Personal, uncommitted overrides belong in
# .claude/settings.local.json.

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

function ConvertTo-ClaudePathRule {
    param([Parameter(Mandatory)][string]$PolicyPath)

    # Directory entries in the specification end with "/".
    if ($PolicyPath.EndsWith("/")) {
        return "./" + $PolicyPath + "**"
    }

    return "./" + $PolicyPath
}

$deny = [System.Collections.Generic.List[string]]::new()

foreach ($rule in $spec.Rules) {

    switch ($rule.Kind) {

        "git-push" {
            foreach ($branch in $rule.Targets) {
                # Common literal spellings of a push at a protected branch.
                $deny.Add("Bash(git push origin ${branch}:*)")
                $deny.Add("Bash(git push -u origin ${branch}:*)")
                $deny.Add("Bash(git push --set-upstream origin ${branch}:*)")
                $deny.Add("Bash(git push origin HEAD:${branch}:*)")
            }
        }

        "command" {
            foreach ($pattern in $rule.Patterns) {
                $deny.Add("Bash(${pattern}:*)")
            }
        }

        "git-mutate" {
            # Claude Code cannot express "this command would mutate branch X",
            # because the effect depends on the currently checked-out branch
            # rather than on the command text. The pre-push hook and the
            # instructions in AGENTS.md carry this rule instead.
        }

        "file-write" {
            if ($mutationAuthorized) {
                continue
            }

            foreach ($policyPath in $rule.Paths) {
                $target = ConvertTo-ClaudePathRule -PolicyPath $policyPath

                $deny.Add("Edit($target)")
                $deny.Add("Write($target)")
            }

            # Claude Code resolves deny before allow, so a path exempted from
            # a denied directory cannot be re-permitted here. The generated
            # configuration is therefore stricter than the policy: the pre-commit
            # hook, which is the authoritative layer, honors the exemption.
            foreach ($exempt in @($spec.PolicyFileExemptions)) {
                Write-Host "  note: '$exempt' is exempt by policy but stays denied here; Claude Code cannot express an exemption inside a denied directory."
            }
        }

        default {
            throw "Claude emitter does not understand capability rule kind '$($rule.Kind)' (rule '$($rule.Id)')."
        }
    }
}

#
# Project capability grants.
#
# Claude Code mediates tool calls; it is not an operating-system sandbox.
# A granted path becomes reachable through additionalDirectories, and the
# read/write distinction is expressed with Edit and Write rules.
#
# That distinction binds Claude Code's own file tools only. Any granted shell
# command runs with the user's operating-system permissions and can therefore
# write anywhere the operating system permits, regardless of the rules emitted
# here. A read-only guarantee has to come from the mount or the access-control
# list. See .agentpolicy/verify-capabilities.ps1, which reports where the two
# disagree.
#

$allow = [System.Collections.Generic.List[string]]::new()
$additionalDirectories = [System.Collections.Generic.List[string]]::new()

function ConvertTo-ClaudeGrantRule {
    param([Parameter(Mandatory)][string]$GrantedPath)

    # Granted paths are absolute or UNC locations outside the repository, so
    # they are used verbatim rather than made repository-relative.
    return ($GrantedPath.TrimEnd('/', '\') + "/**")
}

foreach ($grant in $spec.Grants) {

    switch ($grant.Kind) {

        "tool" {
            foreach ($command in $grant.Commands) {
                $allow.Add("Bash(${command}:*)")
            }
        }

        "mcp" {
            # MCP tool names are already fully qualified as
            # mcp__<server>__<tool>, so Claude Code matches them exactly and
            # they need no Bash-style wrapper or trailing pattern.
            foreach ($tool in $grant.Tools) {
                $allow.Add($tool)
            }
        }

        "path" {
            foreach ($granted in $grant.Paths) {
                $additionalDirectories.Add($granted)

                $target = ConvertTo-ClaudeGrantRule -GrantedPath $granted

                if ($grant.Access -eq "write") {
                    $allow.Add("Edit($target)")
                    $allow.Add("Write($target)")
                }
                else {
                    $deny.Add("Edit($target)")
                    $deny.Add("Write($target)")
                }
            }
        }

        default {
            throw "Claude emitter does not understand grant kind '$($grant.Kind)' (grant '$($grant.Id)')."
        }
    }
}

$settingsPath = Join-Path $RepositoryRoot ".claude/settings.json"

# Preserve any existing project settings; own only permissions.deny.
$settings = [ordered]@{}

if (Test-Path $settingsPath -PathType Leaf) {
    $existing = Get-Content $settingsPath -Raw | ConvertFrom-Json

    foreach ($property in $existing.PSObject.Properties) {
        $settings[$property.Name] = $property.Value
    }
}

$permissions = [ordered]@{}

if ($settings.Contains("permissions") -and $null -ne $settings["permissions"]) {
    foreach ($property in $settings["permissions"].PSObject.Properties) {
        $permissions[$property.Name] = $property.Value
    }
}

$permissions["deny"] = @($deny)

# "allow" and "additionalDirectories" are written only when the project
# declares grants, so a project that declares none keeps whatever it already
# had in those keys.
if ($allow.Count -gt 0) {
    $permissions["allow"] = @($allow)
}

if ($additionalDirectories.Count -gt 0) {
    $permissions["additionalDirectories"] = @($additionalDirectories)
}

$settings["permissions"] = $permissions

$json = ($settings | ConvertTo-Json -Depth 20) + [Environment]::NewLine

Write-GeneratedFile -Path $settingsPath -Content $json

Write-Host "  .claude/settings.json ($($deny.Count) deny, $($allow.Count) allow, $($additionalDirectories.Count) additional directories)"

if ($mutationAuthorized) {
    Write-Host "  note: policy-file write rules omitted (policyMutationMode = always)"
}
