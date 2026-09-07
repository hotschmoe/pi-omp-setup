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
bash -n "$repo/install.sh"
cat "$repo/install.sh" | bash -s -- --plan > "$scratch/plan"
[[ $(wc -l < "$scratch/plan") -eq 3 ]]
echo 'Installer architecture, checksum rejection, and mock download checks passed.'
