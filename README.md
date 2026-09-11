# Pi + OMP setup

Install [Pi](https://github.com/earendil-works/pi) and [Oh My Pi](https://github.com/can1357/oh-my-pi) with the private `hotschmoe-dd` model selected. The installers download native upstream programs and a small Rust configuration helper into your user account. No npm, compiler, administrator account, or subscription login is needed for setup.

You need the **six randomly chosen words** supplied privately by the maintainer. Enter the complete setup passphrase at the hidden prompt, preserving its separators. It is never part of the installation command or public repository.

## Install

Linux or macOS, from an interactive terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.1.1/install.sh | bash
```

Windows, from PowerShell 5.1 or newer:

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.1.1/install.ps1).Content))
```

Enter the private passphrase when asked. Then choose whether to install **Destructive Command Guard (DCG)** and **bang-guard**; each defaults to yes when you press Enter. Open a new terminal and run `pi` or `omp`.

The Windows installer provides a checksum-verified, portable Git for Windows when it cannot find Git Bash. It adds Bash to your user PATH. Unix requires Bash, curl, tar, and either `sha256sum` or `shasum`; Ubuntu's usual curl package is sufficient if curl is missing. Installation uses `~/.local/bin` and `~/.local/share/pi-omp-setup`. Unix appends a managed PATH entry to `.profile` and the relevant Bash/Zsh startup file; Windows updates your user PATH.

## Platforms and pinned versions

| System | CPU | Native download |
| --- | --- | --- |
| Linux with glibc | x86_64, ARM64 | Pi archive and OMP executable |
| Windows | x86_64, ARM64 | Pi archive and OMP executable |
| macOS | Intel, Apple silicon | Pi archive and OMP executable |

Linux helper builds target Ubuntu 22.04's glibc baseline or newer. Alpine/musl Linux and 32-bit CPUs are not supported. The CI workflow builds and tests the helper on all six native platforms; a successful helper build does not establish full interactive-client compatibility on every operating-system version. Pi and OMP have been downloaded and version-tested on Linux x86_64. Native Windows and macOS end-to-end installation still needs validation on those systems.

| Component | Version |
| --- | --- |
| Setup helper and encrypted bundle | `v0.1.1` |
| Pi | `v0.85.1` |
| OMP | `v18.1.14` |
| DCG, optional | `v0.14.0` |
| bang-guard, optional | `v0.3.0` |
| Portable Git for Windows, when needed | `v2.55.0.windows.5` |

## Private configuration

The public release includes `config.enc.json`: authenticated ciphertext encrypted with AES-256-GCM, using an Argon2id key derived from the private passphrase and a random salt. The endpoint and API key are encrypted inside that file. The repository, helper binary, and download commands contain neither credential.

The Rust helper decrypts the bundle **locally** and merges the model into these files:

| Client | Models | Default model |
| --- | --- | --- |
| Pi | `~/.pi/agent/models.json` | `~/.pi/agent/settings.json` |
| OMP | `~/.omp/agent/models.yml` | `~/.omp/agent/config.yml` |

Both clients use **200,000 context**, **32,768 total output tokens**,
**8,192 thinking tokens**, **medium reasoning effort**, and a **40,000-token
compaction reserve**. Output includes reasoning and the answer/tool calls.
PI uses its dynamic vLLM thinking-budget support; OMP 18.1.14 sends a fixed
8,192 budget only on reasoning-enabled requests. Changing OMP's effort selector
does not change that numeric cap. Qwen thinking history is preserved.
Restart existing clients after reconfiguration. These defaults are a practical
starting point for this endpoint, not universal model recommendations.

Existing OMP `.yaml` files are respected. Unrelated settings and providers are preserved, and changed files receive numbered backups. Repeating the same setup is idempotent. Invalid bundles or incorrect passphrases are rejected before client settings are changed.

The client files contain the decrypted credentials so Pi and OMP can connect normally. The helper restricts access using Unix file permissions or Windows ACLs; backups need the same protection. Do not publish these files or their backups. A public encrypted bundle allows offline passphrase guesses, so use six randomly selected EFF-list words, not a memorable sentence. Anyone with the passphrase can recover the API key. Share the passphrase privately and keep it out of shell history, screenshots, and Git. Changing the passphrase does not revoke old ciphertext or its API key; revoke or rotate the underlying key if access must be withdrawn.

DCG installs its native OMP extension and this project's Pi adapter. bang-guard installs its shared extension into both clients. Restart running clients after installing either guard. These guards supplement normal review of commands; their upstream documentation describes their scope.

## Options

Download the installer first when passing options:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.1.1/install.sh
bash install.sh --no-guards
```

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.1.1/install.ps1 -OutFile install.ps1
& .\install.ps1 -NoGuards
```

| Purpose | Bash | PowerShell |
| --- | --- | --- |
| Reconfigure existing clients | `--configure-only` | `-ConfigureOnly` |
| Skip optional guards | `--no-guards` | `-NoGuards` |
| Select both guards without questions | `--guards yes` | `-Guards Yes` |
| Print platform asset names only | `--plan` | `-Plan` |
| Custom executable directory | `--bin-dir DIR` | `-BinDir DIR` |
| Custom installation data directory | `--data-dir DIR` | `-DataDir DIR` |
| Custom Pi agent directory | `--pi-dir DIR` | `-PiDir DIR` |
| Custom OMP agent directory | `--omp-dir DIR` | `-OmpDir DIR` |

Use absolute paths for directory overrides. Custom agent paths select where setup writes configuration; launch the clients with their corresponding profile/directory settings. `--configure-only` still downloads the helper and encrypted bundle and asks about optional guards unless you skip them. Without a controlling terminal, Bash skips optional guards unless explicitly selected; passphrase entry still requires an interactive terminal.

## Development and releases

```bash
cargo test --locked
cargo build --release --locked
bash tests/installers.sh
```

Run `tests/installers.ps1` in PowerShell to check Windows platform planning, checksum rejection, and mocked downloads. Tests use dummy configuration and temporary directories; they do not require deployment credentials.

The GitHub Actions workflow builds six helper artifacts using [native hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). It uploads build artifacts only. Release publication is a separate maintainer action.

For a release, collect the six `pi-omp-setup-{linux,windows,macos}-{x64,arm64}` executables, adding `.exe` on Windows. Include `config.enc.json` and `dcg-pi.ts`, and generate `SHA256SUMS` covering every release asset the installers download. Keep plaintext input and the private passphrase outside the checkout; use the helper's `seal --help` for local bundle creation. Never upload plaintext configuration or the passphrase as workflow artifacts or release files.

MIT licensed. Downloaded upstream programs retain their respective licenses.
