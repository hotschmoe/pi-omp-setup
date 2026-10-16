#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
source "$repo/install.sh"
for host in Linux Darwin; do
  for cpu in x86_64 aarch64 arm64; do
    platform "$host" "$cpu"
    [[ "$arch" == x64 || "$arch" == arm64 ]]
    [[ "$os" == linux || "$os" == macos ]]
  done
done
if platform Linux riscv64 2>/dev/null; then echo 'Accepted unsupported CPU' >&2; exit 1; fi
if platform FreeBSD x86_64 2>/dev/null; then echo 'Accepted unsupported OS' >&2; exit 1; fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
printf 'fixture\n' > "$scratch/tool"
if command -v sha256sum >/dev/null; then
  sha256sum "$scratch/tool" | sed "s|$scratch/||" > "$scratch/SHA256SUMS"
else
  shasum -a 256 "$scratch/tool" | sed "s|$scratch/||" > "$scratch/SHA256SUMS"
fi
verify "$scratch/tool" "$scratch/SHA256SUMS" tool
printf 'tampered\n' >> "$scratch/tool"
if verify "$scratch/tool" "$scratch/SHA256SUMS" tool 2>/dev/null; then echo 'Accepted corrupt binary' >&2; exit 1; fi
if verify "$scratch/tool" "$scratch/SHA256SUMS" missing 2>/dev/null; then echo 'Accepted missing checksum' >&2; exit 1; fi
# Mock curl proves URLs/output paths remain intact, including spaces.
mkdir "$scratch/mock"
cat > "$scratch/mock/curl" <<'MOCK'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in -o) shift; dest=$1 ;; https://*) url=$1 ;; esac
  shift
done
printf '%s' "$url" > "$dest"
MOCK
chmod +x "$scratch/mock/curl"
PATH="$scratch/mock:$PATH" download https://example.invalid/asset "$scratch/with spaces"
[[ $(cat "$scratch/with spaces") == https://example.invalid/asset ]]
# Profile updates preserve existing bytes, are idempotent, quote metacharacters,
# and never follow a profile symlink. These tests only touch explicit temp paths.
profile="$scratch/profile"
printf 'export EXISTING=yes' > "$profile"
weird_dir="/tmp/a b'c"'$(echo forbidden)`echo forbidden`'
add_path_file "$profile" "$weird_dir"
cp "$profile" "$scratch/once"
add_path_file "$profile" "$weird_dir"
cmp "$profile" "$scratch/once"
[[ $(head -c 19 "$profile") == 'export EXISTING=yes' ]]
resolved=$(PROFILE_TEST="$profile" bash -c 'source "$PROFILE_TEST"; printf "%s" "${PATH%%:*}"')
[[ "$resolved" == "$weird_dir" ]]
ln -s "$profile" "$scratch/profile-link"
add_path_file "$scratch/profile-link" /different/path 2>/dev/null
cmp "$profile" "$scratch/once"
# Legacy cleanup removes only what earlier installers created.
legacy="$scratch/legacy"
mkdir -p "$legacy/bin" "$legacy/data/pi-v0.85.1" "$legacy/pi/extensions" "$legacy/omp/extensions"
touch "$legacy/bin/omp" "$legacy/bin/dcg" "$legacy/bin/pi-omp-setup" "$legacy/omp/keep.txt"
ln -s "$legacy/data/pi-v0.85.1/pi" "$legacy/bin/pi"
printf '// pi-omp-setup: managed dcg extension\n' > "$legacy/pi/extensions/dcg-pi.ts"
printf '// bang-guard: managed extension\n' > "$legacy/pi/extensions/bang-guard.ts"
printf '// my own extension\n' > "$legacy/omp/extensions/bang-guard.ts"
cleanup_legacy "$legacy/bin" "$legacy/data" "$legacy/pi" "$legacy/omp" >/dev/null 2>&1
for gone in bin/omp bin/dcg bin/pi data/pi-v0.85.1 pi/extensions/dcg-pi.ts pi/extensions/bang-guard.ts; do
  [[ ! -e "$legacy/$gone" && ! -L "$legacy/$gone" ]] || { echo "Cleanup left $gone" >&2; exit 1; }
done
[[ -e "$legacy/bin/pi-omp-setup" && -e "$legacy/omp/keep.txt" && -e "$legacy/omp/extensions/bang-guard.ts" ]]
cleanup_legacy "$scratch/missing-bin" "$scratch/missing-data" "$scratch/missing-pi" "$scratch/missing-omp" >/dev/null
# Node archive selection ignores musl and unrelated artifacts.
cat > "$scratch/node.sha256" <<'SUMS'
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  node-v24.1.0-linux-x64-musl.tar.gz
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb  node-v24.1.0-linux-x64.tar.gz
cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc  node-v24.1.0-darwin-arm64.tar.gz
SUMS
[[ $(node_asset linux x64 tar.gz "$scratch/node.sha256") == node-v24.1.0-linux-x64.tar.gz ]]
[[ $(node_asset darwin arm64 tar.gz "$scratch/node.sha256") == node-v24.1.0-darwin-arm64.tar.gz ]]
[[ -z $(node_asset linux arm64 tar.gz "$scratch/node.sha256") ]]
[[ $(sq "a b'c") == "'a b'\\''c'" ]]
bash -n "$repo/install.sh"
cat "$repo/install.sh" | bash -s -- --plan > "$scratch/plan"
[[ $(wc -l < "$scratch/plan") -eq 3 ]]
echo 'Installer architecture, checksum rejection, and mock download checks passed.'
