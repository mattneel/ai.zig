#!/usr/bin/env bash
set -euo pipefail

version=${1:-}
changelog=${2:-CHANGELOG.md}

if [[ -z "$version" ]]; then
  echo "usage: $0 <version> [changelog]" >&2
  exit 2
fi

if [[ ! -f "$changelog" ]]; then
  echo "changelog not found: $changelog" >&2
  exit 1
fi

awk -v heading="## [$version]" '
  /^## / {
    if (printing) exit
    if (index($0, heading) == 1) {
      suffix = substr($0, length(heading) + 1)
      if (suffix == "" || substr(suffix, 1, 1) == " ") {
        found = 1
        printing = 1
        next
      }
    }
  }
  printing { print }
  END {
    if (!found) {
      print "missing changelog section for " heading > "/dev/stderr"
      exit 1
    }
  }
' "$changelog"
