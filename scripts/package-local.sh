#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/manifest.yaml"
PYPROJECT_PATH="$ROOT_DIR/pyproject.toml"
UV_LOCK_PATH="$ROOT_DIR/uv.lock"
DIST_DIR="$ROOT_DIR/dist"

if ! command -v dify >/dev/null 2>&1; then
  echo "dify command not found in PATH" >&2
  exit 1
fi

read_manifest_field() {
  local field="$1"

  python3 - "$MANIFEST_PATH" "$field" <<'PY'
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
field = sys.argv[2]
pattern = re.compile(rf'^{re.escape(field)}:\s*"?([^"\n]+)"?\s*$', re.MULTILINE)
content = manifest_path.read_text(encoding="utf-8")
match = pattern.search(content)
if not match:
    raise SystemExit(f"missing field: {field}")
print(match.group(1))
PY
}

read_pyproject_version() {
  python3 - "$PYPROJECT_PATH" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
match = re.search(r'^version = "([^"]+)"\s*$', content, re.MULTILINE)
if not match:
    raise SystemExit("missing project version in pyproject.toml")
print(match.group(1))
PY
}

read_uv_lock_project_version() {
  python3 - "$UV_LOCK_PATH" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
content = path.read_text(encoding="utf-8")
match = re.search(
    r'(?ms)^\[\[package\]\]\nname = "dify-yuhe-openai"\nversion = "([^"]+)"',
    content,
)
if not match:
    raise SystemExit('missing project package version in uv.lock')
print(match.group(1))
PY
}

read_synced_project_version() {
  local manifest_version
  local pyproject_version
  local uv_lock_version

  manifest_version="$(read_manifest_field version)"
  pyproject_version="$(read_pyproject_version)"
  uv_lock_version="$(read_uv_lock_project_version)"

  if [[ "$manifest_version" != "$pyproject_version" || "$manifest_version" != "$uv_lock_version" ]]; then
    {
      echo "project version is not synchronized:"
      echo "  manifest.yaml: $manifest_version"
      echo "  pyproject.toml: $pyproject_version"
      echo "  uv.lock: $uv_lock_version"
    } >&2
    exit 1
  fi

  echo "$manifest_version"
}

version_to_digits() {
  local version="$1"

  python3 - "$version" <<'PY'
import re
import sys

current = sys.argv[1].strip()
if not re.fullmatch(r"\d+(?:\.\d+)+", current):
    raise SystemExit(f"manifest version is not numeric dot-version: {current}")
parts = current.split(".")
if any(len(part) > 2 for part in parts):
    raise SystemExit(f"each manifest version segment must be at most 2 digits: {current}")
print("".join(parts))
PY
}

PLUGIN_NAME="$(read_manifest_field name)"
PLUGIN_VERSION="$(read_synced_project_version)"
PLUGIN_VERSION_DIGITS="$(version_to_digits "$PLUGIN_VERSION")"
OUTPUT_FILE="$DIST_DIR/${PLUGIN_NAME}_${PLUGIN_VERSION_DIGITS}.difypkg"
LEGACY_OUTPUT_FILE="$DIST_DIR/${PLUGIN_NAME}_${PLUGIN_VERSION}.difypkg"

mkdir -p "$DIST_DIR"

tmp_dir="$(mktemp -d)"
tmp_file="$tmp_dir/${PLUGIN_NAME}_${PLUGIN_VERSION_DIGITS}.difypkg"

cleanup() {
  rm -rf "$tmp_dir"
}

trap cleanup EXIT

echo "Packaging ${PLUGIN_NAME} ${PLUGIN_VERSION}"
echo "Version token: ${PLUGIN_VERSION_DIGITS}"
echo "Output: $OUTPUT_FILE"

dify plugin package "$ROOT_DIR" -o "$tmp_file"
if [[ "$LEGACY_OUTPUT_FILE" != "$OUTPUT_FILE" ]]; then
  rm -f "$LEGACY_OUTPUT_FILE"
fi
mv "$tmp_file" "$OUTPUT_FILE"

checksum="$(
  dify plugin checksum "$ROOT_DIR" 2>/dev/null \
    | sed -n 's/.*checksum=//p' \
    | tail -n 1
)"

echo "Done: $OUTPUT_FILE"
if [[ -n "$checksum" ]]; then
  echo "Checksum: $checksum"
fi
