[CmdletBinding()]
param(
    [string]$ProjectCapabilitiesPath,

    # Exit non-zero when any finding is reported. Synchronization runs without
    # this so an unreachable share does not break a sync; continuous
    # integration should run with it.
    [switch]$Strict
)

# Verifies that declared capabilities match what the operating system actually
# permits.
#
# A declaration is a statement of intent. Nothing in the generated agent
# configuration makes a path read-only: any granted shell command runs with
# the user's own permissions. The declaration is therefore only as true as the
# mount or the access-control list behind it, and this script reports where
# the two disagree.
#
# Findings are described, never repaired. Changing a mount or an access-control
# list is the user's decision, not an agent's.

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "emitters/capability-spec.ps1")

$repositoryRoot = (& git rev-parse --show-toplevel).Trim()

if ([string]::IsNullOrWhiteSpace($ProjectCapabilitiesPath)) {
    $ProjectCapabilitiesPath = Join-Path $repositoryRoot ".agentpolicy/capabilities.json"
}

$project = Import-ProjectCapabilities -Path $ProjectCapabilitiesPath

if (@($project.Grants).Count -eq 0) {
    Write-Host "No capability grants are declared; nothing to verify."
    exit 0
}

$findings = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)][ValidateSet("ERROR", "WARN")][string]$Severity,
        [Parameter(Mandatory)][string]$GrantId,
        [Parameter(Mandatory)][string]$Message
    )

    $findings.Add([pscustomobject]@{
        Severity = $Severity
        GrantId  = $GrantId
        Message  = $Message
    })
}

function Test-PathIsWritable {
    param([Parameter(Mandatory)][string]$Path)

    # Probe by attempting a write. Access-control lists, share-level
    # permissions and read-only mounts do not all surface the same way, so an
    # actual attempt is the only reliable check.
    $probe = Join-Path $Path (".agent-policy-write-probe-" + [guid]::NewGuid().ToString("N"))

    try {
        [System.IO.File]::WriteAllText($probe, "probe")
        Remove-Item $probe -Force -ErrorAction SilentlyContinue
        return $true
    }
    catch {
        return $false
    }
}

Write-Host ""
Write-Host "Verifying declared capabilities against the operating system"
Write-Host "------------------------------------------------------------"

foreach ($grant in $project.Grants) {

    switch ($grant.Kind) {

        "tool" {
            #
            # A tool grant names a command *prefix*, not an executable. Agent
            # configuration matches shell commands by prefix, so a project may
            # legitimately grant "git status" in order to permit that one
            # subcommand without granting bare "git".
            #
            # Only the first token is a program PATH can resolve. Resolving the
            # whole prefix reported every multi-word grant as missing, which
            # buried the real findings under noise.
            #
            $executables = @(
                $grant.Commands |
                    ForEach-Object { @($_ -split '\s+' | Where-Object { $_ })[0] } |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                    Select-Object -Unique
            )

            foreach ($executable in $executables) {

                # Which granted prefixes rely on this executable, so a finding
                # names what the project actually declared.
                $prefixes = @(
                    $grant.Commands |
                        Where-Object {
                            @($_ -split '\s+' | Where-Object { $_ })[0] -eq $executable
                        }
                )

                if ($null -eq (Get-Command $executable -ErrorAction SilentlyContinue)) {
                    Add-Finding -Severity "WARN" -GrantId $grant.Id `
                        -Message "'$executable' was not found on PATH; it is required by $($prefixes.Count) granted command prefix(es): $($prefixes -join ', ')."
                }
                elseif ($prefixes.Count -eq 1 -and $prefixes[0] -eq $executable) {
                    Write-Host "  ok    tool '$executable' is available"
                }
                else {
                    Write-Host "  ok    tool '$executable' is available ($($prefixes.Count) granted prefix(es))"
                }
            }

            #
            # A declared entrypoint is a file in this repository, so its absence
            # is a fact about the repository rather than about this machine.
            # That is why it is an ERROR while a tool missing from PATH is only
            # a warning: a renamed or deleted script means the workflow the
            # project documented no longer exists.
            #
            if (-not [string]::IsNullOrWhiteSpace($grant.Entrypoint)) {

                $entrypointPath = Join-Path $repositoryRoot $grant.Entrypoint

                if (-not (Test-Path $entrypointPath -PathType Leaf)) {
                    Add-Finding -Severity "ERROR" -GrantId $grant.Id `
                        -Message "declared entrypoint '$($grant.Entrypoint)' does not exist. The grant permits a command that cannot run."
                }
                else {
                    # A rename done in one place only leaves the entrypoint and
                    # the granted prefix pointing at different files, and the
                    # grant then permits something the project no longer means.
                    $leaf = Split-Path $grant.Entrypoint -Leaf

                    $referencing = @(
                        $grant.Commands |
                            Where-Object {
                                $_.Replace("\", "/") -like "*$($grant.Entrypoint)*" -or
                                $_.Replace("\", "/") -like "*$leaf*"
                            }
                    )

                    if ($referencing.Count -eq 0) {
                        Add-Finding -Severity "WARN" -GrantId $grant.Id `
                            -Message "declared entrypoint '$($grant.Entrypoint)' is named by no granted command prefix, so the two may have drifted apart."
                    }
                    else {
                        Write-Host "  ok    entrypoint '$($grant.Entrypoint)' exists and is referenced"
                    }
                }
            }
        }

        "mcp" {
            # An MCP grant has no operating-system counterpart to compare
            # against: whether the server is reachable depends on the client's
            # MCP configuration rather than on this machine's PATH or mounts.
            foreach ($tool in $grant.Tools) {
                Write-Host "  note  MCP tool '$tool' is granted; reachability depends on the client's MCP configuration"
            }
        }

        "path" {
            foreach ($path in $grant.Paths) {

                if (-not (Test-Path $path)) {
                    Add-Finding -Severity "WARN" -GrantId $grant.Id `
                        -Message "'$path' is granted but is not currently reachable."
                    continue
                }

                $writable = Test-PathIsWritable -Path $path

                if ($grant.Access -eq "write" -and -not $writable) {
                    Add-Finding -Severity "ERROR" -GrantId $grant.Id `
                        -Message "'$path' is granted write access but is not writable. Agents will fail when they attempt to use it."
                }
                elseif ($grant.Access -eq "read" -and $writable) {
                    Add-Finding -Severity "ERROR" -GrantId $grant.Id `
                        -Message "'$path' is declared read-only but IS writable by this user. The declaration is not enforced. Mount it read-only, or restrict the access-control list, so the guarantee holds for every tool."
                }
                else {
                    Write-Host "  ok    path '$path' matches its declared '$($grant.Access)' access"
                }
            }
        }

        default {
            # Both emitters throw on an unrecognized kind. This switch used to
            # skip one silently, which would have reported a clean verification
            # of a grant nobody had checked.
            Add-Finding -Severity "ERROR" -GrantId $grant.Id `
                -Message "grant kind '$($grant.Kind)' is not understood by the verifier, so this grant was not checked against the operating system."
        }
    }
}

Write-Host ""

if ($findings.Count -eq 0) {
    Write-Host "All declared capabilities match the operating system."
    Write-Host ""
    exit 0
}

foreach ($finding in ($findings | Sort-Object Severity)) {
    Write-Host "  $($finding.Severity)  [$($finding.GrantId)] $($finding.Message)"
}

Write-Host ""

$errorCount = @($findings | Where-Object { $_.Severity -eq "ERROR" }).Count

Write-Host "$($findings.Count) finding(s); $errorCount at ERROR severity."
Write-Host ""

if ($Strict -and $findings.Count -gt 0) {
    exit 1
}

exit 0
