#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/manifest.yaml"
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

existing_release_versions() {
  {
    git -C "$ROOT_DIR" tag -l 'v*' | sed 's/^v//'
    if git -C "$ROOT_DIR" remote get-url origin >/dev/null 2>&1; then
      git -C "$ROOT_DIR" ls-remote --tags --refs origin 'v*' 2>/dev/null | sed 's#.*refs/tags/v##'
    fi
  } | awk 'NF' | sort -u
}

ensure_version_is_publishable() {
  local current_version="$1"
  local versions
  versions="$(existing_release_versions || true)"

  EXISTING_RELEASE_VERSIONS="$versions" python3 - "$current_version" <<'PY'
import os
import re
import sys

current = sys.argv[1].strip()
versions = [line.strip() for line in os.environ.get("EXISTING_RELEASE_VERSIONS", "").splitlines() if line.strip()]

def parse(version: str):
    if not re.fullmatch(r"\d+(?:\.\d+)+", version):
        return None
    return tuple(int(part) for part in version.split("."))

def bump_patch(version: str):
    parts = version.split(".")
    parts[-1] = str(int(parts[-1]) + 1)
    return ".".join(parts)

current_key = parse(current)
if current_key is None:
    raise SystemExit(f"manifest version is not numeric dot-version: {current}")

parsed_versions = [(version, parse(version)) for version in versions]
parsed_versions = [(version, key) for version, key in parsed_versions if key is not None]

latest = None
if parsed_versions:
    latest = max(parsed_versions, key=lambda item: item[1])[0]

current_exists = any(version == current for version, _ in parsed_versions)
if current_exists or (latest is not None and current_key <= parse(latest)):
    base = latest if latest is not None and parse(latest) >= current_key else current
    suggestion = bump_patch(base)
    message = [
        f"Current manifest version {current} is already released or not ahead of the latest released version.",
    ]
    if latest is not None:
        message.append(f"Latest released version: {latest}")
    if current_exists:
        message.append(f"Current version already exists: {current}")
    message.append(f"Suggested next version: {suggestion}")
    raise SystemExit("\n".join(message))
PY
}

PLUGIN_NAME="$(read_manifest_field name)"
PLUGIN_VERSION="$(read_manifest_field version)"
OUTPUT_FILE="$DIST_DIR/${PLUGIN_NAME}_${PLUGIN_VERSION}.difypkg"

ensure_version_is_publishable "$PLUGIN_VERSION"

mkdir -p "$DIST_DIR"

tmp_dir="$(mktemp -d)"
tmp_file="$tmp_dir/${PLUGIN_NAME}_${PLUGIN_VERSION}.difypkg"

cleanup() {
  rm -rf "$tmp_dir"
}

trap cleanup EXIT

echo "Packaging ${PLUGIN_NAME} ${PLUGIN_VERSION}"
echo "Output: $OUTPUT_FILE"

dify plugin package "$ROOT_DIR" -o "$tmp_file"
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
