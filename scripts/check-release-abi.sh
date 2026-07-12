#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repository=${AI_ZIG_REPOSITORY:-mattneel/ai.zig}
api_url=${AI_ZIG_RELEASE_API_URL:-https://api.github.com/repos/${repository}/releases/latest}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

release_json="$work_dir/release.json"
http_status=$(curl --silent --show-error --location \
  --output "$release_json" --write-out '%{http_code}' "$api_url")

if [[ "$http_status" == "404" ]]; then
  echo "::notice title=ABI compatibility::No published release exists yet; cross-release ABI compatibility is skipped."
  exit 0
fi

if [[ "$http_status" != "200" ]]; then
  echo "GitHub latest-release request returned HTTP $http_status" >&2
  cat "$release_json" >&2
  exit 1
fi

release_record=$(python - "$release_json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    release = json.load(handle)

tag = release.get("tag_name", "")
version = tag.removeprefix("v")
expected = f"ai_zig-{version}.tar.gz"
for asset in release.get("assets", []):
    if asset.get("name") == expected:
        print(tag)
        print(expected)
        print(asset["browser_download_url"])
        break
else:
    raise SystemExit(f"latest release {tag!r} has no {expected!r} source asset")
PY
)

mapfile -t release_fields <<<"$release_record"
release_tag=${release_fields[0]}
asset_name=${release_fields[1]}
asset_url=${release_fields[2]}
asset_path="$work_dir/$asset_name"

echo "Checking current C ABI against latest published release $release_tag"
curl --fail --silent --show-error --location --retry 3 \
  --output "$asset_path" "$asset_url"

old_tree="$work_dir/old"
mkdir -p "$old_tree"
tar -xzf "$asset_path" -C "$old_tree"
mapfile -t source_roots < <(find "$old_tree" -mindepth 1 -maxdepth 1 -type d -print)
if [[ ${#source_roots[@]} -ne 1 ]]; then
  echo "expected one source root in $asset_name, found ${#source_roots[@]}" >&2
  exit 1
fi

old_root=${source_roots[0]}
old_header="$old_root/include/ai.h"
old_client="$old_root/src/ffi/abi_v1_snapshot_client.c"
old_header_client="$old_root/src/ffi/header_smoke.c"
for required in "$old_header" "$old_client" "$old_header_client"; do
  if [[ ! -f "$required" ]]; then
    echo "release source is missing ${required#"$old_root/"}" >&2
    exit 1
  fi
done

cd "$repo_root"
zig build --summary all

current_lib="$repo_root/zig-out/lib"
snapshot_bin="$work_dir/abi-v1-snapshot-client"
header_bin="$work_dir/abi-v1-header-client"

zig cc -std=c11 "$old_client" -I"$old_root/include" -L"$current_lib" \
  -Wl,-rpath,"$current_lib" -lai -o "$snapshot_bin"
zig cc -std=c11 "$old_header_client" -I"$old_root/include" -L"$current_lib" \
  -Wl,-rpath,"$current_lib" -lai -o "$header_bin"

LD_LIBRARY_PATH="$current_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$snapshot_bin"
LD_LIBRARY_PATH="$current_lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$header_bin"

echo "Old $release_tag header and clients run successfully against the current library."
