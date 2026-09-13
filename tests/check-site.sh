#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"

for file in index.html styles.css script.js; do
  if [[ ! -f "$root/$file" ]]; then
    echo "FAIL: missing $file"
    exit 1
  fi
done

if ! grep -q "DevOps Training" "$root/index.html"; then
  echo "FAIL: index.html does not contain 'DevOps Training'"
  exit 1
fi

if ! grep -q "CI/CD Deployment Successful" "$root/index.html"; then
  echo "FAIL: index.html does not contain expected success message"
  exit 1
fi

if ! grep -Eq "Version: [0-9]+\.[0-9]+" "$root/index.html"; then
  echo "FAIL: index.html does not contain a Version string"
  exit 1
fi

echo "PASS: static site checks succeeded"
