[CmdletBinding()]
param(
    # When empty, the configuration file is discovered from the known
    # locations, newest layout first. An explicit value is used verbatim.
    [string]$ConfigPath = "",

    # core.hooksPath is repaired automatically only when it is unset or holds
    # a value this system is known to have written. A foreign value belongs to
    # another hook manager and is never overwritten without this switch.
    [switch]$ForceHooksPath,

    # Defines this script's functions and returns without synchronizing, so
    # the test suite can exercise them directly:
    #
    #     . ./.agentpolicy/sync.ps1 -LibraryOnly
    #
    # The installer bootstraps this script alone and it then populates
    # everything else from the manifest, so its helpers cannot be moved into a
    # separate library file without adding a second bootstrap dependency.
    [switch]$LibraryOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

#
# Layout defaults.
#
# These are the schemaVersion 1 locations. Every one of them is overridable
# through the manifest's 'paths' table, so a newer manifest can relocate the
# policy infrastructure and be executed correctly by this script.
#
$script:DefaultPaths = @{
    config              = ".agent-policy.json"
    lock                = ".agent-policy.lock.json"
    capabilitySpec      = "policy-capabilities.json"
    projectCapabilities = ".agent-capabilities.json"
    emitters            = "tools/emitters"
    verifier            = "tools/verify-capabilities.ps1"
    hooks               = "tools/git-hooks"
}

#
# Locations the configuration file has ever occupied, newest first. This list
# cannot come from the manifest: the configuration names the repository the
# manifest is fetched from, so it must be found first.
#
$script:ConfigDiscoveryOrder = @(
    ".agentpolicy/config.json",
    ".agent-policy.json"
)

#
# Hook directories this system is known to have written into core.hooksPath.
# A value outside this set belongs to another tool and is left alone.
#
$script:KnownHookDirectories = @(
    "tools/git-hooks",
    ".agentpolicy/hooks"
)

$script:MarkerBegin = "<!-- BEGIN MANAGED AGENT POLICY -->"
$script:MarkerEnd   = "<!-- END MANAGED AGENT POLICY -->"

$script:ToolingMarkerBegin = "<!-- BEGIN MANAGED PROJECT TOOLING -->"
$script:ToolingMarkerEnd   = "<!-- END MANAGED PROJECT TOOLING -->"

#
# Record of what the last synchronization installed, written inside the clone's
# Git directory rather than into the working tree.
#
# The pre-commit hook reads it to tell a synchronization result from a hand
# edit. It describes one clone's last run, which makes it per-clone state of
# exactly the kind core.hooksPath already is, and keeping it out of the working
# tree means it never becomes another generated file that has to be committed.
#
$script:SyncDigestName = "agentpolicy-sync.index"

function Assert-Command {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command '$Name' was not found in PATH."
    }
}

function Invoke-Git {
    param(
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $output = & git -C $WorkingDirectory @Arguments 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "git $($Arguments -join ' ') failed:`n$output"
    }

    return $output
}

function Get-RepositoryRoot {
    $root = & git rev-parse --show-toplevel 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) {
        throw "This command must be run from inside a Git repository."
    }

    return $root.Trim()
}

function Get-CacheKey {
    param([Parameter(Mandatory)][string]$Repository)

    return ($Repository -replace '[^A-Za-z0-9._-]', '_')
}

function Get-OptionalProperty {
    <#
        Strict mode makes an absent property an error rather than $null, so
        every optional manifest field is read through here.
    #>
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    # Indexing the property collection rather than testing its 'Name' member:
    # on an object with no properties at all, member enumeration over the
    # empty collection throws under strict mode.
    if ($null -ne $Object -and
        $null -ne $Object.PSObject.Properties[$Name] -and
        $null -ne $Object.$Name) {

        return $Object.$Name
    }

    return $Default
}

function ConvertTo-NormalizedPath {
    <#
        Repository-relative comparison form: forward slashes, no leading
        './', no trailing '/'. Used for every path equality test so that
        'tools/git-hooks', './tools/git-hooks' and 'tools\git-hooks\' all
        compare equal.
    #>
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    $normalized = $Path.Replace("\", "/").Trim()

    while ($normalized.StartsWith("./")) {
        $normalized = $normalized.Substring(2)
    }

    return $normalized.TrimEnd("/")
}

function Resolve-ManifestPaths {
    <#
        Merges the manifest's 'paths' table over the schemaVersion 1 defaults.
    #>
    param($Manifest)

    $resolved = @{}

    foreach ($key in $script:DefaultPaths.Keys) {
        $resolved[$key] = $script:DefaultPaths[$key]
    }

    $declared = Get-OptionalProperty -Object $Manifest -Name "paths"

    if ($null -ne $declared) {
        foreach ($property in $declared.PSObject.Properties) {
            if (-not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $resolved[$property.Name] = ConvertTo-NormalizedPath ([string]$property.Value)
            }
        }
    }

    return $resolved
}

function Write-RenderedFile {
    <#
        Substitutes the resolved policy mutation authorization into a template.

        The mode and the token are distinct values. Substituting the mode into
        the token placeholder would make "token" mode read as a valid token and
        silently behave as "always".
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$PolicyMutationMode,
        [string]$PolicyMutationToken
    )

    $modeValue =
        if ([string]::IsNullOrWhiteSpace($PolicyMutationMode)) {
            "never"
        }
        else {
            $PolicyMutationMode
        }

    # A token is meaningful only in "token" mode. In every other mode the
    # placeholder resolves to a value that grants nothing.
    $tokenValue =
        if ($modeValue -eq "token" -and
            -not [string]::IsNullOrWhiteSpace($PolicyMutationToken)) {
            $PolicyMutationToken
        }
        else {
            "UNSET"
        }

    if ($modeValue -eq "token" -and $tokenValue -eq "UNSET") {
        Write-Warning "policyMutationMode is 'token' but no policyMutationToken is configured. Policy mutation will remain unauthorized."
    }

    $content = Get-Content $Source -Raw
    $content = $content.Replace("{{POLICY_MUTATION_MODE}}", $modeValue)
    $content = $content.Replace("{{POLICY_MUTATION_TOKEN}}", $tokenValue)

    [System.IO.File]::WriteAllText(
        $Destination,
        $content,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Copy-ManagedFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Render,
        [string]$PolicyMutationMode,
        [string]$PolicyMutationToken
    )

    if (-not (Test-Path $Source -PathType Leaf)) {
        throw "Policy source file does not exist: $Source"
    }

    $parent = Split-Path $Destination -Parent

    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # The manifest declares which files carry placeholders. Matching on the
    # destination file name instead would silently stop rendering the moment
    # that file is renamed.
    if ($Render -eq "policy-mutation") {
        Write-RenderedFile `
            -Source $Source `
            -Destination $Destination `
            -PolicyMutationMode $PolicyMutationMode `
            -PolicyMutationToken $PolicyMutationToken

        return
    }

    Copy-Item $Source $Destination -Force
}

function Set-ExecutableBit {
    <#
        Git requires the executable bit on POSIX systems. Recording it in the
        index makes the mode survive clone on every platform.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    & git -C $RepositoryRoot update-index --add --chmod=+x $RelativePath 2>$null | Out-Null

    if ($IsLinux -or $IsMacOS) {
        & chmod +x (Join-Path $RepositoryRoot $RelativePath) 2>$null
    }
}

function Repair-HooksPath {
    <#
        core.hooksPath lives in .git/config, which is per-clone and not
        version controlled, so no file synchronization can reach it. If it
        points at a directory that no longer exists Git runs no hooks at all,
        silently, and local enforcement is gone with no diagnostic.

        A value this system wrote is repaired. A foreign value belongs to
        another hook manager -- husky, lefthook, a project's own directory --
        and overwriting it would silently disable that project's hooks, so it
        is reported and left intact.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$HooksPath,
        [string[]]$LegacyHooksPaths = @(),
        [switch]$Force
    )

    $desired = ConvertTo-NormalizedPath $HooksPath

    $current = & git -C $RepositoryRoot config --local --get core.hooksPath 2>$null

    if ($LASTEXITCODE -ne 0) {
        $current = ""
    }

    $currentNormalized = ConvertTo-NormalizedPath ([string]$current)

    if ($currentNormalized -eq $desired) {
        Write-Host "  core.hooksPath already set to $desired"
        return
    }

    $reclaimable = @($script:KnownHookDirectories) + @($LegacyHooksPaths) + @($desired) |
        ForEach-Object { ConvertTo-NormalizedPath $_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique

    # An absolute value pointing inside this repository is treated as the
    # relative path it resolves to, so earlier absolute writes are reclaimed.
    $comparable = $currentNormalized

    if (-not [string]::IsNullOrWhiteSpace($comparable)) {
        $rootNormalized = ConvertTo-NormalizedPath $RepositoryRoot

        if ($comparable.StartsWith("$rootNormalized/", [StringComparison]::OrdinalIgnoreCase)) {
            $comparable = $comparable.Substring($rootNormalized.Length + 1)
        }
    }

    $isUnset = [string]::IsNullOrWhiteSpace($currentNormalized)
    $isOurs = $comparable -in $reclaimable

    if (-not ($isUnset -or $isOurs -or $Force)) {
        Write-Warning @"
core.hooksPath is set to '$current', which this policy did not write.
Another hook manager appears to own it. Leaving it untouched: overwriting it
would silently disable that tool's hooks.

Local policy enforcement is NOT active. Resolve it one of two ways:
  - chain the policy hooks from '$current', or
  - re-run this script with -ForceHooksPath to hand control to the policy.
"@
        return
    }

    & git -C $RepositoryRoot config core.hooksPath $desired

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure core.hooksPath."
    }

    if ($isUnset) {
        Write-Host "  core.hooksPath -> $desired"
    }
    else {
        Write-Host "  core.hooksPath -> $desired (was '$current')"
    }
}

function Write-ForwardingShim {
    <#
        Installs a hook that re-executes its counterpart at the current hooks
        directory. A clone whose .git/config still names a previous hooks
        directory therefore stays fully enforced rather than silently
        unprotected, and stays enforced rather than merely blocked.

        'exec' preserves stdin, which pre-push reads its refs from, and "$@"
        preserves the arguments Git passes.

        The repository root is resolved from the shim's own location rather
        than from the working directory. Git does run hooks from the top level,
        but relying on that would make the shim fail for any other caller.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$LegacyDirectory,
        [Parameter(Mandatory)][string]$HooksPath,
        [Parameter(Mandatory)][string[]]$HookNames
    )

    $legacyNormalized = ConvertTo-NormalizedPath $LegacyDirectory
    $hooksNormalized = ConvertTo-NormalizedPath $HooksPath

    if ($legacyNormalized -eq $hooksNormalized) {
        return
    }

    $absoluteLegacy = Join-Path $RepositoryRoot $legacyNormalized

    # Only a repository that already has the legacy directory needs a shim.
    # Creating one during a fresh install would put a dead directory into a
    # project that never had the old layout.
    if (-not (Test-Path $absoluteLegacy -PathType Container)) {
        return
    }

    foreach ($hook in $HookNames) {
        $shimPath = Join-Path $absoluteLegacy $hook

        $lines = @(
            "#!/bin/sh",
            "#",
            "# Forwarding shim written by agent policy synchronization.",
            "#",
            "# The policy hooks now live in $hooksNormalized. This shim keeps a clone",
            "# whose .git/config still points here fully enforced. It is removed in a",
            "# later policy revision, once every consumer has synchronized.",
            "",
            "set -eu",
            "",
            "root=`$(cd `"`$(dirname `"`$0`")`" && git rev-parse --show-toplevel)",
            "",
            "exec `"`$root/$hooksNormalized/`$(basename `"`$0`")`" `"`$@`""
        )

        [System.IO.File]::WriteAllText(
            $shimPath,
            ($lines -join "`n") + "`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        Set-ExecutableBit `
            -RepositoryRoot $RepositoryRoot `
            -RelativePath "$legacyNormalized/$hook"

        Write-Host "  forwarding shim $legacyNormalized/$hook -> $hooksNormalized/$hook"
    }
}

function Install-GitHooks {
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$HooksPath,
        [Parameter(Mandatory)][string[]]$HookNames,
        [Parameter(Mandatory)][string[]]$ProtectedBranches,
        [Parameter(Mandatory)][string[]]$PolicyFiles,
        [Parameter(Mandatory)][string]$ConfigRelativePath,
        [Parameter(Mandatory)][string]$SyncCommand,
        [string[]]$PolicyFileExemptions = @(),
        [string[]]$LegacyHooksPaths = @(),
        [switch]$ForceHooksPath
    )

    $hooksRelative = ConvertTo-NormalizedPath $HooksPath
    $hooksDirectory = Join-Path $RepositoryRoot $hooksRelative

    if (-not (Test-Path $hooksDirectory)) {
        throw "Git hook directory was not installed: $hooksDirectory"
    }

    # Configuration consumed by the POSIX hook scripts, which avoid parsing
    # JSON so they remain dependency-free. The hooks refuse to run when this
    # file is absent rather than falling back to a stale built-in list.
    #
    # Every path the hooks need is emitted here, so relocating the layout is a
    # manifest change and never an edit to a hook.
    $envLines = @(
        "# Generated during agent policy synchronization from the capability specification.",
        "# Edits are overwritten on the next synchronization.",
        "",
        "PROTECTED_BRANCHES=`"$($ProtectedBranches -join ' ')`"",
        "POLICY_FILES=`"$($PolicyFiles -join ' ')`"",
        "POLICY_FILE_EXEMPTIONS=`"$($PolicyFileExemptions -join ' ')`"",
        "CONFIG_PATH=`"$ConfigRelativePath`"",
        "SYNC_COMMAND=`"$SyncCommand`"",
        "SYNC_DIGEST_NAME=`"$script:SyncDigestName`""
    )

    [System.IO.File]::WriteAllText(
        (Join-Path $hooksDirectory "policy.env"),
        ($envLines -join "`n") + "`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    foreach ($hook in $HookNames) {
        Set-ExecutableBit `
            -RepositoryRoot $RepositoryRoot `
            -RelativePath "$hooksRelative/$hook"
    }

    Repair-HooksPath `
        -RepositoryRoot $RepositoryRoot `
        -HooksPath $hooksRelative `
        -LegacyHooksPaths $LegacyHooksPaths `
        -Force:$ForceHooksPath

    foreach ($legacy in $LegacyHooksPaths) {
        Write-ForwardingShim `
            -RepositoryRoot $RepositoryRoot `
            -LegacyDirectory $legacy `
            -HooksPath $hooksRelative `
            -HookNames $HookNames
    }

    Write-Host "  protected branches: $($ProtectedBranches -join ', ')"
}

function Get-GitDirectory {
    param([Parameter(Mandatory)][string]$RepositoryRoot)

    $directory = & git -C $RepositoryRoot rev-parse --absolute-git-dir 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($directory)) {
        throw "Unable to locate the Git directory for '$RepositoryRoot'."
    }

    return $directory.Trim()
}

function Write-SynchronizationDigest {
    <#
        Records the identity of every file this run installed, so the
        pre-commit hook can tell a synchronization result from a hand edit.

        Matching on path alone cannot make that distinction, and refusing every
        staged policy path is what made an installation impossible to commit.

        The recorded identity is a Git blob id rather than a plain content
        hash. 'git hash-object' applies the same clean filters staging does, so
        the value here is exactly what 'git add' will put in the index. A raw
        hash of the working-tree bytes would disagree with the index the moment
        a project normalizes line endings, and would fail every commit on
        Windows while appearing correct everywhere it was tested.

        Written last, after the lock file and after this script has updated
        itself, so it describes the tree as synchronization finally left it.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RelativePaths
    )

    $records = @()

    foreach ($relativePath in ($RelativePaths | Select-Object -Unique)) {

        if ([string]::IsNullOrWhiteSpace($relativePath)) {
            continue
        }

        $normalized = ConvertTo-NormalizedPath $relativePath

        if (-not (Test-Path (Join-Path $RepositoryRoot $normalized) -PathType Leaf)) {
            continue
        }

        $blob = & git -C $RepositoryRoot hash-object -- $normalized 2>$null

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($blob)) {
            throw "Unable to record the installed identity of '$normalized'."
        }

        $records += "$($blob.Trim()) $normalized"
    }

    $lines = @(
        "# Generated during agent policy synchronization.",
        "# Git blob id of every file this synchronization installed.",
        "# Read by the pre-commit hook. Not tracked, and not edited by hand."
    ) + $records

    $digestPath = Join-Path (Get-GitDirectory -RepositoryRoot $RepositoryRoot) $script:SyncDigestName

    [System.IO.File]::WriteAllText(
        $digestPath,
        ($lines -join "`n") + "`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "  recorded $($records.Count) installed files"
}

function Write-ManagedRegion {
    <#
        Rewrites only the text between the managed markers, leaving everything
        a project wrote around them untouched. This is what allows a file the
        project owns -- its root AGENTS.md -- to carry managed policy content
        without synchronization destroying the project's own material.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$Body,

        # A file may carry more than one managed region -- the policy summary
        # and the generated project tooling inventory both live in the root
        # instruction file -- so the marker pair is a parameter rather than a
        # constant. Defaults preserve the original single-region behavior.
        [string]$BeginMarker,
        [string]$EndMarker
    )

    if ([string]::IsNullOrWhiteSpace($BeginMarker)) { $BeginMarker = $script:MarkerBegin }
    if ([string]::IsNullOrWhiteSpace($EndMarker)) { $EndMarker = $script:MarkerEnd }

    $regionLines = @($BeginMarker, $Body.TrimEnd(), $EndMarker)
    $region = $regionLines -join "`n"

    if (-not (Test-Path $Destination -PathType Leaf)) {
        $parent = Split-Path $Destination -Parent

        if ($parent -and -not (Test-Path $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }

        [System.IO.File]::WriteAllText(
            $Destination,
            $region + "`n",
            [System.Text.UTF8Encoding]::new($false)
        )

        return
    }

    $existing = [System.IO.File]::ReadAllText($Destination)

    # Preserve whichever newline style the project's file already uses.
    $usesCrLf = $existing.Contains("`r`n")
    $normalized = $existing.Replace("`r`n", "`n")

    $beginCount = ([regex]::Matches($normalized, [regex]::Escape($BeginMarker))).Count
    $endCount = ([regex]::Matches($normalized, [regex]::Escape($EndMarker))).Count

    if ($beginCount -gt 1 -or $endCount -gt 1) {
        throw "Duplicate managed policy markers in $Destination. Remove the extra markers and synchronize again."
    }

    if ($beginCount -ne $endCount) {
        throw "Unbalanced managed policy markers in $Destination. Restore the matching marker and synchronize again."
    }

    if ($beginCount -eq 0) {
        $updated = $normalized.TrimEnd() + "`n`n" + $region + "`n"
    }
    else {
        $pattern =
            [regex]::Escape($BeginMarker) +
            "[\s\S]*?" +
            [regex]::Escape($EndMarker)

        $updated = [regex]::Replace($normalized, $pattern, { $region })
    }

    if ($usesCrLf) {
        $updated = $updated.Replace("`n", "`r`n")
    }

    [System.IO.File]::WriteAllText(
        $Destination,
        $updated,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Get-DeclaredProjectTooling {
    <#
        Reads the project's declared tooling out of its capability file.

        Deliberately a shallow reader rather than a call into
        emitters/capability-spec.ps1: that library defines its own
        Get-OptionalProperty, and dot-sourcing it here would silently replace
        this engine's. The emitter validates the same file authoritatively
        moments later, so a malformed declaration still fails the run -- this
        pass only needs enough of the shape to render a table.
    #>
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        return @()
    }

    try {
        $project = Get-Content $Path -Raw | ConvertFrom-Json
    }
    catch {
        # The emitter reports the real parse error with context.
        return @()
    }

    $declared = @()

    foreach ($grant in @(Get-OptionalProperty -Object $project -Name "grant" -Default @())) {

        $entrypoint = [string](Get-OptionalProperty -Object $grant -Name "entrypoint" -Default "")

        # Only a grant that names one of the project's own scripts belongs in
        # an inventory of that project's tooling.
        if ([string]::IsNullOrWhiteSpace($entrypoint)) {
            continue
        }

        $mutates = Get-OptionalProperty -Object $grant -Name "mutates" -Default $null

        $declared += [pscustomobject]@{
            Id          = [string](Get-OptionalProperty -Object $grant -Name "id" -Default "")
            Commands    = @(Get-OptionalProperty -Object $grant -Name "commands" -Default @())
            Entrypoint  = $entrypoint.Replace("\", "/").Trim()
            Mutates     = $mutates
            Description = [string](Get-OptionalProperty -Object $grant -Name "description" -Default "")
        }
    }

    return $declared
}

function Write-ProjectToolingRegion {
    <#
        Renders the project's declared tooling into a managed region of a file
        the project owns.

        This is the only place a grant's 'description' reaches an agent. Without
        it, a project's tooling is discoverable only through whatever prose that
        project happened to write in one agent's native file, which is how a
        repository ends up with its whole operational workflow visible to one
        agent and invisible to another.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][array]$Tooling
    )

    $lines = [System.Collections.Generic.List[string]]::new()

    $lines.Add("## Project tooling")
    $lines.Add("")
    $lines.Add("Generated from the declared grants in this project's capability file. Run each")
    $lines.Add("task through the command shown; it is the form the agent is permitted to use.")
    $lines.Add("")
    $lines.Add("The order to run these in, which to prefer where two overlap, and any step that")
    $lines.Add("has no command belong in this file's own prose, outside the managed markers.")
    $lines.Add("")
    $lines.Add("| Task | Command | Changes state | Purpose |")
    $lines.Add("|---|---|---|---|")

    foreach ($task in $Tooling) {

        $command =
            if ($task.Commands.Count -gt 0) {
                '`' + ([string]$task.Commands[0]) + '`'
            }
            else {
                '`' + $task.Entrypoint + '`'
            }

        $mutates =
            if ($null -eq $task.Mutates) { "not stated" }
            elseif ([bool]$task.Mutates) { "yes" }
            else { "no" }

        $description =
            if ([string]::IsNullOrWhiteSpace($task.Description)) { "--" }
            else { ($task.Description -replace '\|', '\|') -replace '\r?\n', ' ' }

        $lines.Add("| $($task.Id) | $command | $mutates | $description |")
    }

    $lines.Add("")
    $lines.Add("'Changes state' is the project's own claim, not an enforced property. Nothing")
    $lines.Add("prevents a task marked 'no' from writing somewhere; treat it as documentation.")

    Write-ManagedRegion `
        -Destination (Join-Path $RepositoryRoot $Destination) `
        -Body ($lines -join "`n") `
        -BeginMarker $script:ToolingMarkerBegin `
        -EndMarker $script:ToolingMarkerEnd

    Write-Host "  project tooling inventory -> $Destination ($($Tooling.Count) task(s))"
}

function Write-DeprecatedEntryPoint {
    <#
        Leaves a working script at a previous entry point so a project's own
        documentation, scripts, or muscle memory keep functioning after the
        entry point moves.

        Only rewritten where the old path already exists: a fresh install must
        not acquire a stub for a layout it never had.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$LegacyPath,
        [Parameter(Mandatory)][string]$CurrentPath
    )

    $legacyNormalized = ConvertTo-NormalizedPath $LegacyPath
    $currentNormalized = ConvertTo-NormalizedPath $CurrentPath

    if ($legacyNormalized -eq $currentNormalized) {
        return
    }

    $absoluteLegacy = Join-Path $RepositoryRoot $legacyNormalized

    if (-not (Test-Path $absoluteLegacy -PathType Leaf)) {
        return
    }

    $lines = @(
        "#",
        "# Deprecated entry point. Agent policy synchronization now lives at:",
        "#",
        "#     ./$currentNormalized",
        "#",
        "# This forwarder is removed in a later policy revision.",
        "#",
        "",
        "Write-Warning `"$legacyNormalized has moved to $currentNormalized. Update any script or document that calls the old path.`"",
        "",
        "& (Join-Path (& git rev-parse --show-toplevel).Trim() `"$currentNormalized`") @args",
        "",
        "exit `$LASTEXITCODE"
    )

    [System.IO.File]::WriteAllText(
        $absoluteLegacy,
        ($lines -join "`n") + "`n",
        [System.Text.UTF8Encoding]::new($false)
    )

    Write-Host "  deprecated entry point $legacyNormalized -> $currentNormalized"
}

function Move-ProjectOwnedFile {
    <#
        Relocates a file whose content belongs to the project -- its declared
        capability grants, its policy configuration. These are never recreated
        from a template, because doing so would silently discard the project's
        own decisions.

        The move happens only when the old path exists and the new one does
        not, which makes it safe to run on every synchronization.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To
    )

    $fromRelative = ConvertTo-NormalizedPath $From
    $toRelative = ConvertTo-NormalizedPath $To

    if ($fromRelative -eq $toRelative) {
        return
    }

    $source = Join-Path $RepositoryRoot $fromRelative
    $destination = Join-Path $RepositoryRoot $toRelative

    if (-not (Test-Path $source -PathType Leaf)) {
        return
    }

    if (Test-Path $destination) {
        Write-Warning "Both $fromRelative and $toRelative exist. Keeping $toRelative and leaving $fromRelative in place for you to reconcile and delete."
        return
    }

    $parent = Split-Path $destination -Parent

    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    Write-Host "Migrating project-owned file $fromRelative -> $toRelative"

    Move-Item -Path $source -Destination $destination
}

function Remove-RetiredFile {
    <#
        Deletes a file a previous layout installed. Without this, every
        consumer keeps dead policy files at their old paths forever -- and
        because the protected-file list no longer covers those paths, an agent
        would be free to edit a stale copy of the enforcement machinery.

        Only exact paths the manifest names are removed. Never globs.
    #>
    param(
        [Parameter(Mandatory)][string]$RepositoryRoot,
        [Parameter(Mandatory)][string]$RelativePath
    )

    $relative = ConvertTo-NormalizedPath $RelativePath

    if ([string]::IsNullOrWhiteSpace($relative) -or
        $relative.Contains("..") -or
        [System.IO.Path]::IsPathRooted($relative)) {

        throw "Refusing to remove an unsafe path from the manifest: '$RelativePath'"
    }

    $absolute = Join-Path $RepositoryRoot $relative

    if (-not (Test-Path $absolute -PathType Leaf)) {
        return
    }

    Write-Host "Removing retired file $relative"

    Remove-Item $absolute -Force

    # Prune directories the removal emptied, stopping at the repository root.
    $parent = Split-Path $absolute -Parent
    $rootFull = [System.IO.Path]::GetFullPath($RepositoryRoot)

    while ($parent) {
        $parentFull = [System.IO.Path]::GetFullPath($parent)

        if ($parentFull -eq $rootFull -or -not $parentFull.StartsWith($rootFull)) {
            break
        }

        if (@(Get-ChildItem -Path $parent -Force).Count -ne 0) {
            break
        }

        Remove-Item $parent -Force
        $parent = Split-Path $parent -Parent
    }
}

if ($LibraryOnly) {
    return
}

Assert-Command "git"
Assert-Command "gh"

$repositoryRoot = Get-RepositoryRoot

#
# Locate the configuration. An explicit -ConfigPath is authoritative;
# otherwise the known locations are searched newest layout first so a
# repository that has already migrated is found before the legacy path.
#

$configFile = $null
$configRelative = $null

if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    $configRelative = ConvertTo-NormalizedPath $ConfigPath
    $configFile = Join-Path $repositoryRoot $configRelative

    if (-not (Test-Path $configFile -PathType Leaf)) {
        throw "Agent policy configuration not found: $configFile"
    }
}
else {
    foreach ($candidate in $script:ConfigDiscoveryOrder) {
        $probe = Join-Path $repositoryRoot $candidate

        if (Test-Path $probe -PathType Leaf) {
            $configRelative = $candidate
            $configFile = $probe
            break
        }
    }

    if ($null -eq $configFile) {
        throw "Agent policy configuration not found. Looked for: $($script:ConfigDiscoveryOrder -join ', ')"
    }
}

$config = Get-Content $configFile -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($config.repository)) {
    throw "'repository' must be specified in $configRelative."
}

if ([string]::IsNullOrWhiteSpace($config.agent)) {
    throw "'agent' must be specified in $configRelative."
}

$requestedVersion =
    if ([string]::IsNullOrWhiteSpace($config.version)) {
        "latest"
    }
    else {
        $config.version
    }

$agent = $config.agent.ToLowerInvariant()

$policyMutationMode = [string](Get-OptionalProperty -Object $config -Name "policyMutationMode")
$policyMutationToken = [string](Get-OptionalProperty -Object $config -Name "policyMutationToken")

if (-not [string]::IsNullOrWhiteSpace($policyMutationMode) -and
    $policyMutationMode -notin @("never", "token", "always")) {
    throw "'policyMutationMode' must be one of: never, token, always. Found: '$policyMutationMode'."
}

$cacheBase =
    if ($env:LOCALAPPDATA) {
        Join-Path $env:LOCALAPPDATA "AgentPolicy"
    }
    else {
        Join-Path $HOME ".agent-policy"
    }

$cacheKey = Get-CacheKey $config.repository
$cachePath = Join-Path $cacheBase $cacheKey

New-Item -ItemType Directory -Path $cacheBase -Force | Out-Null

if (-not (Test-Path (Join-Path $cachePath ".git"))) {
    Write-Host "Cloning agent policy repository..."

    & gh repo clone $config.repository $cachePath -- --no-checkout

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to clone policy repository '$($config.repository)'."
    }
}
else {
    Write-Host "Updating cached policy repository..."
}

Invoke-Git $cachePath @(
    "fetch",
    "--tags",
    "--prune",
    "origin"
) | Out-Null

if ($requestedVersion -eq "latest") {
    $tags = Invoke-Git $cachePath @(
        "tag",
        "--list",
        "v*",
        "--sort=-version:refname"
    )

    $resolvedVersion = $tags |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -First 1

    if ([string]::IsNullOrWhiteSpace($resolvedVersion)) {
        Write-Warning "No version tags matching 'v*' exist. Falling back to origin/main."
        $resolvedVersion = "origin/main"
    }
}
else {
    $resolvedVersion = $requestedVersion
}

$commit = (
    Invoke-Git $cachePath @(
        "rev-parse",
        "$resolvedVersion^{commit}"
    )
).Trim()

Write-Host "Policy version: $resolvedVersion"
Write-Host "Policy commit:  $commit"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "agent-policy-" + [guid]::NewGuid().ToString("N")
)

New-Item -ItemType Directory -Path $tempRoot | Out-Null

try {
    Invoke-Git $cachePath @(
        "worktree",
        "add",
        "--detach",
        $tempRoot,
        $commit
    ) | Out-Null

    $manifestPath = Join-Path $tempRoot "policy-manifest.json"

    if (-not (Test-Path $manifestPath -PathType Leaf)) {
        throw "Policy manifest not found: policy-manifest.json"
    }

    $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

    $paths = Resolve-ManifestPaths -Manifest $manifest

    $legacy = Get-OptionalProperty -Object $manifest -Name "legacyPaths"
    $legacyHooks = @(Get-OptionalProperty -Object $legacy -Name "hooks" -Default @())

    #
    # Move the configuration file if the manifest has relocated it. Nothing in
    # the file table can do this: the configuration is project owned, written
    # by the installer, and never distributed.
    #

    $configTarget = ConvertTo-NormalizedPath $paths["config"]

    if ($configTarget -ne (ConvertTo-NormalizedPath $configRelative)) {
        $configDestination = Join-Path $repositoryRoot $configTarget
        $configParent = Split-Path $configDestination -Parent

        if ($configParent -and -not (Test-Path $configParent)) {
            New-Item -ItemType Directory -Path $configParent -Force | Out-Null
        }

        Write-Host "Migrating configuration $configRelative -> $configTarget"

        Move-Item -Path $configFile -Destination $configDestination -Force

        $configFile = $configDestination
        $configRelative = $configTarget
    }

    #
    # Relocate project-owned content, then retire paths whose content is
    # centrally managed and now lives elsewhere.
    #
    # Both happen before anything is installed, so seeding sees a root that no
    # longer holds the previous layout and correctly recreates what belongs at
    # the new location.
    #

    foreach ($entry in @(Get-OptionalProperty -Object $manifest -Name "migratedFiles" -Default @())) {
        Move-ProjectOwnedFile `
            -RepositoryRoot $repositoryRoot `
            -From ([string]$entry.from) `
            -To ([string]$entry.to)
    }

    foreach ($retired in @(Get-OptionalProperty -Object $manifest -Name "removedFiles" -Default @())) {
        Remove-RetiredFile -RepositoryRoot $repositoryRoot -RelativePath ([string]$retired)
    }

    #
    # Install centrally managed files.
    #
    # The synchronization script is deliberately installed last so that this
    # invocation completes using the version of the script with which it
    # started. The manifest flags which entry that is; matching on a path
    # literal would break silently the moment the script is relocated.
    #

    $managedFiles = @($manifest.managedFiles)

    $selfUpdateFile = $managedFiles | Where-Object {
        [bool](Get-OptionalProperty -Object $_ -Name "selfUpdate" -Default $false)
    }

    $normalManagedFiles = $managedFiles | Where-Object {
        -not [bool](Get-OptionalProperty -Object $_ -Name "selfUpdate" -Default $false)
    }

    if (@($selfUpdateFile).Count -ne 1) {
        throw "policy-manifest.json must mark exactly one managed file with 'selfUpdate': true. Found $(@($selfUpdateFile).Count)."
    }

    # Collapse to a scalar so later property access cannot silently operate on
    # a single-element array.
    $selfUpdateFile = @($selfUpdateFile)[0]

    foreach ($entry in $normalManagedFiles) {
        $sourceRelative = $entry.source.Replace("{agent}", $agent)
        $destinationRelative = $entry.destination.Replace("{agent}", $agent)

        $source = Join-Path $tempRoot $sourceRelative
        $destination = Join-Path $repositoryRoot $destinationRelative

        Write-Host "Syncing $destinationRelative"

        Copy-ManagedFile `
            -Source $source `
            -Destination $destination `
            -Render ([string](Get-OptionalProperty -Object $entry -Name "render")) `
            -PolicyMutationMode $policyMutationMode `
            -PolicyMutationToken $policyMutationToken
    }

    #
    # Seed project-owned files only when absent.
    #

    foreach ($entry in @($manifest.seedFiles)) {
        $sourceRelative = $entry.source.Replace("{agent}", $agent)
        $destinationRelative = $entry.destination.Replace("{agent}", $agent)

        $source = Join-Path $tempRoot $sourceRelative
        $destination = Join-Path $repositoryRoot $destinationRelative

        if (-not (Test-Path $destination)) {
            Write-Host "Creating project-owned file $destinationRelative"

            Copy-ManagedFile `
                -Source $source `
                -Destination $destination `
                -Render ([string](Get-OptionalProperty -Object $entry -Name "render")) `
                -PolicyMutationMode $policyMutationMode `
                -PolicyMutationToken $policyMutationToken
        }
        else {
            Write-Host "Preserving project-owned file $destinationRelative"
        }
    }

    #
    # Refresh the managed region inside each agent-native instruction file.
    #
    # These files are project owned. Only the marked region is rewritten, so a
    # project's own instructions survive synchronization intact.
    #

    $nativeFiles = Get-OptionalProperty -Object $manifest -Name "nativeInstructionFiles"
    $agentNativeFiles = @(Get-OptionalProperty -Object $nativeFiles -Name $agent -Default @())

    foreach ($entry in $agentNativeFiles) {
        $regionSource = Join-Path $tempRoot ([string]$entry.source)
        $regionDestination = Join-Path $repositoryRoot ([string]$entry.destination)

        if (-not (Test-Path $regionSource -PathType Leaf)) {
            throw "Managed region source not found: $($entry.source)"
        }

        Write-Host "Refreshing managed region in $($entry.destination)"

        Write-ManagedRegion `
            -Destination $regionDestination `
            -Body (Get-Content $regionSource -Raw)
    }

    #
    # Emit agent-specific enforcement configuration from the agent-neutral
    # capability specification, then install the agent-agnostic Git hooks.
    #
    # The generated agent configuration fails fast on the common literal forms
    # of a prohibited action. The Git hooks inspect the refs and files actually
    # involved and are therefore the authoritative local layer.
    #

    $capabilitySpecPath = Join-Path $repositoryRoot $paths["capabilitySpec"]
    $projectCapabilities = Join-Path $repositoryRoot $paths["projectCapabilities"]

    if (Test-Path $capabilitySpecPath -PathType Leaf) {

        Write-Host ""
        Write-Host "Emitting enforcement configuration for '$agent':"

        $emitter = Join-Path $repositoryRoot "$($paths['emitters'])/$agent.ps1"

        if (-not (Test-Path $emitter -PathType Leaf)) {
            throw "No capability emitter exists for agent '$agent': $emitter"
        }

        # The emitter is a PowerShell script and signals failure by throwing,
        # which propagates through $ErrorActionPreference = "Stop".
        & $emitter `
            -RepositoryRoot $repositoryRoot `
            -CapabilitySpecPath $capabilitySpecPath `
            -ProjectCapabilitiesPath $projectCapabilities `
            -PolicyMutationMode $policyMutationMode

        $capabilities = Get-Content $capabilitySpecPath -Raw | ConvertFrom-Json

        # The hook names come from the file table, so adding a hook to the
        # manifest is enough to have it made executable and shimmed.
        $hooksRelative = ConvertTo-NormalizedPath $paths["hooks"]

        $hookNames = @(
            $managedFiles |
                ForEach-Object { ConvertTo-NormalizedPath $_.destination } |
                Where-Object { $_.StartsWith("$hooksRelative/") } |
                ForEach-Object { Split-Path $_ -Leaf }
        )

        if ($hookNames.Count -eq 0) {
            throw "policy-manifest.json declares no hook files under '$hooksRelative'."
        }

        Install-GitHooks `
            -RepositoryRoot $repositoryRoot `
            -HooksPath $hooksRelative `
            -HookNames $hookNames `
            -ProtectedBranches @($capabilities.protectedBranches) `
            -PolicyFiles @($capabilities.policyFiles) `
            -ConfigRelativePath $configRelative `
            -SyncCommand "./$(ConvertTo-NormalizedPath $selfUpdateFile.destination)" `
            -PolicyFileExemptions @(Get-OptionalProperty -Object $capabilities -Name "policyFileExemptions" -Default @()) `
            -LegacyHooksPaths $legacyHooks `
            -ForceHooksPath:$ForceHooksPath

        #
        # Report where a declared capability and the operating system
        # disagree. Non-strict: an unreachable share must not break a sync.
        #

        $verifier = Join-Path $repositoryRoot $paths["verifier"]

        if ((Test-Path $verifier -PathType Leaf) -and
            (Test-Path $projectCapabilities -PathType Leaf)) {

            & $verifier -ProjectCapabilitiesPath $projectCapabilities
        }
    }
    else {
        Write-Warning "$($paths['capabilitySpec']) is absent; no enforcement configuration was generated."
    }

    #
    # Publish the project's declared tooling into every file an agent reads on
    # its own, so the inventory does not depend on which agent is configured.
    #
    # After the emitter, so a malformed capability file has already failed the
    # run rather than being half-rendered here first.
    #

    $toolingRegion = Get-OptionalProperty -Object $manifest -Name "projectToolingRegion"
    $toolingEnabled = [bool](Get-OptionalProperty -Object $toolingRegion -Name "enabled" -Default $false)

    if ($toolingEnabled) {

        $declaredTooling = @(Get-DeclaredProjectTooling -Path $projectCapabilities)

        # A project that has declared no entrypoints gets no region at all,
        # rather than an empty table it then has to wonder about.
        if ($declaredTooling.Count -gt 0) {

            Write-Host ""
            Write-Host "Publishing declared project tooling:"

            foreach ($entry in $agentNativeFiles) {
                Write-ProjectToolingRegion `
                    -RepositoryRoot $repositoryRoot `
                    -Destination ([string]$entry.destination) `
                    -Tooling $declaredTooling
            }
        }
    }

    #
    # Record the exact installed policy revision.
    #

    $lock = [ordered]@{
        repository = $config.repository
        requestedVersion = $requestedVersion
        resolvedVersion = $resolvedVersion
        commit = $commit
        agent = $agent
        syncedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $lockRelative = ConvertTo-NormalizedPath $paths["lock"]
    $lockPath = Join-Path $repositoryRoot $lockRelative
    $lockParent = Split-Path $lockPath -Parent

    if ($lockParent -and -not (Test-Path $lockParent)) {
        New-Item -ItemType Directory -Path $lockParent -Force | Out-Null
    }

    $lock |
        ConvertTo-Json -Depth 10 |
        Set-Content `
            -Path $lockPath `
            -Encoding utf8

    #
    # Self-update last.
    #

    foreach ($entry in @($selfUpdateFile)) {
        $source = Join-Path $tempRoot $entry.source
        $destination = Join-Path $repositoryRoot $entry.destination

        Write-Host "Updating policy synchronization script"

        Copy-ManagedFile `
            -Source $source `
            -Destination $destination `
            -Render ([string](Get-OptionalProperty -Object $entry -Name "render")) `
            -PolicyMutationMode $policyMutationMode `
            -PolicyMutationToken $policyMutationToken
    }

    #
    # Keep a previous entry point working, so a project's own scripts and
    # documentation survive the move. Written after self-update, because the
    # script being forwarded to has to exist first.
    #

    foreach ($legacyEntry in @(Get-OptionalProperty -Object $legacy -Name "syncScript" -Default @())) {
        Write-DeprecatedEntryPoint `
            -RepositoryRoot $repositoryRoot `
            -LegacyPath ([string]$legacyEntry) `
            -CurrentPath $selfUpdateFile.destination
    }

    #
    # Record what this run installed.
    #
    # Last, so every managed file, the generated hook configuration and the
    # lock file are all in their final state. The pre-commit hook compares
    # staged content against this record, which is what allows a project to
    # commit an installation and every later synchronization result while a
    # hand edit to the same paths is still refused.
    #

    Write-Host ""
    Write-Host "Recording installed policy files:"

    Write-SynchronizationDigest `
        -RepositoryRoot $repositoryRoot `
        -RelativePaths (
            @(
                $managedFiles |
                    ForEach-Object { ([string]$_.destination).Replace("{agent}", $agent) }
            ) + @(
                "$(ConvertTo-NormalizedPath $paths['hooks'])/policy.env",
                $lockRelative
            )
        )

    Write-Host ""
    Write-Host "Agent policy synchronization complete."
    Write-Host "Applied: $resolvedVersion ($commit)"
}
finally {
    if (Test-Path $tempRoot) {
        try {
            Invoke-Git $cachePath @(
                "worktree",
                "remove",
                "--force",
                $tempRoot
            ) | Out-Null
        }
        catch {
            Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
