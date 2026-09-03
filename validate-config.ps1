# Validates install.config.json against install.dependencies.json and
# packages.json. Dot-sourced by setup-win.ps1 and directly testable.
# Returns a list of problem descriptions; an empty list means the
# configuration is supported.

function Get-InstallConfigurationErrors {
	param(
		$InstallConfig,
		[string]$DependenciesPath,
		[string]$PackagesPath,
		[string]$Platform
	)

	$problems = @()
	$deps = Get-Content -Path $DependenciesPath -Raw | ConvertFrom-Json
	$packagesJson = Get-Content -Path $PackagesPath -Raw | ConvertFrom-Json

	$knownComponents = @($deps.known_components)
	$platformDeps = $deps.$Platform

	function Test-EnabledComponent([string]$Name) {
		if ($null -eq $InstallConfig -or $null -eq $InstallConfig.components) {
			return $true
		}
		$prop = $InstallConfig.components.PSObject.Properties[$Name]
		if ($null -eq $prop) {
			return $true
		}
		return [bool]$prop.Value
	}

	$excluded = @()
	if ($InstallConfig -and $InstallConfig.packages -and $InstallConfig.packages.exclude) {
		$excluded = @($InstallConfig.packages.exclude)
	}

	# Reject typos: unknown component names in the config
	if ($InstallConfig -and $InstallConfig.components) {
		foreach ($prop in $InstallConfig.components.PSObject.Properties) {
			if ($knownComponents -notcontains $prop.Name) {
				$problems += "Unknown component '$($prop.Name)' in install.config.json. Known components: $($knownComponents -join ', ')"
			}
		}
	}

	# Reject typos: excluded names that match nothing in packages.json
	$knownPackages = @()
	foreach ($p in $packagesJson.packages) {
		$knownPackages += if ($p -is [string]) { $p } else { $p.name }
	}
	$knownPackages += @($packagesJson.admin_packages)
	if ($packagesJson.mac_extras) {
		$knownPackages += @($packagesJson.mac_extras.formulae)
		$knownPackages += @($packagesJson.mac_extras.casks)
	}
	foreach ($pkg in $excluded) {
		if ($knownPackages -notcontains $pkg) {
			$problems += "Unknown package '$pkg' in packages.exclude; names must match packages.json entries"
		}
	}

	# A required package is satisfied when it will be installed, or is present
	function Test-PackageAvailable([string]$Package) {
		if ((Test-EnabledComponent 'packages') -and
			($excluded -notcontains $Package) -and
			($knownPackages -contains $Package)) {
			return $true
		}
		$check = $platformDeps.package_checks.PSObject.Properties[$Package]
		if ($null -eq $check) {
			return $false
		}
		if ($check.Value.command) {
			return $null -ne (Get-Command $check.Value.command -ErrorAction SilentlyContinue)
		}
		if ($check.Value.file) {
			return Test-Path -Path $check.Value.file
		}
		return $false
	}

	foreach ($compProp in $platformDeps.components.PSObject.Properties) {
		$comp = $compProp.Name
		if (-not (Test-EnabledComponent $comp)) {
			continue
		}
		foreach ($requiredComp in @($compProp.Value.components)) {
			if ($requiredComp -and -not (Test-EnabledComponent $requiredComp)) {
				$problems += "Component '$comp' requires component '$requiredComp', which is disabled in install.config.json"
			}
		}
		foreach ($pkg in @($compProp.Value.packages)) {
			if ($pkg -and -not (Test-PackageAvailable $pkg)) {
				$why = if ($excluded -contains $pkg) {
					"'$pkg' is in packages.exclude"
				} elseif (-not (Test-EnabledComponent 'packages')) {
					"the 'packages' component is disabled"
				} else {
					"'$pkg' is not available"
				}
				$problems += "Component '$comp' requires package '$pkg', but $why and it was not found on this system. Remove the exclusion, install it manually, or disable '$comp'."
			}
		}
	}

	return ,$problems
}
