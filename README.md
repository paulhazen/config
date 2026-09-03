# config

Personal development-machine configuration: dotfiles plus bootstrap scripts for
Windows, macOS, and Linux.

> **Provenance note:** this repository was cloned from a coworker's config
> setup. Several values, package choices, and workflow assumptions are specific
> to the original author's environment. Read
> [Values to change for your environment](#values-to-change-for-your-environment)
> before running any setup script — the scripts are **destructive by design**
> (they delete and replace existing dotfiles, rewrite your Windows Terminal
> settings, manage a block of your PowerShell profile, and re-point this
> repo's `origin` remote).

## Repository layout

| Path | Purpose | Installed by |
|---|---|---|
| `setup-win.ps1` | Windows bootstrap (scoop, Go, symlinks, GPG, terminal, Claude Code) | run directly |
| `setup-mac.sh` | macOS bootstrap (Homebrew, oh-my-zsh, goenv, symlinks, GPG) | run directly |
| `setup.sh` | Linux bootstrap (vim, i3, fonts, GPG) — **stale, see below** | run directly |
| `packages.json` | Shared package manifest (scoop names, with `brew`/`brew_cask` mappings and `mac_extras`) | both installers |
| `install.config.json` | Selects which components and packages the installers actually install | read by Windows + macOS installers |
| `.gitconfig` | Core Git config: aliases, LFS (identity/signing live in generated `~/.gitconfig-user`) | Windows admin phase, macOS, Linux |
| `.gitconfig-windows` | Windows-only Git config: OpenSSH command, VS Code diff/merge | Windows admin phase (included from `.gitconfig`) |
| `.gitconfig-mac` | macOS-only Git config: LFS, Beyond Compare diff/merge | macOS (included from `.gitconfig`) |
| `ssh_config` | Becomes your entire `~/.ssh/config` | all three |
| `.zshrc` | zsh config: oh-my-zsh, GPG-agent-as-SSH-agent, eza/bat aliases, goenv | macOS only |
| `nvim/init.lua` | Neovim config: lazy.nvim, NERDTree, LSP (gopls, clangd), kanagawa theme | Windows admin phase, macOS |
| `claude/statusline.py` | Claude Code status line script (model name + context usage) | Windows |
| `.i3/config`, `.i3status.conf` | i3 window manager config | Linux only |
| `fonts/` | DroidSansMono and UbuntuMono TTFs | Linux only |
| `.gemrc`, `.hgrc`, `.editorconfig`, `oh-my-opencode.json` | Ruby gems, Mercurial, editor defaults, opencode Go settings | `.gemrc`: Linux; the rest are not installed by any script |
| `.agentpolicy/`, `AGENTS.md`, `.claude/settings.json` | Centrally managed agent policy for AI coding agents (see `AGENTS.md`) | `./.agentpolicy/sync.ps1` |
| `test.txt` | Empty leftover file; safe to delete | — |

## Choosing what to install

`install.config.json` at the repo root controls what the Windows and macOS
installers do. `components` holds per-feature booleans (a missing key defaults
to `true`, and a missing file installs everything), and `packages.exclude`
lists package names from `packages.json` to skip. Each component is described
in the file's own `_documentation.component_reference`. Edit it before running
an installer — it is the supported way to opt in or out of the package
choices and surprising behaviors listed later in this document.

The committed defaults encode the repo owner's preferences: Windows-centric,
VS Code as editor (Neovim config off), no GPG/commit-signing machinery
(standard OpenSSH agent), Go/Node/Python toolchains (no .NET), oh-my-posh
prompt and fzf keybindings but no eza/bat aliases (`cli_aliases` off), origin
re-pointing and Git-exe cleanup off, and the original author's personal apps
excluded. Delete the file to install absolutely everything.

The installers also prompt for values that are yours rather than the repo's:
Git `user.name`, `user.email`, and whether to GPG-sign commits. Answers are
written once to `~/.gitconfig-user` (included by the symlinked `.gitconfig`,
never tracked by this repo); delete that file to be prompted again.

## What installation does

### Windows — `setup-win.ps1`

The script self-elevates and runs an **admin phase** first (`-AdminOnly`):

1. Sets the machine-wide PowerShell execution policy to `Bypass`.
2. Enables Windows Developer Mode via the registry (required for creating
   symlinks without elevation).
3. **Deletes** any existing `%LOCALAPPDATA%\nvim`, `~/.gitconfig`,
   `~/.gitconfig-windows`, `~/.claude/statusline.py`, and `~/.ssh/config`,
   replacing each with a symlink into this repository.
4. Writes `gpg-agent.conf` / `gpg.conf` under `%APPDATA%\gnupg` (loopback
   pinentry, Win32-OpenSSH support, 24-hour key cache) and registers a
   logon scheduled task that starts `gpg-connect-agent`.

Then the **user phase**:

5. Installs VS Code (winget) and sets the user `EDITOR` env var to `code`.
6. Installs scoop, adds the buckets from `packages.json` **plus two personal
   third-party buckets** (`dicklesworthstone`, `mendsley`), and installs every
   entry in `packages` (and `admin_packages` globally via gsudo).
7. Installs `goup` (pinned version) and Go (pinned version), adds Go paths to
   the user `PATH`, and installs `golangci-lint` and `staticcheck`.
8. **Rewrites Windows Terminal settings**: default profile becomes PowerShell 7
   (`pwsh`), default font becomes "MesloLGM Nerd Font" 10pt, bar cursor.
9. Installs the Meslo Nerd Font, posh-git, and PSFzf, and **amends your pwsh
   profile** (`$PROFILE.CurrentUserCurrentHost`) with a marker-delimited
   managed block: oh-my-posh with the `multiverse-neon` theme, fzf keybindings
   (`Ctrl+t`, `Ctrl+r`), and aliases that replace `ls`/`ll`/`la`/`tree` with
   `eza` and `cat` with `bat`. Content outside the markers is preserved on
   every run; only the managed block is rewritten.
10. Enables corepack (npm), installs Claude Code if missing, and points the
    Claude Code `statusLine` setting at `claude/statusline.py` (invoked with
    `python`, which must be on `PATH`).
11. **Re-points this repository's `origin` remote** at the `$DepotURL` defined
    at the top of the script.
12. **Deletes `vim.exe` and `gpg.exe` from the Git for Windows install** so the
    scoop-installed neovim and gpg4win are always the ones on `PATH`.

### macOS — `setup-mac.sh`

1. Installs Homebrew if missing.
2. Installs every `packages` entry that has a `brew`/`brew_cask` mapping, plus
   everything in `mac_extras` (string-only entries are scoop/Windows-only).
3. Installs oh-my-zsh (keeps existing `.zshrc` during install, but see next
   steps) and goenv, and installs the latest Go if none is present.
4. **Deletes and replaces** `~/.gitconfig`, `~/.gitconfig-mac`,
   `~/.config/nvim`, `~/.ssh/config`, and `~/.zshrc` with symlinks into this
   repository, and runs `git lfs install`.
5. Appends GPG settings under `~/.gnupg`: `use-agent`, `use-keyboxd`,
   `pinentry-mac` as the pinentry program, and `enable-ssh-support` (gpg-agent
   doubles as the SSH agent — see `.zshrc`, which exports `SSH_AUTH_SOCK` from
   `gpgconf`).

### Linux — `setup.sh`

**This script is stale.** It symlinks `vim/.vimrc`, `vim/.gvimrc`, and `vim/`
into `$HOME`, but no `vim/` directory exists in the repository anymore (the
Neovim config replaced it), and it runs `git submodule update --init` although
there are no submodules. Expect it to fail partway. What it attempts:

- vim symlinks (broken), `~/.ssh/config`, `~/.gemrc`, i3 config,
  `~/.gitconfig`
- disables the gnome-keyring SSH component so gpg-agent can own SSH, and
  appends `use-agent` / `enable-ssh-support` to the GPG config
- symlinks the bundled fonts into `~/.fonts` and rebuilds the font cache

Note it does **not** install `.zshrc` (macOS-only) or `.hgrc` (installed by
nothing).

## Values to change for your environment

These are the settings that carry the original author's identity, employer,
hardware, or personal tool choices. Review each before (or immediately after)
running an installer.

### Identity

| File | Setting | Current value | Action |
|---|---|---|---|
| `.gitconfig` | `[user] name` / `email` | prompted at install time | The installers write your answers to `~/.gitconfig-user`; nothing personal remains in the tracked file. Edit `~/.gitconfig-user` to change identity later. |
| `.hgrc` | `[ui] username` | `Matthew Endsley <mendsley@gmail.com>` | The original author's Mercurial identity. Change it or delete the file — no setup script installs it anyway. |
| `setup-win.ps1` | `$DepotURL` (top of script) | `git@github.com:paulhazen/config` | The script force-replaces this repo's `origin` with this URL. Make sure it points at **your** fork before running. |

### Signing, GPG, and SSH-agent workflow

The original author used a **GPG-key-backed workflow** (likely with a
YubiKey). The default configuration now disables all of it (`gpg` component
off, `gpg4win`/`yubioath` excluded) in favor of the standard OpenSSH agent and
unsigned commits; the machinery remains available behind the `gpg` component:

| File | Setting | Why it may not be portable |
|---|---|---|
| `.gitconfig` | `[commit] gpgsign` | Prompted at install time (default: no) and written to `~/.gitconfig-user`. Answer yes only once you have a GPG key configured, or commits fail. |
| `.zshrc` (macOS) | `SSH_AUTH_SOCK` from `gpgconf`, `gpg-connect-agent /bye` | gpg-agent replaces your SSH agent on every shell start. Because of this, `setup-mac.sh` on a Mac without gnupg installed rejects the Windows-oriented defaults — re-enable `gpg` and un-exclude `gpg4win` there. |
| `setup-win.ps1` / `setup.sh` / `setup-mac.sh` | gpg-agent config, logon task, gnome-keyring SSH disable | Same workflow assumption on each OS; all behind the `gpg` component. |
| `ssh_config` | (nearly empty) | Installed as your **entire** `~/.ssh/config`, deleting whatever you had. Merge your own hosts into this file before running an installer. |

### Employer- and workflow-specific Git settings

| File | Setting | Why |
|---|---|---|
| `.gitconfig` | `[credential "https://lfscache.office.playeveryware.com"] provider = github` | PlayEveryWare's internal Git LFS cache. Harmless elsewhere, but remove it if this config leaves the org. |
| `.gitconfig` | alias `lpm` (`remotes/p4/master..`) | Assumes a git-p4 (Perforce) remote named `p4`. |
| `.gitconfig` | alias `svu` | git-svn helper against `origin/master`. Dead weight without SVN. |
| `.gitconfig-windows` | `[merge]`/`[diff] tool = vscode` | Diff/merge via `code --wait`; requires VS Code on PATH (the `vscode` component installs it). |
| `.gitconfig-mac` | `[merge]`/`[diff] tool = bc3` (`bcomp`) | Still the original Beyond Compare setup (paid license); change if you ever set up a Mac. |

### Personal package and tool choices (`packages.json`, `setup-win.ps1`)

Things the original author uses that are now **excluded by the default
`install.config.json`** (remove them from `packages.exclude` to get them back):

- **Personal-bucket tools**: `dicklesworthstone/bv` and `mendsley/bd`. The
  `scoop bucket add` lines for those two buckets still run (harmlessly) when
  the `packages` component is enabled.
- **Personal apps**: `gnucash` (personal finance), `winrar`, `marktext`,
  `p4v` (Perforce client), `versions/beyondcompare4`, `yubioath` (YubiKey),
  `alacritty`, `dotnet-sdk`, and `openvpn` (an admin package installed
  globally when not excluded).
- **Pinned versions** at the top of `setup-win.ps1`: `$goupVersion`,
  `$goVersion` (note: the goup download URL hardcodes `v1.7.0` regardless of
  the variable), and `$ompTheme` (also effectively hardcoded — line ~257 embeds
  `multiverse-neon.omp.json` directly).

### Look-and-feel choices

- `setup-win.ps1` forces Windows Terminal to pwsh + MesloLGM Nerd Font and
  manages a block of your pwsh profile (oh-my-posh `multiverse-neon`, fzf
  keybindings, plus eza/bat aliases only when `cli_aliases` is enabled);
  anything you add outside the marked block is left alone.
- `.zshrc` hardcodes Apple Silicon Homebrew paths (`/opt/homebrew/...`) —
  Intel Macs use `/usr/local` and will need edits. Theme is `af-magic`;
  `EDITOR=nvim` (Windows sets `EDITOR=code` instead).
- `nvim/init.lua` uses `;` as the leader key, kanagawa-wave colorscheme, and
  auto-installs `gopls` and `clangd` — a Go/C++ development bias throughout
  (see also the Go toolchains in every installer and `oh-my-opencode.json`).
- `.i3/config` / `.i3status.conf` (Linux) assume gnome-settings-daemon paths
  and `wlan0`/`eth0` interface names from an older distro.

## Agent policy

`AGENTS.md`, `.agentpolicy/`, and the `permissions.deny` block of
`.claude/settings.json` are a centrally managed policy for AI coding agents
(protected `main`, PR-only merges, Git hooks). They are synchronized with
`./.agentpolicy/sync.ps1` and must not be hand-edited — see `AGENTS.md` for
the rules and `.agentpolicy/testing.md` for project-owned testing notes.
