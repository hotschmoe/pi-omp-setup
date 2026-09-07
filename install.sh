#!/usr/bin/env bash
# Native, per-user installation. No npm, compiler, or administrator required.
set -euo pipefail

platform() {
  case "${1:-$(uname -s)}" in Linux) os=linux; upstream_os=linux ;; Darwin) os=macos; upstream_os=darwin ;; *) echo 'Use install.ps1 on Windows; unsupported Unix platform.' >&2; return 1 ;; esac
  case "${2:-$(uname -m)}" in x86_64|amd64) arch=x64 ;; aarch64|arm64) arch=arm64 ;; *) echo 'Only x86_64 and ARM64 are supported.' >&2; return 1 ;; esac
}
download() { curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 "$1" -o "$2"; }
verify() {
  local file=$1 manifest=$2 name=$3 expected actual
  expected=$(awk -v name="$name" '$2 == name || $2 == "*" name { print $1 }' "$manifest")
  [[ "$expected" =~ ^[a-fA-F0-9]{64}$ ]] || { echo "Missing/invalid checksum: $name" >&2; return 1; }
  if command -v sha256sum >/dev/null; then actual=$(sha256sum "$file"); else actual=$(shasum -a 256 "$file"); fi
  [[ "${actual%% *}" == "$expected" ]] || { echo "Checksum mismatch: $name" >&2; return 1; }
}
ask() {
  local reply
  if ! { : </dev/tty; } 2>/dev/null; then echo "No terminal: skipping optional $1 (use --guards yes to opt in)." >&2; return 1; fi
  printf 'Install %s? [Y/n] ' "$1" >/dev/tty
  IFS= read -r reply </dev/tty || return 1
  [[ "$reply" == '' || "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
}
add_path_file() {
  local profile=$1 directory=$2 quoted line existing
  if [[ -L "$profile" ]]; then
    printf 'Skipping symlinked shell profile: %s; add %s to PATH manually.\n' "$profile" "$directory" >&2
    return
  fi
  # POSIX single quoting also handles spaces, apostrophes, dollars and backticks.
  quoted=${directory//\'/\'\\\'\'}
  line="export PATH='$quoted':\"\$PATH\" # pi-omp-setup"
  if [[ -e "$profile" ]]; then
    [[ -f "$profile" ]] || { printf 'Skipping non-file profile: %s\n' "$profile" >&2; return; }
    while IFS= read -r existing || [[ -n "$existing" ]]; do
      [[ "$existing" != "$line" ]] || return 0
    done < "$profile"
  fi
  # Append only; every pre-existing byte is retained, even without a final LF.
  printf '\n# pi-omp-setup user commands\n%s\n' "$line" >> "$profile"
}
main() {
  local bin_dir="$HOME/.local/bin" data_dir="$HOME/.local/share/pi-omp-setup" pi_dir="$HOME/.pi/agent" omp_dir="$HOME/.omp/agent"
  local configure_only=0 guards=ask plan=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-dir|--data-dir|--pi-dir|--omp-dir|--guards)
        [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; return 2; }
        case "$1" in --bin-dir) bin_dir=$2 ;; --data-dir) data_dir=$2 ;; --pi-dir) pi_dir=$2 ;; --omp-dir) omp_dir=$2 ;; --guards) guards=$2 ;; esac; shift 2 ;;
      --configure-only) configure_only=1; shift ;;
      --no-guards) guards=no; shift ;;
      --plan) plan=1; shift ;;
      --help|-h) echo 'Usage: bash install.sh [--configure-only] [--guards ask|yes|no] [--no-guards] [--bin-dir DIR] [--data-dir DIR] [--pi-dir DIR] [--omp-dir DIR] [--plan]'; return ;;
      *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
  done
  case "$guards" in ask|yes|no) ;; *) echo 'Expected --guards ask|yes|no' >&2; return 2 ;; esac
  local directory
  for directory in "$bin_dir" "$data_dir" "$pi_dir" "$omp_dir"; do
    [[ "$directory" == /* ]] || { echo "Use an absolute directory path: $directory" >&2; return 2; }
  done
  local os upstream_os arch
  platform
  local pi_asset="pi-$upstream_os-$arch.tar.gz" omp_asset="omp-$upstream_os-$arch" helper_asset="pi-omp-setup-$os-$arch"
  if [[ "$plan" == 1 ]]; then printf '%s\n' "$pi_asset" "$omp_asset" "$helper_asset"; return; fi
  command -v curl >/dev/null || { echo 'Install curl using your OS package manager first.' >&2; return 1; }
  command -v tar >/dev/null || { echo 'tar is required.' >&2; return 1; }
  command -v sha256sum >/dev/null || command -v shasum >/dev/null || { echo 'sha256sum or shasum is required.' >&2; return 1; }
  if [[ "$os" == linux ]] && { ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; }; then echo 'Pi requires glibc Linux; Alpine/musl is not supported by this installer.' >&2; return 1; fi
  setup_scratch=$(mktemp -d "${TMPDIR:-/tmp}/pi-omp-setup.XXXXXXXX")
  trap 'rm -rf -- "$setup_scratch"' EXIT
  local scratch=$setup_scratch base
  mkdir -p -- "$bin_dir" "$data_dir"
  if [[ "$configure_only" == 0 ]]; then
    base=https://github.com/earendil-works/pi/releases/download/v0.85.1
    download "$base/$pi_asset" "$scratch/$pi_asset"
    download "$base/SHA256SUMS" "$scratch/pi.sha256"
    verify "$scratch/$pi_asset" "$scratch/pi.sha256" "$pi_asset"
    tar xzf "$scratch/$pi_asset" -C "$scratch"
    [[ -x "$scratch/pi/pi" ]] || { echo 'Pi archive missing executable.' >&2; return 1; }
    # Keep the full distribution: Pi discovers docs/themes relative to its binary.
    mkdir -p -- "$data_dir/pi-v0.85.1"
    cp -R "$scratch/pi/." "$data_dir/pi-v0.85.1/"
    ln -sfn "$data_dir/pi-v0.85.1/pi" "$bin_dir/pi"
    base=https://github.com/can1357/oh-my-pi/releases/download/v18.1.14
    download "$base/$omp_asset" "$scratch/$omp_asset"
    download "$base/SHA256SUMS.txt" "$scratch/omp.sha256"
    verify "$scratch/$omp_asset" "$scratch/omp.sha256" "$omp_asset"
    install -m 755 "$scratch/$omp_asset" "$bin_dir/omp"
  fi
  base=https://github.com/hotschmoe/pi-omp-setup/releases/download/v0.1.0
  download "$base/$helper_asset" "$scratch/$helper_asset"
  download "$base/config.enc.json" "$scratch/config.enc.json"
  download "$base/SHA256SUMS" "$scratch/setup.sha256"
  verify "$scratch/$helper_asset" "$scratch/setup.sha256" "$helper_asset"
  verify "$scratch/config.enc.json" "$scratch/setup.sha256" config.enc.json
  install -m 755 "$scratch/$helper_asset" "$bin_dir/pi-omp-setup"
  "$bin_dir/pi-omp-setup" configure --bundle "$scratch/config.enc.json" --pi-dir "$pi_dir" --omp-dir "$omp_dir"
  export PATH="$bin_dir:$PATH"
  add_path_file "$HOME/.profile" "$bin_dir"
  case "${SHELL:-}" in
    */zsh) add_path_file "$HOME/.zshrc" "$bin_dir" ;;
    */bash|'') add_path_file "$HOME/.bashrc" "$bin_dir" ;;
  esac
  if [[ "$guards" == yes ]] || { [[ "$guards" == ask ]] && ask 'Destructive Command Guard (DCG)'; }; then
    download https://raw.githubusercontent.com/Dicklesworthstone/destructive_command_guard/v0.14.0/install.sh "$scratch/dcg-install.sh"
    bash "$scratch/dcg-install.sh" --version v0.14.0 --easy-mode --no-configure --dest "$bin_dir"
    OMP_PROFILE='' PI_PROFILE='' PI_CODING_AGENT_DIR="$omp_dir" "$bin_dir/dcg" install --omp
    download "$base/dcg-pi.ts" "$scratch/dcg-pi.ts"
    verify "$scratch/dcg-pi.ts" "$scratch/setup.sha256" dcg-pi.ts
    local dest="$pi_dir/extensions/dcg-pi.ts" first_line
    [[ ! -L "$dest" ]] || { echo "Refusing symlink: $dest" >&2; return 1; }
    if [[ -e "$dest" ]]; then
      IFS= read -r first_line < "$dest" || true
      [[ "$first_line" == '// pi-omp-setup: managed dcg extension' ]] || { echo "Refusing to replace custom extension: $dest" >&2; return 1; }
      cp -p "$dest" "$dest.bak"
    fi
    mkdir -p -- "$pi_dir/extensions"
    install -m 600 "$scratch/dcg-pi.ts" "$dest"
  fi
  if [[ "$guards" == yes ]] || { [[ "$guards" == ask ]] && ask 'bang-guard'; }; then
    download https://raw.githubusercontent.com/hotschmoe/bang-guard/v0.3.0/install.sh "$scratch/bang-install.sh"
    bash "$scratch/bang-install.sh" --version v0.3.0 --target both --pi-dir "$pi_dir" --omp-dir "$omp_dir"
  fi
  printf '\nInstalled. Launch %s/pi or %s/omp.\n' "$bin_dir" "$bin_dir"
  printf 'Open a new terminal to use pi and omp from PATH.\n'
}
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then main "$@"; fi
