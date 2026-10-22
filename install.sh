#!/usr/bin/env bash
# Per-user installation of Pi and Oh My Pi from upstream release binaries.
# No Node.js, npm, or administrator account is required.
set -euo pipefail

SETUP_VERSION=v0.3.0
PI_RELEASE=https://github.com/earendil-works/pi/releases/latest/download
OMP_RELEASE=https://github.com/can1357/oh-my-pi/releases/latest/download

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
sq() { local v=${1//\'/\'\\\'\'}; printf "'%s'" "$v"; }
pi_asset() { printf 'pi-%s-%s.tar.gz' "$upstream_os" "$arch"; }
omp_asset() { printf 'omp-%s-%s' "$upstream_os" "$arch"; }
# Remove files left by the npm-based installer (private Node, DCG, bang-guard).
# Pi and omp binaries in the bin directory are replaced by this install. Session
# data under the agent directories is never deleted.
remove_managed() {
  local file=$1 marker=$2 first_line=''
  [[ -f "$file" && ! -L "$file" ]] || return 0
  IFS= read -r first_line < "$file" || true
  # A prefix matches the full managed header, including DCG's longer generated line.
  if [[ "$first_line" == "$marker"* ]]; then rm -f -- "$file"; echo "Removed $file"
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
  for path in "$data_dir/node" "$data_dir/npm"; do
    if [[ -e "$path" || -L "$path" ]]; then rm -rf -- "$path"; echo "Removed $path"; fi
  done
  remove_managed "$pi_dir/extensions/dcg-pi.ts" '// pi-omp-setup: managed dcg extension'
  remove_managed "$omp_dir/extensions/dcg-guard.ts" '// dcg-omp-extension:'
  remove_managed "$pi_dir/extensions/bang-guard.ts" '// bang-guard: managed extension'
  remove_managed "$omp_dir/extensions/bang-guard.ts" '// bang-guard: managed extension'
  return 0
}
install_pi_binary() {
  local bin_dir=$1 data_dir=$2 scratch=$3 asset
  asset=$(pi_asset)
  download "$PI_RELEASE/SHA256SUMS" "$scratch/pi.sha256"
  download "$PI_RELEASE/$asset" "$scratch/$asset"
  verify "$scratch/$asset" "$scratch/pi.sha256" "$asset"
  mkdir -p -- "$scratch/pi-unpacked"
  tar xzf "$scratch/$asset" -C "$scratch/pi-unpacked"
  [[ -x "$scratch/pi-unpacked/pi/pi" ]] || { echo 'Pi archive missing executable.' >&2; return 1; }
  rm -rf -- "$data_dir/pi"
  mv -- "$scratch/pi-unpacked/pi" "$data_dir/pi"
  ln -sfn -- "$data_dir/pi/pi" "$bin_dir/pi"
}
install_omp_binary() {
  local bin_dir=$1 scratch=$2 asset
  asset=$(omp_asset)
  download "$OMP_RELEASE/SHA256SUMS.txt" "$scratch/omp.sha256"
  download "$OMP_RELEASE/$asset" "$scratch/$asset"
  verify "$scratch/$asset" "$scratch/omp.sha256" "$asset"
  install -m 755 "$scratch/$asset" "$bin_dir/omp"
}
install_updater() {
  local bin_dir=$1 data_dir=$2 pi_dir=$3 omp_dir=$4
  local url="https://raw.githubusercontent.com/hotschmoe/pi-omp-setup/${SETUP_VERSION}/install.sh"
  cat > "$bin_dir/pi-omp-update" <<EOF
#!/bin/sh
set -eu
tmp=\$(mktemp)
trap 'rm -f "\$tmp"' EXIT
curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 $(sq "$url") -o "\$tmp"
exec bash "\$tmp" --update --bin-dir $(sq "$bin_dir") --data-dir $(sq "$data_dir") --pi-dir $(sq "$pi_dir") --omp-dir $(sq "$omp_dir") "\$@"
EOF
  chmod 755 "$bin_dir/pi-omp-update"
}
json_string() {
  local key=$1 file=$2 line
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ \"${key}\"[[:space:]]*:[[:space:]]*\"([^\"]*)\" ]]; then
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$file"
  return 1
}
probe_client() {
  local name=$1 out err pid start now
  shift
  out=$(mktemp)
  err=$(mktemp)
  "$@" </dev/null >"$out" 2>"$err" &
  pid=$!
  start=$(date +%s)
  while kill -0 "$pid" 2>/dev/null; do
    now=$(date +%s)
    if (( now - start >= 180 )); then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      printf '%s probe timed out.\n' "$name" >&2
      cat "$err" >&2 || true
      rm -f -- "$out" "$err"
      return 1
    fi
    sleep 1
  done
  if ! wait "$pid"; then
    printf '%s probe failed.\n' "$name" >&2
    cat "$err" >&2 || true
    rm -f -- "$out" "$err"
    return 1
  fi
  if ! grep -q '[^[:space:]]' "$out"; then
    printf '%s returned an empty response.\n' "$name" >&2
    cat "$err" >&2 || true
    rm -f -- "$out" "$err"
    return 1
  fi
  rm -f -- "$out" "$err"
  printf '%s responded.\n' "$name"
}
probe_models() {
  local bin_dir=$1 pi_dir=$2 provider model work status=0
  provider=$(json_string defaultProvider "$pi_dir/settings.json" || true)
  model=$(json_string defaultModel "$pi_dir/settings.json" || true)
  [[ -n "$provider" && -n "$model" ]] || { echo 'Model settings are missing; cannot probe.' >&2; return 1; }
  [[ -x "$bin_dir/pi" && -x "$bin_dir/omp" ]] || { echo 'pi and omp must be installed before the probe.' >&2; return 1; }
  work=$(mktemp -d)
  (
    cd "$work"
    probe_client pi "$bin_dir/pi" --no-extensions --no-skills --no-tools --no-session --no-approve --provider "$provider" --model "$model" -p 'Reply with the single word OK.'
    probe_client omp "$bin_dir/omp" --no-extensions --no-skills --no-tools --no-session --model "$provider/$model" -p 'Reply with the single word OK.'
  ) || status=$?
  rm -rf -- "$work"
  return "$status"
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
  local configure_only=0 plan=0 update=0 skip_probe=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bin-dir|--data-dir|--pi-dir|--omp-dir)
        [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; return 2; }
        case "$1" in --bin-dir) bin_dir=$2 ;; --data-dir) data_dir=$2 ;; --pi-dir) pi_dir=$2 ;; --omp-dir) omp_dir=$2 ;; esac; shift 2 ;;
      --configure-only) configure_only=1; shift ;;
      --update) update=1; shift ;;
      --skip-probe) skip_probe=1; shift ;;
      --plan) plan=1; shift ;;
      --help|-h) echo 'Usage: bash install.sh [--configure-only | --update] [--skip-probe] [--bin-dir DIR] [--data-dir DIR] [--pi-dir DIR] [--omp-dir DIR] [--plan]'; return ;;
      *) echo "Unknown option: $1" >&2; return 2 ;;
    esac
  done
  if [[ "$configure_only" == 1 && "$update" == 1 ]]; then echo 'Use either --configure-only or --update.' >&2; return 2; fi
  local directory
  for directory in "$bin_dir" "$data_dir" "$pi_dir" "$omp_dir"; do
    [[ "$directory" == /* ]] || { echo "Use an absolute directory path: $directory" >&2; return 2; }
  done
  local os upstream_os arch
  platform
  local helper_asset="pi-omp-setup-$os-$arch"
  if [[ "$plan" == 1 ]]; then printf '%s\n' "$(pi_asset)" "$(omp_asset)" "$helper_asset"; return; fi
  command -v curl >/dev/null || { echo 'Install curl using your OS package manager first.' >&2; return 1; }
  command -v tar >/dev/null || { echo 'tar is required.' >&2; return 1; }
  command -v sha256sum >/dev/null || command -v shasum >/dev/null || { echo 'sha256sum or shasum is required.' >&2; return 1; }
  if [[ "$os" == linux ]] && { ls /lib/ld-musl-*.so.1 >/dev/null 2>&1; }; then echo 'Pi requires glibc Linux; Alpine/musl is not supported by this installer.' >&2; return 1; fi
  setup_scratch=$(mktemp -d "${TMPDIR:-/tmp}/pi-omp-setup.XXXXXXXX")
  trap 'rm -rf -- "$setup_scratch"' EXIT
  local scratch=$setup_scratch base
  mkdir -p -- "$bin_dir" "$data_dir"
  if [[ "$configure_only" == 0 ]]; then
    if [[ "$update" == 0 ]]; then cleanup_legacy "$bin_dir" "$data_dir" "$pi_dir" "$omp_dir"; fi
    install_pi_binary "$bin_dir" "$data_dir" "$scratch"
    install_omp_binary "$bin_dir" "$scratch"
    install_updater "$bin_dir" "$data_dir" "$pi_dir" "$omp_dir"
    # Drop the private Node/npm tree left by earlier installers once the binaries are in place.
    for path in "$data_dir/node" "$data_dir/npm"; do
      if [[ -e "$path" || -L "$path" ]]; then rm -rf -- "$path"; echo "Removed $path"; fi
    done
  fi
  if [[ "$update" == 0 ]]; then
    base=https://github.com/hotschmoe/pi-omp-setup/releases/download/$SETUP_VERSION
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
  fi
  if [[ "$skip_probe" == 0 ]]; then probe_models "$bin_dir" "$pi_dir"; fi
  if [[ "$update" == 1 ]]; then
    printf '\nUpdated. pi and omp are the latest published release binaries.\n'
  else
    printf '\nInstalled. Launch %s/pi or %s/omp.\n' "$bin_dir" "$bin_dir"
    printf 'Update both later with: pi-omp-update\n'
    printf 'Open a new terminal to use them from PATH.\n'
  fi
}
if [[ -z "${BASH_SOURCE[0]:-}" || "${BASH_SOURCE[0]:-}" == "$0" ]]; then main "$@"; fi
