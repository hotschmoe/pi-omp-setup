# Pi and Oh My Pi setup

Install [Pi](https://github.com/earendil-works/pi) and [Oh My Pi](https://github.com/can1357/oh-my-pi) with the private `hotschmoe-dd` model selected. The installers download the official release binaries, verify them against each project's published checksums, and run a small Rust configuration helper. No Node.js, npm, compiler, administrator account, or subscription login is needed.

Update both programs later with `pi-omp-update`. That command downloads the latest Pi and Oh My Pi release binaries and checks their checksums again. `pi update` cannot replace a standalone Pi binary: when a newer release exists it only prints a download link. `omp update` can replace its own binary, but it still consults npm to decide the version and has failed when that version was not published on GitHub yet. `pi-omp-update` uses the GitHub release assets for both tools.

You need the **six randomly chosen words** supplied privately by the maintainer. Enter the complete setup passphrase at the hidden prompt, preserving its separators. It is never part of the installation command or public repository.

## Install

Linux or macOS, from an interactive terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.3.1/install.sh | bash
```

Windows, from PowerShell 5.1 or newer:

```powershell
& ([scriptblock]::Create((Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.3.1/install.ps1).Content))
```

Enter the private passphrase when asked. The installer then sends each program the prompt `Reply with the single word OK.` and waits for a non-empty answer. Open a new terminal and run `pi` or `omp`.

**Upgrading from an earlier version:** the installer removes the private Node.js and npm tree, the `dcg` command, the managed Pi DCG extension, Oh My Pi's generated `dcg-guard.ts`, and the managed bang-guard extensions. It replaces the `pi` and `omp` binaries. Your own extensions are left alone. Session directories are not deleted. Model settings are rewritten: every previously configured custom provider is replaced by `hotschmoe-local` / `hotschmoe-dd`, and roles or allow-lists that named a removed model are pointed at `hotschmoe-dd`. Theme, compaction, and other non-model settings stay.

The Windows installer provides a checksum-verified, portable Git for Windows when it cannot find Git Bash. It adds Bash to your user PATH, because Pi's shell tool uses Bash. Unix requires curl, tar, and either `sha256sum` or `shasum`; Ubuntu's usual curl package is sufficient if curl is missing. Installation uses `~/.local/bin` and `~/.local/share/pi-omp-setup`. Unix appends a managed PATH entry to `.profile` and the relevant Bash/Zsh startup file; Windows updates your user PATH.

## Platforms and pinned versions

| System | CPU |
| --- | --- |
| Linux with glibc | x86_64, ARM64 |
| Windows | x86_64, ARM64 |
| macOS | Intel, Apple silicon |

Linux helper builds target Ubuntu 22.04's glibc baseline or newer. Alpine/musl Linux and 32-bit CPUs are not supported, because the Pi release binary is built for glibc. The CI workflow builds and tests the helper on all six native platforms; a successful helper build does not establish full interactive-client compatibility on every operating-system version. Native Windows and macOS end-to-end installation still needs validation on those systems.

| Component | Version |
| --- | --- |
| Setup helper and encrypted bundle | `v0.3.1` |
| Pi | latest GitHub release, checksum verified |
| Oh My Pi | latest GitHub release, checksum verified |
| Portable Git for Windows, when needed | `v2.55.0.windows.5` |

## Private configuration

The public release includes `config.enc.json`: authenticated ciphertext encrypted with AES-256-GCM, using an Argon2id key derived from the private passphrase and a random salt. The endpoint and API key are encrypted inside that file. The repository, helper binary, and download commands contain neither credential.

The Rust helper decrypts the bundle **locally** and writes the model into Pi (`~/.pi/agent/models.json` and `settings.json`) and Oh My Pi (`~/.omp/agent/models.yml`, or an existing `models.yaml` / `models.json`, and `config.yml`, or an existing `config.yaml` / `settings.json`).

`hotschmoe-dd` accepts **text and images**. Oh My Pi's `default` and `vision` roles both use it, so image turns are not sent to another model. Pi uses **200,000 context**, **32,768 total output tokens**,
**8,192 thinking tokens**, **medium reasoning effort**, and a **40,000-token
compaction reserve**. Output includes reasoning and the answer/tool calls.
Pi uses its dynamic vLLM thinking-budget support. Thinking history is preserved.
Restart existing clients after reconfiguration. These defaults are a practical
starting point for this endpoint, not universal model recommendations.

Custom providers other than `hotschmoe-local` are removed, including retired model ids. Non-model settings are kept. Changed files receive numbered backups. Repeating the same setup is idempotent. Invalid bundles or incorrect passphrases are rejected before client settings are changed. YAML comments in rewritten Oh My Pi files are not preserved.

The client files contain the decrypted credentials so Pi can connect normally. The helper restricts access using Unix file permissions or Windows ACLs; backups need the same protection. Do not publish these files or their backups. A public encrypted bundle allows offline passphrase guesses, so use six randomly selected EFF-list words, not a memorable sentence. Anyone with the passphrase can recover the API key. Share the passphrase privately and keep it out of shell history, screenshots, and Git. Changing the passphrase does not revoke old ciphertext or its API key; revoke or rotate the underlying key if access must be withdrawn.

## Options

Download the installer first when passing options:

```bash
curl -fsSLo install.sh https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.3.1/install.sh
bash install.sh --configure-only
```

```powershell
Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/v0.3.1/install.ps1 -OutFile install.ps1
& .\install.ps1 -ConfigureOnly
```

| Purpose | Bash | PowerShell |
| --- | --- | --- |
| Reconfigure existing clients | `--configure-only` | `-ConfigureOnly` |
| Replace pi and omp binaries only | `--update` | `-Update` |
| Skip the live model probe | `--skip-probe` | `-SkipProbe` |
| Print platform download names only | `--plan` | `-Plan` |
| Custom executable directory | `--bin-dir DIR` | `-BinDir DIR` |
| Custom installation data directory | `--data-dir DIR` | `-DataDir DIR` |
| Custom Pi agent directory | `--pi-dir DIR` | `-PiDir DIR` |
| Custom Oh My Pi agent directory | `--omp-dir DIR` | `-OmpDir DIR` |

Use absolute paths for directory overrides. A custom agent path selects where setup writes configuration; launch the client with the matching `PI_CODING_AGENT_DIR`. `--configure-only` downloads only the helper and encrypted bundle and leaves binaries untouched. `--update` replaces the binaries and does not ask for the passphrase. Passphrase entry requires an interactive terminal. `pi-omp-update` is the installed form of `--update`.

## Development and releases

```bash
cargo test --locked
cargo build --release --locked
bash tests/installers.sh
```

Run `tests/installers.ps1` in PowerShell to check Windows platform planning, checksum rejection, mocked downloads, release asset names, and legacy cleanup. Tests use dummy configuration and temporary directories; they do not require deployment credentials.

The GitHub Actions workflow builds six helper artifacts using [native hosted runners](https://docs.github.com/en/actions/reference/runners/github-hosted-runners). It uploads build artifacts only. Release publication is a separate maintainer action.

For a release, collect the six `pi-omp-setup-{linux,windows,macos}-{x64,arm64}` executables, adding `.exe` on Windows. Include `config.enc.json`, and generate `SHA256SUMS` covering every release asset the installers download. Keep plaintext input and the private passphrase outside the checkout; use the helper's `seal --help` for local bundle creation. Never upload plaintext configuration or the passphrase as workflow artifacts or release files.

MIT licensed. Downloaded upstream programs retain their respective licenses.
