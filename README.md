# Pi setup

Install [Pi](https://github.com/earendil-works/pi) with the private `hotschmoe-dd` model selected. The installers download a private Node.js LTS, install Pi from npm into your user account, and run a small Rust configuration helper. Pi stays updatable with `pi update`. No system npm, compiler, administrator account, or subscription login is needed for setup.

You need the **six randomly chosen words** supplied privately by the maintainer. Enter the complete setup passphrase at the hidden prompt, preserving its separators. It is never part of the installation command or public repository.

## Install

Linux or macOS, from an interactive terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.2.0/install.sh | bash
```

Windows, from PowerShell 5.1 or newer:

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.2.0/install.ps1).Content))
```

Enter the private passphrase when asked, then open a new terminal and run `pi`. Update Pi later with `pi update`.

**Upgrading from an earlier version:** the installer first removes the old standalone Pi build, `omp`, DCG, and bang-guard files that earlier versions installed. Your own extensions are left alone, and `~/.omp` is never deleted, so you can remove it yourself once you no longer need it.

The Windows installer provides a checksum-verified, portable Git for Windows when it cannot find Git Bash. It adds Bash to your user PATH. Node.js is installed privately in `~/.local/share/pi-omp-setup/node`, so Pi does not depend on, or modify, any Node you already have. Unix requires Bash, curl, tar, and either `sha256sum` or `shasum`; Ubuntu's usual curl package is sufficient if curl is missing. Installation uses `~/.local/bin` and `~/.local/share/pi-omp-setup`. Unix appends a managed PATH entry to `.profile` and the relevant Bash/Zsh startup file; Windows updates your user PATH.

## Platforms and pinned versions

| System | CPU |
| --- | --- |
| Linux with glibc | x86_64, ARM64 |
| Windows | x86_64, ARM64 |
| macOS | Intel, Apple silicon |

Linux helper builds target Ubuntu 22.04's glibc baseline or newer. Alpine/musl Linux and 32-bit CPUs are not supported. The CI workflow builds and tests the helper on all six native platforms; a successful helper build does not establish full interactive-client compatibility on every operating-system version. The npm-based installation and Pi 1.3.0 configuration have been tested on Linux ARM64. Native Windows and macOS end-to-end installation still needs validation on those systems.

| Component | Version |
| --- | --- |
| Setup helper and encrypted bundle | `v0.2.0` |
| Pi | latest release from npm (`@earendil-works/pi-coding-agent`) |
| Node.js | latest v24 LTS, verified against nodejs.org checksums |
| Portable Git for Windows, when needed | `v2.55.0.windows.5` |

## Private configuration

The public release includes `config.enc.json`: authenticated ciphertext encrypted with AES-256-GCM, using an Argon2id key derived from the private passphrase and a random salt. The endpoint and API key are encrypted inside that file. The repository, helper binary, and download commands contain neither credential.

The Rust helper decrypts the bundle **locally** and merges the model into `~/.pi/agent/models.json` and the default model into `~/.pi/agent/settings.json`.

Pi uses **200,000 context**, **32,768 total output tokens**,
**8,192 thinking tokens**, **medium reasoning effort**, and a **40,000-token
compaction reserve**. Output includes reasoning and the answer/tool calls.
Pi uses its dynamic vLLM thinking-budget support. Qwen thinking history is preserved.
Restart existing clients after reconfiguration. These defaults are a practical
starting point for this endpoint, not universal model recommendations.

Unrelated settings and providers are preserved, and changed files receive numbered backups. Repeating the same setup is idempotent. Invalid bundles or incorrect passphrases are rejected before client settings are changed.

The client files contain the decrypted credentials so Pi can connect normally. The helper restricts access using Unix file permissions or Windows ACLs; backups need the same protection. Do not publish these files or their backups. A public encrypted bundle allows offline passphrase guesses, so use six randomly selected EFF-list words, not a memorable sentence. Anyone with the passphrase can recover the API key. Share the passphrase privately and keep it out of shell history, screenshots, and Git. Changing the passphrase does not revoke old ciphertext or its API key; revoke or rotate the underlying key if access must be withdrawn.

## Options

Download the installer first when passing options:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.2.0/install.sh
bash install.sh --configure-only
```

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.2.0/install.ps1 -OutFile install.ps1
& .\install.ps1 -ConfigureOnly
```

| Purpose | Bash | PowerShell |
| --- | --- | --- |
| Reconfigure existing clients | `--configure-only` | `-ConfigureOnly` |
| Print platform download names only | `--plan` | `-Plan` |
| Custom executable directory | `--bin-dir DIR` | `-BinDir DIR` |
| Custom installation data directory | `--data-dir DIR` | `-DataDir DIR` |
| Custom Pi agent directory | `--pi-dir DIR` | `-PiDir DIR` |

Use absolute paths for directory overrides. A custom Pi agent path selects where setup writes configuration; launch Pi with the matching `PI_CODING_AGENT_DIR`. `--configure-only` downloads only the helper and encrypted bundle and leaves Node, Pi and any old files untouched. Passphrase entry requires an interactive terminal.

## Development and releases

```bash
cargo test --locked
cargo build --release --locked
bash tests/installers.sh
```

Run `tests/installers.ps1` in PowerShell to check Windows platform planning, checksum rejection, mocked downloads, Node selection, and legacy cleanup. Tests use dummy configuration and temporary directories; they do not require deployment credentials.

The GitHub Actions workflow builds six helper artifacts using [native hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). It uploads build artifacts only. Release publication is a separate maintainer action.

For a release, collect the six `pi-omp-setup-{linux,windows,macos}-{x64,arm64}` executables, adding `.exe` on Windows. Include `config.enc.json`, and generate `SHA256SUMS` covering every release asset the installers download. Keep plaintext input and the private passphrase outside the checkout; use the helper's `seal --help` for local bundle creation. Never upload plaintext configuration or the passphrase as workflow artifacts or release files.

MIT licensed. Downloaded upstream programs retain their respective licenses.
