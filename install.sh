#!/usr/bin/env bash
# Per-user installation of Pi with a private Node.js LTS. No administrator required.
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
NODE_MAJOR=24
PI_PACKAGE=@earendil-works/pi-coding-agent
sq() { local v=${1//\'/\'\\\'\'}; printf "'%s'" "$v"; }
# Remove files left by earlier versions of this installer (standalone Pi build,
# OMP, DCG, bang-guard). Only files this project installed are touched; the
# ~/.omp directory is never deleted because it can hold the user's own sessions.
remove_managed() {
  local file=$1 marker=$2 first_line=''
  [[ -f "$file" && ! -L "$file" ]] || return 0
  IFS= read -r first_line < "$file" || true
  if [[ "$first_line" == "$marker" ]]; then rm -f -- "$file"; echo "Removed $file"
  else echo "Left custom file in place: $file" >&2; fi
}
cleanup_legacy() {
  local bin_dir=$1 data_dir=$2 pi_dir=$3 omp_dir=$4 path
  for path in "$bin_dir/omp" "$bin_dir/dcg" "$bin_dir/pi"; do
    if [[ -e "$path" || -L "$path" ]]; then rm -f -- "$path"; echo "Removed $path"; fi
  done
  for path in "$data_dir"/pi-v*; do
    [[ -d "$path" ]] && { rm -rf -- "$path"; echo "Removed $path"; }
  done
  remove_managed "$pi_dir/extensions/dcg-pi.ts" '// pi-omp-setup: managed dcg extension'
  remove_managed "$pi_dir/extensions/bang-guard.ts" '// bang-guard: managed extension'
  remove_managed "$omp_dir/extensions/bang-guard.ts" '// bang-guard: managed extension'
  if [[ -d "$omp_dir" ]]; then echo "Oh My Pi is no longer installed; your data in $omp_dir was left untouched."; fi
  return 0
}
node_asset() {
  # Name of the official archive for this platform in a Node SHASUMS256.txt.
  awk -v suffix="-$1-$2.$3" '{ n = $2; if (n ~ /^node-v[0-9.]+-/ && length(n) > length(suffix) && substr(n, length(n) - length(suffix) + 1) == suffix && n !~ /musl/) { print n; exit } }' "$4"
}
install_node() {
  local data_dir=$1 scratch=$2 base="https://nodejs.org/dist/latest-v$NODE_MAJOR.x" asset
  download "$base/SHASUMS256.txt" "$scratch/node.sha256"
  asset=$(node_asset "$upstream_os" "$arch" tar.gz "$scratch/node.sha256")
  [[ -n "$asset" ]] || { echo 'No Node.js build for this platform.' >&2; return 1; }
  download "$base/$asset" "$scratch/$asset"
  verify "$scratch/$asset" "$scratch/node.sha256" "$asset"
  mkdir -p -- "$scratch/node-unpacked"
  tar xzf "$scratch/$asset" -C "$scratch/node-unpacked"
  rm -rf -- "$data_dir/node"
  mv -- "$scratch/node-unpacked/${asset%.tar.gz}" "$data_dir/node"
  [[ -x "$data_dir/node/bin/node" ]] || { echo 'Node archive missing executable.' >&2; return 1; }
}
install_pi() {
  local bin_dir=$1 data_dir=$2 prefix="$2/npm"
  mkdir -p -- "$prefix"
  PATH="$data_dir/node/bin:$PATH" NPM_CONFIG_PREFIX="$prefix" \
    npm install -g --no-fund --no-audit --loglevel=error "$PI_PACKAGE@latest"
  [[ -x "$prefix/bin/pi" ]] || { echo 'Pi package did not provide a pi command.' >&2; return 1; }
  # The launcher points npm at the private prefix so `pi update` stays self-contained.
  { printf '#!/bin/sh\nexport NPM_CONFIG_PREFIX=%s\nexport PATH=%s:%s:"$PATH"\nexec %s "$@"\n' \
      "$(sq "$prefix")" "$(sq "$data_dir/node/bin")" "$(sq "$prefix/bin")" "$(sq "$prefix/bin/pi")"; } > "$bin_dir/pi"
  chmod 755 "$bin_dir/pi"
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
  local configure_only=0 plan=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-dir|--data-dir|--pi-dir)
        [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; return 2; }
        case "$1" in --bin-dir) bin_dir=$2 ;; --data-dir) data_dir=$2 ;; --pi-dir) pi_dir=$2 ;; esac; shift 2 ;;
      --configure-only) configure_only=1; shift ;;
      --plan) plan=1; shift ;;
      --help|-h) echo 'Usage: bash install.sh [--configure-only] [--bin-dir DIR] [--data-dir DIR] [--pi-dir DIR] [--plan]'; return ;;
      *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
  done
  local directory
  for directory in "$bin_dir" "$data_dir" "$pi_dir"; do
    [[ "$directory" == /* ]] || { echo "Use an absolute directory path: $directory" >&2; return 2; }
  done
  local os upstream_os arch
  platform
  local helper_asset="pi-omp-setup-$os-$arch"
  if [[ "$plan" == 1 ]]; then printf '%s\n' "node-v$NODE_MAJOR-$upstream_os-$arch" "$PI_PACKAGE" "$helper_asset"; return; fi
  command -v curl >/dev/null || { echo 'Install curl using your OS package manager first.' >&2; return 1; }
  command -v tar >/dev/null || { echo 'tar is required.' >&2; return 1; }
  command -v sha256sum >/dev/null || command -v shasum >/dev/null || { echo 'sha256sum or shasum is required.' >&2; return 1; }
  if [[ "$os" == linux ]] && { ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; }; then echo 'Pi requires glibc Linux; Alpine/musl is not supported by this installer.' >&2; return 1; fi
  setup_scratch=$(mktemp -d "${TMPDIR:-/tmp}/pi-omp-setup.XXXXXXXX")
  trap 'rm -rf -- "$setup_scratch"' EXIT
  local scratch=$setup_scratch base
  mkdir -p -- "$bin_dir" "$data_dir"
  if [[ "$configure_only" == 0 ]]; then
    cleanup_legacy "$bin_dir" "$data_dir" "$pi_dir" "$HOME/.omp/agent"
    install_node "$data_dir" "$scratch"
    install_pi "$bin_dir" "$data_dir"
  fi
  base=https://github.com/hotschmoe/pi-omp-setup/releases/download/v0.2.0
  download "$base/$helper_asset" "$scratch/$helper_asset"
  download "$base/config.enc.json" "$scratch/config.enc.json"
  download "$base/SHA256SUMS" "$scratch/setup.sha256"
  verify "$scratch/$helper_asset" "$scratch/setup.sha256" "$helper_asset"
  verify "$scratch/config.enc.json" "$scratch/setup.sha256" config.enc.json
  install -m 755 "$scratch/$helper_asset" "$bin_dir/pi-omp-setup"
  "$bin_dir/pi-omp-setup" configure --bundle "$scratch/config.enc.json" --pi-dir "$pi_dir"
  export PATH="$bin_dir:$PATH"
  add_path_file "$HOME/.profile" "$bin_dir"
  case "${SHELL:-}" in
    */zsh) add_path_file "$HOME/.zshrc" "$bin_dir" ;;
    */bash|'') add_path_file "$HOME/.bashrc" "$bin_dir" ;;
  esac
  printf '\nInstalled. Launch %s/pi (update later with: pi update).\n' "$bin_dir"
  printf 'Open a new terminal to use pi from PATH.\n'
}
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then main "$@"; fi
