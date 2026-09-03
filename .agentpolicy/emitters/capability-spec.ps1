# Shared loader for .agentpolicy/capability-spec.json.
#
# Emitters dot-source this file to obtain a capability specification with
# "@name" references already resolved against the top-level collections.
#
# This file contains no agent-specific knowledge. Agent-specific translation
# belongs in the individual emitters.

Set-StrictMode -Version Latest

function Get-OptionalProperty {
    param(
        [Parameter(Mandatory)][AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    # Set-StrictMode makes reading an absent property a terminating error, and
    # every field of a project-authored declaration is potentially absent.
    if ($null -eq $Object) {
        return $Default
    }

    if ($Object.PSObject.Properties.Name -notcontains $Name) {
        return $Default
    }

    $value = $Object.$Name

    if ($null -eq $value) {
        return $Default
    }

    return $value
}

function Resolve-CapabilityReference {
    param(
        [Parameter(Mandatory)][AllowNull()]$Value,
        [Parameter(Mandatory)][hashtable]$Collections
    )

    # A reference is the literal string "@collectionName".
    if ($Value -is [string] -and $Value.StartsWith("@")) {
        $name = $Value.Substring(1)

        if (-not $Collections.ContainsKey($name)) {
            throw "Capability specification references unknown collection '@$name'."
        }

        return @($Collections[$name])
    }

    return @($Value)
}

function ConvertTo-CapabilityRule {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()]$Forbid,
        [Parameter(Mandatory)][hashtable]$Collections
    )

    $rules = foreach ($rule in @($Forbid)) {
        $targets = @()
        $paths = @()
        $patterns = @()

        if ($rule.PSObject.Properties.Name -contains "targets") {
            $targets = Resolve-CapabilityReference -Value $rule.targets -Collections $Collections
        }

        if ($rule.PSObject.Properties.Name -contains "paths") {
            $paths = Resolve-CapabilityReference -Value $rule.paths -Collections $Collections
        }

        if ($rule.PSObject.Properties.Name -contains "patterns") {
            $patterns = @($rule.patterns)
        }

        $requiresPolicyMutation = $false

        if ($rule.PSObject.Properties.Name -contains "requiresPolicyMutation") {
            $requiresPolicyMutation = [bool]$rule.requiresPolicyMutation
        }

        [pscustomobject]@{
            Id                     = Get-OptionalProperty -Object $rule -Name "id" -Default ""
            Kind                   = Get-OptionalProperty -Object $rule -Name "kind" -Default ""
            Description            = Get-OptionalProperty -Object $rule -Name "description" -Default ""
            Targets                = $targets
            Paths                  = $paths
            Patterns               = $patterns
            RequiresPolicyMutation = $requiresPolicyMutation
        }
    }

    return @($rules)
}

function Import-CapabilitySpec {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Capability specification not found: $Path"
    }

    $spec = Get-Content $Path -Raw | ConvertFrom-Json

    $collections = @{
        protectedBranches = @($spec.protectedBranches)
        policyFiles       = @($spec.policyFiles)
    }

    $rules = ConvertTo-CapabilityRule -Forbid $spec.forbid -Collections $collections

    # A path may sit inside a protected directory and still be project owned by
    # content -- the seeded testing document is the case this exists for. The
    # specification must name each one explicitly; the default is empty, so an
    # older specification protects everything it always did.
    $exemptions = @(
        Get-OptionalProperty -Object $spec -Name "policyFileExemptions" -Default @()
    )

    return [pscustomobject]@{
        SchemaVersion        = $spec.schemaVersion
        ProtectedBranches    = @($spec.protectedBranches)
        PolicyFiles          = @($spec.policyFiles)
        PolicyFileExemptions = $exemptions
        Rules                = @($rules)
        Grants               = @()
        Sandbox              = $spec.sandbox
    }
}

function Import-ProjectCapabilities {
    param(
        [Parameter(Mandatory)][string]$Path
    )

    # A project that declares nothing is represented as an empty set rather
    # than as a missing value, so callers need no special case.
    if (-not (Test-Path $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Grants = @()
            Forbid = @()
        }
    }

    $project = Get-Content $Path -Raw | ConvertFrom-Json

    $grants = foreach ($grant in @(Get-OptionalProperty -Object $project -Name "grant" -Default @())) {

        $id = [string](Get-OptionalProperty -Object $grant -Name "id" -Default "")

        if ([string]::IsNullOrWhiteSpace($id)) {
            throw "Every grant in $Path must declare an 'id'."
        }

        $kind = [string](Get-OptionalProperty -Object $grant -Name "kind" -Default "")
        $access = [string](Get-OptionalProperty -Object $grant -Name "access" -Default "")
        $commands = @(Get-OptionalProperty -Object $grant -Name "commands" -Default @())
        $paths = @(Get-OptionalProperty -Object $grant -Name "paths" -Default @())
        $tools = @(Get-OptionalProperty -Object $grant -Name "tools" -Default @())

        # A project's own script, named so that its absence can be reported and
        # so that it can be listed for the agent. It is a verification and
        # documentation hint: nothing derived from it reaches any agent's allow
        # list, so it confers no access and opens no escalation path. The
        # command prefixes in 'commands' remain the whole granted surface.
        $entrypoint = [string](Get-OptionalProperty -Object $grant -Name "entrypoint" -Default "")

        # A project's claim about whether running this changes anything outside
        # the repository. Nothing enforces it; it is carried so the generated
        # inventory can state it, because the naive guess is wrong in both
        # directions often enough to be worth writing down.
        $mutates = Get-OptionalProperty -Object $grant -Name "mutates" -Default $null

        switch ($kind) {

            "tool" {
                if ($commands.Count -eq 0) {
                    throw "Grant '$id' is of kind 'tool' and must declare 'commands'."
                }

                if (-not [string]::IsNullOrWhiteSpace($entrypoint)) {
                    $normalizedEntrypoint = $entrypoint.Replace("\", "/").Trim()

                    if ([System.IO.Path]::IsPathRooted($normalizedEntrypoint) -or
                        $normalizedEntrypoint -match '(^|/)\.\.(/|$)') {

                        throw "Grant '$id' declares entrypoint '$entrypoint', which must be a repository-relative path with no '..' segment."
                    }
                }
            }

            "path" {
                if ($paths.Count -eq 0) {
                    throw "Grant '$id' is of kind 'path' and must declare 'paths'."
                }

                if ($access -notin @("read", "write")) {
                    throw "Grant '$id' is of kind 'path' and must declare 'access' as 'read' or 'write'."
                }
            }

            "mcp" {
                if ($tools.Count -eq 0) {
                    throw "Grant '$id' is of kind 'mcp' and must declare 'tools'."
                }

                # An MCP tool name is emitted into an agent's allow list
                # verbatim, with no wrapper to constrain it. Requiring the
                # mcp__server__tool shape is what stops this kind from being
                # used to smuggle a rule of another form, such as
                # "Bash(git push --force:*)", past the central forbid checks
                # in Merge-Capabilities.
                foreach ($tool in $tools) {
                    if ($tool -notmatch '^mcp__[A-Za-z0-9][A-Za-z0-9_-]*__[A-Za-z0-9][A-Za-z0-9_-]*$') {
                        throw "Grant '$id' declares MCP tool '$tool', which is not of the form 'mcp__<server>__<tool>'."
                    }
                }
            }

            default {
                throw "Grant '$id' declares unknown kind '$kind'. Supported kinds are 'tool', 'path', and 'mcp'."
            }
        }

        [pscustomobject]@{
            Id          = $id
            Kind        = $kind
            Access      = $access
            Commands    = $commands
            Paths       = $paths
            Tools       = $tools
            Entrypoint  = ($entrypoint.Replace("\", "/").Trim())
            Mutates     = $mutates
            Description = Get-OptionalProperty -Object $grant -Name "description" -Default ""
        }
    }

    return [pscustomobject]@{
        Grants = @($grants)
        Forbid = @(Get-OptionalProperty -Object $project -Name "forbid" -Default @())
    }
}

function Test-PathWithinPolicyPath {
    param(
        [Parameter(Mandatory)][string]$Candidate,
        [Parameter(Mandatory)][string]$PolicyPath
    )

    # Compare with normalized separators so a project cannot slip past the
    # check by spelling a path differently than the specification does.
    $normalize = {
        param($value)
        ($value -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
    }

    $c = & $normalize $Candidate
    $p = & $normalize $PolicyPath

    if ($c -eq $p) {
        return $true
    }

    # A directory entry also covers everything beneath it, in either direction:
    # granting a parent of a managed path would expose that path too.
    return ($c.StartsWith($p + "/") -or $p.StartsWith($c + "/"))
}

function Merge-Capabilities {
    param(
        [Parameter(Mandatory)][pscustomobject]$Central,
        [Parameter(Mandatory)][pscustomobject]$Project
    )

    #
    # Precedence. Central rules always win.
    #
    # A project may tighten freely, but must not be able to widen its own
    # authority. Any grant that reaches a centrally managed path, or a command
    # that is centrally forbidden, is rejected outright rather than silently
    # dropped, so a mistaken declaration fails loudly.
    #

    $forbiddenCommands = @(
        $Central.Rules |
            Where-Object { $_.Kind -eq "command" } |
            ForEach-Object { $_.Patterns }
    )

    foreach ($grant in $Project.Grants) {

        if ($grant.Kind -eq "path") {
            foreach ($granted in $grant.Paths) {

                # An exactly exempted path is project owned by content and may
                # be granted. Only an exact match qualifies: accepting a parent
                # here would let a project reach the whole protected directory
                # by naming an exemption's ancestor.
                $isExempt = @($Central.PolicyFileExemptions) |
                    Where-Object {
                        ($_ -replace '\\', '/').TrimEnd('/').ToLowerInvariant() -eq
                        ($granted -replace '\\', '/').TrimEnd('/').ToLowerInvariant()
                    }

                if (@($isExempt).Count -gt 0) {
                    continue
                }

                foreach ($policyPath in $Central.PolicyFiles) {

                    if (Test-PathWithinPolicyPath -Candidate $granted -PolicyPath $policyPath) {
                        throw "Grant '$($grant.Id)' would give access to managed policy path '$policyPath' through '$granted'. A project cannot widen its own authority."
                    }
                }
            }
        }

        # 'entrypoint' and 'mutates' are deliberately absent from these checks.
        # Neither reaches an agent's allow list: the entrypoint is only resolved
        # against the filesystem by the verifier and printed in the generated
        # inventory, and 'mutates' is a description. The command prefixes below
        # remain the entire surface a project can widen, so this stays the only
        # escalation check a tool grant needs.
        if ($grant.Kind -eq "tool") {
            foreach ($command in $grant.Commands) {
                foreach ($pattern in $forbiddenCommands) {

                    if ($pattern.StartsWith($command) -or $command.StartsWith($pattern)) {
                        throw "Grant '$($grant.Id)' would permit '$command', which the central policy forbids as '$pattern'."
                    }
                }
            }
        }
    }

    #
    # Project forbid rules are additive. They are parsed through the same
    # normalization as central rules so both emit identically.
    #

    $projectRules = @()

    if (@($Project.Forbid).Count -gt 0) {
        $collections = @{
            protectedBranches = @($Central.ProtectedBranches)
            policyFiles       = @($Central.PolicyFiles)
        }

        $projectRules = ConvertTo-CapabilityRule -Forbid $Project.Forbid -Collections $collections
    }

    return [pscustomobject]@{
        SchemaVersion        = $Central.SchemaVersion
        ProtectedBranches    = $Central.ProtectedBranches
        PolicyFiles          = $Central.PolicyFiles
        PolicyFileExemptions = @($Central.PolicyFileExemptions)
        Rules                = @($Central.Rules) + @($projectRules)
        Grants               = @($Project.Grants)
        Sandbox              = $Central.Sandbox
    }
}

function Test-PolicyMutationAuthorized {
    param(
        [AllowNull()][string]$PolicyMutationMode
    )

    # Only "always" grants standing authorization. "token" authorizes a single
    # user request and therefore cannot relax a generated configuration file,
    # which has no notion of an individual request.
    return ($PolicyMutationMode -eq "always")
}

function Write-GeneratedFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Content
    )

    $parent = Split-Path $Path -Parent

    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    [System.IO.File]::WriteAllText(
        $Path,
        $Content,
        [System.Text.UTF8Encoding]::new($false)
    )
}
