param(
	[switch]$AdminOnly
)

$ErrorActionPreference = 'Stop'

$goupVersion = "1.7.0"
$goVersion = "1.26.0"
$ompTheme = "multiverse-neon"

# The location of this config depot
$DepotURL = "git@github.com:mendsley/config"

# Install configuration: selects which components and packages to install.
# A missing file or missing key means "install everything". A user may keep a
# personal install.config.local.json (untracked, gitignored) next to the
# tracked file; when present it is used instead, so personal preferences never
# touch tracked files.
$installConfig = $null
$installConfigPath = "$PSScriptRoot\install.config.json"
$localConfigPath = "$PSScriptRoot\install.config.local.json"
if (Test-Path -Path $localConfigPath) {
	Write-Host "Using local install configuration override: $localConfigPath"
	$installConfigPath = $localConfigPath
}
if (Test-Path -Path $installConfigPath) {
	try {
		$installConfig = Get-Content -Path $installConfigPath -Raw | ConvertFrom-Json
	} catch {
		Write-Error "install.config.json is not valid JSON: $($_.Exception.Message)"
	}
} else {
	Write-Warning "install.config.json not found; installing all components and packages"
}

function Test-Component {
	param([string]$Name)
	if ($null -eq $installConfig -or $null -eq $installConfig.components) {
		return $true
	}
	$prop = $installConfig.components.PSObject.Properties[$Name]
	if ($null -eq $prop) {
		return $true
	}
	return [bool]$prop.Value
}

$excludedPackages = @()
if ($installConfig -and $installConfig.packages -and $installConfig.packages.exclude) {
	$excludedPackages = @($installConfig.packages.exclude)
}

# Reject an unsupported configuration before anything is changed, so the
# install never fails (or produces a broken shell) partway through.
. "$PSScriptRoot\validate-config.ps1"
$configProblems = Get-InstallConfigurationErrors `
	-InstallConfig $installConfig `
	-DependenciesPath "$PSScriptRoot\install.dependencies.json" `
	-PackagesPath "$PSScriptRoot\packages.json" `
	-Platform 'windows'
if ($configProblems.Count -gt 0) {
	foreach ($problem in $configProblems) {
		Write-Host "CONFIG ERROR: $problem" -ForegroundColor Red
	}
	Write-Error "install.config.json is not a supported configuration; nothing was installed."
}

# Computes new profile content: replaces the existing managed block when the
# markers are present, otherwise appends one. Everything outside the markers
# is preserved, so personal profile customizations survive re-runs.
function Update-ProfileManagedBlock {
	param(
		[string[]]$ExistingLines,
		[string[]]$ManagedLines,
		[string]$BeginMarker,
		[string]$EndMarker
	)

	$existing = @($ExistingLines)
	$beginIndex = [array]::IndexOf($existing, $BeginMarker)
	$endIndex = [array]::IndexOf($existing, $EndMarker)

	if ($beginIndex -ge 0 -and $endIndex -ge $beginIndex) {
		$before = @()
		if ($beginIndex -gt 0) { $before = $existing[0..($beginIndex - 1)] }
		$after = @()
		if ($endIndex -lt ($existing.Count - 1)) { $after = $existing[($endIndex + 1)..($existing.Count - 1)] }
		return @($before) + @($ManagedLines) + @($after)
	}

	# No markers: a fresh profile, or one written by the old replace-style
	# setup. Drop exact copies of lines the managed block re-adds; keep
	# everything else.
	$generated = @($ManagedLines | Where-Object { $_ -ne '' -and $_ -ne $BeginMarker -and $_ -ne $EndMarker })
	$kept = @($existing | Where-Object { $generated -notcontains $_ })
	if ($kept.Count -gt 0) { $kept += '' }
	return @($kept) + @($ManagedLines)
}

# Check if we're running as administrator
function Test-Administrator {
	$currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
	$principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
	$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Scoop's root directory, matching the resolution order used by get.scoop.sh
# and scoop itself: $env:SCOOP, then root_path from scoop's config file, then
# the default under the user profile.
function Get-ScoopDir {
	if ($env:SCOOP) {
		return $env:SCOOP
	}
	$scoopConfigPath = "$env:USERPROFILE\.config\scoop\config.json"
	if (Test-Path -Path $scoopConfigPath) {
		try {
			$rootPath = (Get-Content -Path $scoopConfigPath -Raw | ConvertFrom-Json).root_path
			if ($rootPath) {
				return $rootPath
			}
		} catch {
			# Unreadable config: fall through to the default root.
		}
	}
	return "$env:USERPROFILE\scoop"
}

# The global app root used by `scoop install --global`, matching scoop's own
# resolution order: $env:SCOOP_GLOBAL, then global_path from scoop's config
# file, then the default under ProgramData.
function Get-ScoopGlobalDir {
	if ($env:SCOOP_GLOBAL) {
		return $env:SCOOP_GLOBAL
	}
	$scoopConfigPath = "$env:USERPROFILE\.config\scoop\config.json"
	if (Test-Path -Path $scoopConfigPath) {
		try {
			$globalPath = (Get-Content -Path $scoopConfigPath -Raw | ConvertFrom-Json).global_path
			if ($globalPath) {
				return $globalPath
			}
		} catch {
			# Unreadable config: fall through to the default root.
		}
	}
	return "$env:ProgramData\scoop"
}

# Moves a directory, elevating for just the move when this process lacks the
# rights (the global scoop root under ProgramData is typically admin-owned).
function Move-ItemMaybeElevated {
	param(
		[string]$Path,
		[string]$Destination
	)
	try {
		Move-Item -LiteralPath $Path -Destination $Destination
		return
	} catch {
		if (Test-Administrator) {
			# Already elevated, so retrying elevated cannot help.
			throw
		}
		Write-Host "Elevating to move $Path"
	}
	$moveCommand = "try { Move-Item -LiteralPath '$Path' -Destination '$Destination' -ErrorAction Stop; exit 0 } catch { exit 1 }"
	$moveProcess = Start-Process -Wait -PassThru -Verb RunAs powershell.exe `
		-ArgumentList '-NoProfile', '-Command', $moveCommand
	if ($moveProcess.ExitCode -ne 0) {
		throw "Failed to move $Path to $Destination (exit code $($moveProcess.ExitCode))"
	}
}

# True only when the scoop command resolves and actually runs. This treats a
# missing install, a shims directory that fell off PATH, and a root directory
# left broken by a failed install/uninstall all the same way: not usable.
function Test-ScoopHealthy {
	if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
		return $false
	}
	try {
		& scoop help *> $null
		return $?
	} catch {
		return $false
	}
}

function Install-Scoop {
	$scoopDir = Get-ScoopDir
	$scoopShims = Join-Path $scoopDir 'shims'

	if (Test-ScoopHealthy) {
		Write-Host "scoop already installed"
		return
	}

	# An existing install may only be missing from PATH (the user PATH entry
	# was lost, or this session predates the install). Restore it and retest
	# before doing anything more invasive.
	if (Test-Path -Path (Join-Path $scoopShims 'scoop.ps1')) {
		Write-Host "Found existing scoop at $scoopDir; restoring its PATH entry"
		$env:PATH = "$scoopShims;$env:PATH"
		$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
		if (@($userPath -split ';') -notcontains $scoopShims) {
			[Environment]::SetEnvironmentVariable('PATH', "$userPath;$scoopShims", 'User')
		}
		if (Test-ScoopHealthy) {
			return
		}
	}

	# Whatever is left at the root now is a broken install (e.g. a failed
	# uninstall). The installer refuses to run over a non-empty directory, so
	# move it aside (never delete it) to allow a clean reinstall.
	if (Test-Path -Path $scoopDir) {
		$backupDir = "$scoopDir.broken-$(Get-Date -Format yyyyMMdd-HHmmss)"
		Write-Warning "scoop at $scoopDir is not functional; moving it to $backupDir and reinstalling"
		try {
			Move-Item -Path $scoopDir -Destination $backupDir
		} catch {
			Write-Error ("Could not move the broken scoop directory aside: $($_.Exception.Message). " +
				"Close any programs running from $scoopDir (or remove it manually) and re-run this script.")
		}
	}

	# The installer also refuses to run while the *global* app root (used by
	# `scoop install --global`, e.g. C:\ProgramData\scoop) is non-empty, even
	# though that directory is normally healthy data left from a previous
	# install. Pointing the installer at a different -ScoopGlobalDir is no
	# better: it would persist that path as global_path in scoop's config.
	# So move the directory aside for the duration of the install and restore
	# it afterwards; the globally installed apps come back untouched.
	$scoopGlobalDir = Get-ScoopGlobalDir
	$globalStashDir = $null
	if ((Test-Path -Path $scoopGlobalDir) -and (Test-Path -Path "$scoopGlobalDir\*")) {
		$globalStashDir = "$scoopGlobalDir.reinstall-$(Get-Date -Format yyyyMMdd-HHmmss)"
		Write-Host "Temporarily moving $scoopGlobalDir to $globalStashDir so the scoop installer will run"
		try {
			Move-ItemMaybeElevated -Path $scoopGlobalDir -Destination $globalStashDir
		} catch {
			Write-Error ("Could not move the global scoop directory aside: $($_.Exception.Message). " +
				"The scoop installer refuses to run while $scoopGlobalDir is non-empty; " +
				"move or remove it and re-run this script.")
		}
	}

	# Run the installer as a script file in a child process. Piping it into
	# Invoke-Expression lets its abort path run a bare `break`, which would
	# silently terminate this entire script; a file invocation aborts with a
	# real exit code instead, and the child process contains it either way.
	Write-Host "Installing scoop..."
	$installerPath = Join-Path $env:TEMP "scoop-installer-$PID.ps1"
	Invoke-RestMethod -Uri 'https://get.scoop.sh' -OutFile $installerPath
	try {
		$installerArgs = @()
		if (Test-Administrator) {
			# The installer refuses to run elevated unless told otherwise;
			# support this script being launched from an admin shell.
			$installerArgs += '-RunAsAdmin'
		}
		& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installerPath @installerArgs
		if ($LASTEXITCODE -ne 0) {
			Write-Error "The scoop installer failed with exit code $LASTEXITCODE"
		}
	} finally {
		Remove-Item -Path $installerPath -ErrorAction SilentlyContinue

		# Put the global app root back, whether or not the install succeeded.
		if ($globalStashDir -and (Test-Path -Path $globalStashDir)) {
			if (Test-Path -Path "$scoopGlobalDir\*") {
				Write-Warning ("The scoop installer recreated $scoopGlobalDir; your previous global " +
					"apps were left at $globalStashDir - merge them back manually.")
			} else {
				try {
					if (Test-Path -Path $scoopGlobalDir) {
						# Remove the empty recreated directory; moving onto an
						# existing directory would nest the stash inside it.
						Remove-Item -LiteralPath $scoopGlobalDir
					}
					Move-ItemMaybeElevated -Path $globalStashDir -Destination $scoopGlobalDir
				} catch {
					Write-Warning ("Could not restore the global scoop directory: $($_.Exception.Message). " +
						"Your global apps are intact at $globalStashDir - move it back to $scoopGlobalDir manually.")
				}
			}
		}
	}

	# The installer adds shims to the user PATH; expose them to this session
	# so the scoop calls below (and `scoop which bash` later) resolve.
	if (@($env:PATH -split ';') -notcontains $scoopShims) {
		$env:PATH = "$scoopShims;$env:PATH"
	}

	if (-not (Test-ScoopHealthy)) {
		Write-Error "scoop is still not usable after installing it; aborting before package installs."
	}
}

# Adds a bucket only when it is missing, so re-runs and pre-existing scoop
# installs don't fail on 'bucket already exists'.
function Add-ScoopBucket {
	param(
		[string]$Name,
		[string]$Repo
	)
	if (Test-Path -Path (Join-Path (Get-ScoopDir) "buckets\$Name")) {
		Write-Host "scoop bucket '$Name' already added"
		return
	}
	if ($Repo) {
		scoop bucket add $Name $Repo
	} else {
		scoop bucket add $Name
	}
	if (!$?) {
		Write-Warning "Failed to add scoop bucket $Name"
	}
}

# Run administrator tasks first
if (-not (Test-Administrator)) {
	Write-Host "Elevating to run admin commands..."
	$adminScript = "-File $($PSCommandPath) -AdminOnly"
	Start-Process -Wait -Verb RunAs powershell.exe -ArgumentList $adminScript
}

# Install vs code early
if (Test-Component 'vscode') {
	winget install -e --id Microsoft.VisualStudioCode
}

if ($AdminOnly) {
	if (Test-Component 'developer_mode') {
		# Switch local machine policy
		Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope LocalMachine

		# Enable developer mode
		$devModePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock"
		if (-not (Test-Path -Path $devModePath)) {
			New-Item -Path $devModePath -Force | Out-Null
		}
		Set-ItemProperty `
			-Path $devModePath `
			-Name AllowDevelopmentWithoutDevLicense `
			-Value 1 `
			-Type DWord `
			;
	}

	# Configure neovim
	if (Test-Component 'nvim') {
		if (Test-Path -Path "$env:LOCALAPPDATA\nvim") {
			Remove-Item -Force -Recurse -Path "$env:LOCALAPPDATA\nvim"
		}
		New-Item -ItemType 'SymbolicLink' `
			-Path "$env:LOCALAPPDATA\nvim" `
			-Target "$PSScriptRoot\nvim" `
			| Out-Null
	}

	# Git configuration
	if (Test-Component 'git') {
		Remove-Item -ErrorAction SilentlyContinue -Path "$env:USERPROFILE\.gitconfig" -Force
		Remove-Item -ErrorAction SilentlyContinue -Path "$env:USERPROFILE\.gitconfig-windows" -Force
		New-Item -ItemType 'SymbolicLink' `
			-Path "$env:USERPROFILE\.gitconfig" `
			-Target "$PSScriptRoot\.gitconfig" `
			| Out-Null
		New-Item -ItemType 'SymbolicLink' `
			-Path "$env:USERPROFILE\.gitconfig-windows" `
			-Target "$PSScriptRoot\.gitconfig-windows" `
			| Out-Null
	}

	# Claude Code statusline
	if (Test-Component 'claude') {
		New-Item -ItemType Directory -Path "$env:USERPROFILE\.claude" -Force | Out-Null
		Remove-Item -ErrorAction SilentlyContinue -Path "$env:USERPROFILE\.claude\statusline.py" -Force
		New-Item -ItemType 'SymbolicLink' `
			-Path "$env:USERPROFILE\.claude\statusline.py" `
			-Target "$PSScriptRoot\claude\statusline.py" `
			| Out-Null
	}

	# SSH configuration
	if (Test-Component 'ssh') {
		New-Item -Path "$env:USERPROFILE\.ssh" -ItemType 'Directory' -Force | Out-Null
		Remove-Item -ErrorAction SilentlyContinue -Path "$env:USERPROFILE\.ssh\config" -Force
		New-Item -ItemType 'SymbolicLink' `
			-Path "$env:USERPROFILE\.ssh\config" `
			-Target "$PSScriptRoot\ssh_config" | Out-Null
	}

	# GPG configuration
	if (Test-Component 'gpg') {
		New-Item -ItemType 'Directory' -Path "$env:APPDATA\gnupg" -Force | Out-Null
		$gpgAgentConf = @"
enable-win32-openssh-support
allow-loopback-pinentry
default-cache-ttl 86400
default-cache-ttl-ssh 86400
"@
		Set-Content `
			-Path "$env:APPDATA\gnupg\gpg-agent.conf" `
			-Value $gpgAgentConf `
			-Encoding utf8 `
			-NoNewLine `
			;
		$gpgConf = @"
use-agent
pinentry-mode loopback
"@
		Set-Content `
			-Path "$env:APPDATA\gnupg\gpg.conf" `
			-Value $gpgConf `
			-Encoding utf8 `
			-NoNewLine `
			;

		# GPG agent startup
		$gpgTaskConfig = @{
			TaskName = 'Start GPG Agent'
		Action = New-ScheduledTaskAction -Execute (Get-Command gpg-connect-agent).Source -Argument '/bye';
			Trigger = New-ScheduledTaskTrigger -AtLogOn;
			Principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited;
		}
		$existingTask =  Get-ScheduledTask -TaskName $gpgTaskConfig.TaskName -ErrorAction SilentlyContinue
		if ($null -eq $existingTask) {
			Register-ScheduledTask -TaskName $gpgTaskConfig.TaskName `
				-Action $gpgTaskConfig.Action `
				-Trigger $gpgTaskConfig.Trigger `
				-Principal $gpgTaskConfig.Principal | Out-Null
			Write-Host "Created gpg-connect-agent task"
		} else {
			Set-ScheduledTask -TaskName $gpgTaskConfig.TaskName `
				-Action $gpgTaskConfig.Action `
				-Trigger $gpgTaskConfig.Trigger `
				-Principal $gpgTaskConfig.Principal | Out-Null

			Write-Host "Updated gpg-connect-agent task"
		}
	}

	exit 0
}

# Git identity and signing preference are user-specific, so they are prompted
# for once and written to ~/.gitconfig-user (included by .gitconfig) instead of
# living in the tracked .gitconfig. Re-running the script never re-prompts;
# delete ~/.gitconfig-user to be asked again.
if (Test-Component 'git') {
	$gitUserConfigPath = "$env:USERPROFILE\.gitconfig-user"
	if (Test-Path -Path $gitUserConfigPath) {
		Write-Host "Git identity already configured in $gitUserConfigPath"
	} else {
		Write-Host "Configuring Git identity (written to $gitUserConfigPath)"
		$gitUserName = ''
		while (-not $gitUserName) {
			$gitUserName = Read-Host "Git user.name (e.g. your full name)"
		}
		$gitUserEmail = ''
		while (-not $gitUserEmail) {
			$gitUserEmail = Read-Host "Git user.email"
		}
		$signAnswer = Read-Host "Sign commits with GPG? Requires a configured GPG key. [y/N]"
		$gpgSign = if ($signAnswer -match '^[yY]') { 'true' } else { 'false' }

		$gitUserConfig = @"
# Generated by setup-win.ps1. Edit freely; delete to be prompted again.
[user]
	name = $gitUserName
	email = $gitUserEmail
[commit]
	gpgsign = $gpgSign
"@
		Set-Content -Path $gitUserConfigPath -Value $gitUserConfig -Encoding utf8
	}
}

if (Test-Component 'vscode') {
	[System.Environment]::SetEnvironmentVariable('EDITOR', 'code', [System.EnvironmentVariableTarget]::User)
} else {
	[System.Environment]::SetEnvironmentVariable('EDITOR', 'nvim', [System.EnvironmentVariableTarget]::User)
}

if (Test-Component 'packages') {
	# Install (or repair) scoop; see Install-Scoop above.
	Install-Scoop

	$packagesJson = Get-Content -Path "$PSScriptRoot\packages.json" -Raw | ConvertFrom-Json
	foreach ($bucket in $packagesJson.buckets) {
		Add-ScoopBucket -Name $bucket
	}

	# Add dicklesworthstone bucket
	Add-ScoopBucket -Name dicklesworthstone -Repo https://github.com/Dicklesworthstone/scoop-bucket
	Add-ScoopBucket -Name mendsley -Repo https://github.com/mendsley/scoop-bucket

	foreach ($package in $packagesJson.packages) {
		$name = if ($package -is [string]) { $package } else { $package.name }
		if ($excludedPackages -contains $name) {
			Write-Host "Skipping excluded package $name"
			continue
		}
		scoop install $name
		if (!$?) {
			Write-Warning "Failed to install $name"
		}
	}

	foreach ($package in $packagesJson.admin_packages) {
		if ($excludedPackages -contains $package) {
			Write-Host "Skipping excluded package $package"
			continue
		}
		gsudo scoop install --global $package
	}
}

# GPG configuration
if (Test-Component 'gpg') {
	New-Item -Path "$env:USERPROFILE\.gnupg" -ItemType Directory -Force | Out-Null
}

# Setup goup (Go version manager)
if ((Test-Component 'go') -and -not (Get-Command goup -ErrorAction SilentlyContinue)) {
	Write-Host "Installing goup..."
	$goupUrl = "https://github.com/zekroTJA/goup/releases/download/v$goupVersion/goup-v1.7.0-x86_64-pc-windows-msvc.exe"
	$goupDir = "$env:USERPROFILE\.local\bin"
	$groupPath = "$goupDir\goup.exe"

	New-Item -ItemType Directory -Path $goupDir -Force | Out-Null
	Invoke-WebRequest -Uri $goupUrl -OutFile $groupPath

	# add to PATH
	$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
	if ($currentPath -notlike "*$goupDir*") {
		[Environment]::SetEnvironmentVariable("PATH", "$currentPath;$goupDir", "User")
	}
	$env:PATH += ";$goupDir"

	# add go paths
	$env:GOROOT = "$env:USERPROFILE\.local\goup\current\go"
	[Environment]::SetEnvironmentVariable("GOROOT", $env:GOROOT, "User")

	$goupGoPath = "$($env:GOROOT)\bin"
	$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
	if ($currentPath -notlike "*$goupGoPath*") {
		[Environment]::SetEnvironmentVariable("PATH", "$currentPath;$goupGoPath", "User")
	}
	$env:PATH += ";goupGoPath"
}

if (Test-Component 'go') {
	# Install go
	goup use $goVersion
	if (!$?) {
		Write-Error "Failed to install go $goVersion"
	}

	# Add GOPATH\bin to PATH if not already present
	$goPath = & go env GOPATH
	if ($goPath) {
		$goPathBin = Join-Path $goPath "bin"
		$currentPath = [Environment]::GetEnvironmentVariable("PATH", "User")
		if ($currentPath -notlike "*$goPathBin*") {
			Write-Host "Adding $goPathBin to PATH..."
			[Environment]::SetEnvironmentVariable("PATH", "$currentPath;$goPathBin", "User")
			$env:PATH += ";$goPathBin"
		} else {
			Write-Host "GOPATH\bin already in PATH"
		}
	}
}

# Setup windows terminal to use pwsh
$wtSettingsPath = "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json"
if ((Test-Component 'terminal') -and (Test-Path -Path $wtSettingsPath)) {

	$settings = Get-Content -Path $wtSettingsPath -Raw -Encoding UTF8 `
		| ConvertFrom-Json `
		;

	$settings.defaultProfile = "{574e775e-4f2a-5b96-ac1e-a2962a402336}"

	$profiles = [ordered]@{
		defaults = [ordered]@{
			cursorShape = "bar"
			"experimental.retroTerminalEffect" = $false
			font = @{
				face = "MesloLGM Nerd Font"
				size = 10
			}
		}
		list = $settings.profiles.list
	}

	Add-Member `
		-Force `
		-InputObject $settings`
		-MemberType NoteProperty `
		-Name "profiles" `
		-Value $profiles `
		;

	$settings `
		| ConvertTo-Json -Depth 10 `
		| Set-Content -Path $wtSettingsPath -Encoding UTF8 `
		;
}

# Setup oh-my-posh/posh-git
if (Test-Component 'shell') {
	pwsh -Command 'oh-my-posh font install meslo'

	pwsh -Command 'Install-Module posh-git -Scope CurrentUser -Force -Confirm:$false -AllowClobber'
	pwsh -Command 'Install-Module PSFzf -Scope CurrentUser -Force -Confirm:$false -AllowClobber'

	$profilePath =  pwsh -Command 'Write-Host $PROFILE.CurrentUserCurrentHost'
	$profileDir = Split-Path -Path $profilePath -Parent

	if (-not (Test-Path $profileDir)) {
		New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
	}

	# The profile is amended, not replaced: only the block between these
	# markers belongs to this script, and content outside them is preserved.
	$managedBegin = '# >>> managed by config repo setup-win.ps1 >>>'
	$managedEnd = '# <<< managed by config repo setup-win.ps1 <<<'
	$managedLines = @(
		$managedBegin,
		'# This block is rewritten by setup-win.ps1 on every run.',
		'# Put personal customizations outside the markers.',
		'oh-my-posh init pwsh --config "$env:POSH_THEMES_PATH\multiverse-neon.omp.json" | Invoke-Expression',
		'Import-Module posh-git',
		'',
		'# fzf integration',
		'Import-Module PSFzf',
		"Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'"
	)

	# Aliasing ls/cat over to eza/bat is its own component: the tools install
	# with the package set either way, but only replace the classic commands
	# when cli_aliases is enabled.
	if (Test-Component 'cli_aliases') {
		$managedLines += @(
			'',
			'# eza aliases',
			'Remove-Alias ls -Force -ErrorAction SilentlyContinue',
			'Set-Alias -Name ls -Value eza',
			'function ll { eza -l @args }',
			'function la { eza -la @args }',
			'function tree { eza --tree @args }',
			'',
			'# bat alias',
			'Remove-Alias cat -Force -ErrorAction SilentlyContinue',
			'function cat { bat --plain @args }'
		)
	}

	$managedLines += $managedEnd

	$profileLines = @()
	if (Test-Path -Path $profilePath) {
		$profileLines = @(Get-Content -Path $profilePath)
	}

	$newProfileLines = Update-ProfileManagedBlock `
		-ExistingLines $profileLines `
		-ManagedLines $managedLines `
		-BeginMarker $managedBegin `
		-EndMarker $managedEnd

	Set-Content -Path $profilePath -Value $newProfileLines -Encoding UTF8
}

# install corepack
if (Test-Component 'node') {
	npm install -g corepack
	"y" | corepack enable
}

# Go tools
if (Test-Component 'go') {
	go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest
	go install honnef.co/go/tools/cmd/staticcheck@latest
}

if (Test-Component 'claude') {
	# Install claude
	if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
		Write-Host "Installing Claude Code..."
		$bashCommand = (scoop which bash | Resolve-Path).Path
		[System.Environment]::SetEnvironmentVariable('CLAUDE_CODE_GIT_BASH_PATH', $bashCommand, 'User')
		$env:SHELL = $bashCommand
		$env:CLAUDE_CODE_GIT_BASH_PATH = $bashCommand
		irm https://claude.ai/install.ps1 | iex
	} else {
		Write-Host "Claude Code already installed"
	}

	# Claude Code settings
	$claudeSettingsPath = "$env:USERPROFILE\.claude\settings.json"
	$statuslinePath = "$env:USERPROFILE\.claude\statusline.py" -replace '\\', '/'
	$claudeSettings = @{}
	if (Test-Path $claudeSettingsPath) {
		$claudeSettings = Get-Content -Path $claudeSettingsPath -Raw | ConvertFrom-Json -AsHashtable
	}
	$claudeSettings['statusLine'] = @{
		type = 'command'
		command = "python $statuslinePath"
	}
	$claudeSettings | ConvertTo-Json -Depth 10 | Set-Content -Path $claudeSettingsPath -Encoding UTF8
}

# Replace origin with SSH remote (if needed)
if (Test-Component 'repo_remote') {
	$originUrl = git remote get-url origin 2>$null
	if ($originUrl -ne $DepotURL) {
		git remote rm origin
		git remote add origin $DepotURL
	}
}

if (Test-Component 'git_tools_cleanup') {
	$gitVimPath = "$env:GIT_INSTALL_ROOT\usr\bin\vim.exe"
	if (Test-Path -Path $gitVimPath) {
		Remove-Item -Force -Path $gitVimPath
	}

	$gitGpgPath = "$env:GIT_INSTALL_ROOT\usr\bin\gpg.exe"
	if (Test-Path -Path $gitGpgPath) {
		Remove-Item -Force -Path $gitGpgPath
	}
}
