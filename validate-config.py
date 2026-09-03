#!/usr/bin/env python3
"""Validates install.config.json against install.dependencies.json and
packages.json. Run by setup-mac.sh before it changes anything; exits non-zero
with CONFIG ERROR lines on stderr when the configuration is unsupported.

Usage: validate-config.py <install.config.json> <install.dependencies.json> \
           <packages.json> <platform>
"""
import json
import os
import shutil
import sys


def main():
    config_path, deps_path, packages_path, platform = sys.argv[1:5]

    config = {}
    if os.path.exists(config_path):
        try:
            with open(config_path) as f:
                config = json.load(f)
        except ValueError as e:
            print(f"CONFIG ERROR: {config_path} is not valid JSON: {e}",
                  file=sys.stderr)
            return 1
    with open(deps_path) as f:
        deps = json.load(f)
    with open(packages_path) as f:
        packages_json = json.load(f)

    components = config.get("components", {})
    excluded = set(config.get("packages", {}).get("exclude", []))
    known_components = set(deps["known_components"])
    platform_deps = deps.get(platform, {})
    checks = platform_deps.get("package_checks", {})

    def enabled(name):
        return bool(components.get(name, True))

    known_packages = set()
    for p in packages_json.get("packages", []):
        known_packages.add(p if isinstance(p, str) else p["name"])
    known_packages.update(packages_json.get("admin_packages", []))
    extras = packages_json.get("mac_extras", {})
    known_packages.update(extras.get("formulae", []))
    known_packages.update(extras.get("casks", []))

    problems = []

    # Reject typos: unknown component names in the config
    for name in components:
        if name not in known_components:
            problems.append(
                f"Unknown component '{name}' in install.config.json. "
                f"Known components: {', '.join(sorted(known_components))}")

    # Reject typos: excluded names that match nothing in packages.json
    for pkg in sorted(excluded):
        if pkg not in known_packages:
            problems.append(
                f"Unknown package '{pkg}' in packages.exclude; "
                f"names must match packages.json entries")

    # A required package is satisfied when it will be installed, or is present
    def package_available(pkg):
        if enabled("packages") and pkg not in excluded and pkg in known_packages:
            return True
        check = checks.get(pkg, {})
        if "command" in check:
            return shutil.which(check["command"]) is not None
        if "file" in check:
            return os.path.exists(check["file"])
        return False

    for comp, required in platform_deps.get("components", {}).items():
        if not enabled(comp):
            continue
        for required_comp in required.get("components", []):
            if not enabled(required_comp):
                problems.append(
                    f"Component '{comp}' requires component '{required_comp}',"
                    f" which is disabled in install.config.json")
        for pkg in required.get("packages", []):
            if package_available(pkg):
                continue
            if pkg in excluded:
                why = f"'{pkg}' is in packages.exclude"
            elif not enabled("packages"):
                why = "the 'packages' component is disabled"
            else:
                why = f"'{pkg}' is not available"
            problems.append(
                f"Component '{comp}' requires package '{pkg}', but {why} and "
                f"it was not found on this system. Remove the exclusion, "
                f"install it manually, or disable '{comp}'.")

    for problem in problems:
        print(f"CONFIG ERROR: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
