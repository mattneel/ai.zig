#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_dir="$repo_root/dist"
requested_version=""

usage() {
  cat <<'EOF'
usage: scripts/package-release.sh [--version <vX.Y.Z|X.Y.Z>] [--output <dir>]

Build all release targets, assemble archives, create the pruned Zig source
tarball and Python sdist, and write HASHES.txt plus SHA256SUMS.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      requested_version=${2:-}
      shift 2
      ;;
    --output)
      output_dir=${2:-}
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cd "$repo_root"
package_version=$(awk -F'"' '/^[[:space:]]*\.version = "/ { print $2; exit }' build.zig.zon)
version=${requested_version#v}
if [[ -z "$version" ]]; then
  version=$package_version
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "release version must be X.Y.Z or vX.Y.Z, got: ${requested_version:-<empty>}" >&2
  exit 1
fi

if [[ "$version" != "$package_version" ]]; then
  echo "release version $version does not match build.zig.zon version $package_version" >&2
  exit 1
fi

output_dir=$(mkdir -p "$output_dir" && cd "$output_dir" && pwd)
find "$output_dir" -mindepth 1 -maxdepth 1 -type f -delete

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

targets=(
  x86_64-linux-gnu
  aarch64-linux-gnu
  x86_64-macos
  aarch64-macos
  x86_64-windows-gnu
  aarch64-windows-gnu
)

copy_target_libraries() {
  local target=$1
  local destination=$2
  local found_static=0
  local found_dynamic=0
  local file base
  local search_dirs=()

  [[ -d zig-out/lib ]] && search_dirs+=(zig-out/lib)
  [[ -d zig-out/bin ]] && search_dirs+=(zig-out/bin)
  if [[ ${#search_dirs[@]} -eq 0 ]]; then
    echo "zig build produced no lib or bin directory for $target" >&2
    return 1
  fi

  while IFS= read -r -d '' file; do
    base=$(basename "$file")
    case "$base" in
      libai.a)
        found_static=1
        ;;
      libai.so*|libai*.dylib|ai.dll|libai.dll)
        found_dynamic=1
        ;;
      libai.dll.a|ai.lib|libai.lib)
        ;;
      *)
        continue
        ;;
    esac
    cp -a "$file" "$destination/lib/$base"
  done < <(find "${search_dirs[@]}" -maxdepth 1 \( -type f -o -type l \) -print0 | sort -z)

  if [[ $found_static -ne 1 || $found_dynamic -ne 1 ]]; then
    echo "missing required static or shared library for $target" >&2
    return 1
  fi
  if [[ "$target" == *-linux-gnu && ! -f "$destination/lib/libai.so.1.0.0" ]]; then
    echo "missing versioned ELF library libai.so.1.0.0 for $target" >&2
    return 1
  fi
}

for target in "${targets[@]}"; do
  echo "==> Building $target"
  rm -rf zig-out
  zig build -Dtarget="$target" --summary all

  archive_root="ai-$version-$target"
  stage="$work_dir/$archive_root"
  mkdir -p "$stage/lib" "$stage/include"
  copy_target_libraries "$target" "$stage"

  if [[ ! -f zig-out/include/ai.h ]] || ! cmp -s include/ai.h zig-out/include/ai.h; then
    echo "installed ai.h is missing or differs from include/ai.h for $target" >&2
    exit 1
  fi
  cp include/ai.h "$stage/include/ai.h"
  cp LICENSE NOTICE README.md "$stage/"

  if [[ "$target" == *-windows-gnu ]]; then
    archive="$output_dir/$archive_root.zip"
    (cd "$work_dir" && zip -X -q -r "$archive" "$archive_root")
    unzip -tq "$archive" >/dev/null
  else
    archive="$output_dir/$archive_root.tar.gz"
    tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      -C "$work_dir" -cf - "$archive_root" | gzip -n >"$archive"
    tar -tzf "$archive" >/dev/null
  fi
done

mapfile -t package_paths < <(
  awk '
    /^[[:space:]]*\.paths = \.\{/ { in_paths = 1; next }
    in_paths && /^[[:space:]]*},/ { exit }
    in_paths && /^[[:space:]]*"[^"]+"[[:space:]]*,/ {
      line = $0
      sub(/^[[:space:]]*"/, "", line)
      sub(/"[[:space:]]*,.*/, "", line)
      print line
    }
  ' build.zig.zon
)

if [[ ${#package_paths[@]} -eq 0 ]]; then
  echo "could not read build.zig.zon .paths" >&2
  exit 1
fi

source_root_name="ai_zig-$version"
source_parent="$work_dir/source"
source_root="$source_parent/$source_root_name"
mkdir -p "$source_root"
for path in "${package_paths[@]}"; do
  if [[ ! -e "$path" ]]; then
    echo "build.zig.zon .paths entry does not exist: $path" >&2
    exit 1
  fi
  mkdir -p "$source_root/$(dirname "$path")"
  cp -a "$path" "$source_root/$path"
done

source_asset="$output_dir/$source_root_name.tar.gz"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  -C "$source_parent" -cf - "$source_root_name" | gzip -n >"$source_asset"
tar -tzf "$source_asset" >/dev/null

while IFS= read -r member; do
  relative=${member#"$source_root_name"}
  relative=${relative#/}
  relative=${relative%/}
  [[ -z "$relative" ]] && continue
  allowed=0
  for path in "${package_paths[@]}"; do
    if [[ "$relative" == "$path" || "$relative" == "$path/"* ]]; then
      allowed=1
      break
    fi
  done
  if [[ $allowed -ne 1 ]]; then
    echo "source archive contains path outside build.zig.zon .paths: $relative" >&2
    exit 1
  fi
done < <(tar -tzf "$source_asset")

python_dist="$work_dir/python-dist"
python -m build --sdist --outdir "$python_dist" bindings/python
python_sdist="$python_dist/ai_zig-$version.tar.gz"
if [[ ! -f "$python_sdist" ]]; then
  echo "Python build did not produce ai_zig-$version.tar.gz" >&2
  exit 1
fi
cp "$python_sdist" "$output_dir/ai_zig_python-$version.tar.gz"

zig_exe=$(zig env | awk -F'"' '/^[[:space:]]*\.zig_exe =/ { print $2; exit }')
if [[ ! -x "$zig_exe" ]]; then
  echo "could not resolve the Zig compiler executable" >&2
  exit 1
fi
zig_hash=$(
  cd "$source_root"
  "$zig_exe" fetch --global-cache-dir "$work_dir/zig-fetch-cache" "$source_asset"
)
zig_hash=${zig_hash//$'\r'/}
zig_hash=${zig_hash//$'\n'/}
if [[ -z "$zig_hash" ]]; then
  echo "zig fetch did not return a package hash" >&2
  exit 1
fi

cat >"$output_dir/HASHES.txt" <<EOF
# Zig package hash (computed by Zig 0.16.0 fetch)
$zig_hash  $(basename "$source_asset")
EOF

(
  cd "$output_dir"
  find . -mindepth 1 -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' \
    | LC_ALL=C sort \
    | xargs sha256sum >SHA256SUMS
)

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Zig package hash"
    echo
    echo "\`$zig_hash\`"
    echo
    echo "Computed from \`$(basename "$source_asset")\` with Zig 0.16.0."
  } >>"$GITHUB_STEP_SUMMARY"
fi

echo "==> Release assets"
(cd "$output_dir" && find . -mindepth 1 -maxdepth 1 -type f -printf '%f\t%s bytes\n' | LC_ALL=C sort)
echo "==> Zig package hash: $zig_hash"
