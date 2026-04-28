#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST_PATH="$ROOT_DIR/manifest.yaml"
PYPROJECT_PATH="$ROOT_DIR/pyproject.toml"
UV_LOCK_PATH="$ROOT_DIR/uv.lock"
PACKAGE_SCRIPT="$ROOT_DIR/scripts/package-local.sh"
ORIGIN_REMOTE="origin"
TEMP_BRANCH=""
TEMP_BRANCH_PUSHED=0

cleanup() {
  local exit_code=$?

  if [[ "$TEMP_BRANCH_PUSHED" -eq 1 && -n "$TEMP_BRANCH" ]]; then
    git -C "$ROOT_DIR" push "$ORIGIN_REMOTE" ":refs/heads/$TEMP_BRANCH" >/dev/null 2>&1 || true
  fi

  exit "$exit_code"
}

trap cleanup EXIT

require_command() {
  local cmd="$1"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "$cmd command not found in PATH" >&2
    exit 1
  fi
}

for cmd in dify gh git python3; do
  require_command "$cmd"
done

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

require_clean_worktree() {
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    echo "git worktree is not clean, please commit or stash changes first" >&2
    git -C "$ROOT_DIR" status --short >&2
    exit 1
  fi
}

validate_release_version() {
  local version="$1"

  python3 - "$version" <<'PY'
import re
import sys

current = sys.argv[1].strip()
if not re.fullmatch(r"\d+(?:\.\d+)+", current):
    raise SystemExit(f"release version is not numeric dot-version: {current}")
parts = current.split(".")
if any(len(part) > 2 for part in parts):
    raise SystemExit(f"each release version segment must be at most 2 digits: {current}")
print(current)
PY
}

version_to_digits() {
  local version="$1"

  version="$(validate_release_version "$version")"
  python3 - "$version" <<'PY'
import sys

print("".join(sys.argv[1].strip().split(".")))
PY
}

bump_patch() {
  local version="$1"

  python3 - "$version" <<'PY'
import sys

parts = sys.argv[1].strip().split(".")
parts[-1] = str(int(parts[-1]) + 1)
print(".".join(parts))
PY
}

latest_known_version() {
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

candidates = [current]
candidates.extend(version for version in versions if parse(version) is not None)

latest = max(candidates, key=parse)
print(latest)
PY
}

existing_release_versions() {
  {
    git -C "$ROOT_DIR" tag -l 'v*' | sed 's/^v//'
    if git -C "$ROOT_DIR" remote get-url "$ORIGIN_REMOTE" >/dev/null 2>&1; then
      git -C "$ROOT_DIR" ls-remote --tags --refs "$ORIGIN_REMOTE" 'v*' 2>/dev/null | sed 's#.*refs/tags/v##'
    fi
  } | awk 'NF' | sort -u
}

ensure_target_version_is_publishable() {
  local current_version="$1"
  local target_version="$2"
  local versions
  versions="$(existing_release_versions || true)"

  EXISTING_RELEASE_VERSIONS="$versions" python3 - "$current_version" "$target_version" <<'PY'
import os
import re
import sys

current = sys.argv[1].strip()
target = sys.argv[2].strip()
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
target_key = parse(target)
if current_key is None:
    raise SystemExit(f"current project version is not numeric dot-version: {current}")
if target_key is None:
    raise SystemExit(f"target release version is not numeric dot-version: {target}")

parsed_versions = [parse(version) for version in versions if parse(version) is not None]
latest = max(parsed_versions) if parsed_versions else None

if target_key <= current_key:
    raise SystemExit(
        "\n".join(
            [
                f"target release version must be greater than current project version: {current}",
                f"Suggested next version: {bump_patch(max([current], key=parse))}",
            ]
        )
    )

if target in versions:
    base = max([target, current] + versions, key=parse)
    raise SystemExit(
        "\n".join(
            [
                f"target release version already exists: {target}",
                f"Suggested next version: {bump_patch(base)}",
            ]
        )
    )

if latest is not None and target_key <= latest:
    latest_text = ".".join(str(part) for part in latest)
    raise SystemExit(
        "\n".join(
            [
                f"target release version must be greater than latest released version: {latest_text}",
                f"Suggested next version: {bump_patch(latest_text)}",
            ]
        )
    )
PY
}

parse_github_repo() {
  local remote_url="$1"

  python3 - "$remote_url" <<'PY'
import re
import sys

remote_url = sys.argv[1].strip()
patterns = [
    r"^git@github\.com:(?P<repo>[^/]+/[^/]+?)(?:\.git)?$",
    r"^https://github\.com/(?P<repo>[^/]+/[^/]+?)(?:\.git)?$",
    r"^ssh://git@github\.com/(?P<repo>[^/]+/[^/]+?)(?:\.git)?$",
]
for pattern in patterns:
    match = re.match(pattern, remote_url)
    if match:
        print(match.group("repo"))
        raise SystemExit(0)
raise SystemExit(f"unsupported GitHub remote URL: {remote_url}")
PY
}

select_release_version() {
  local current_version="$1"
  local requested_version="${2:-}"
  local default_version
  local chosen_version

  default_version="$(bump_patch "$(latest_known_version "$current_version")")"

  if [[ -n "$requested_version" ]]; then
    chosen_version="$requested_version"
  elif [[ -t 0 ]]; then
    read -r -p "Release version [${default_version}]: " chosen_version
    chosen_version="${chosen_version:-$default_version}"
  else
    chosen_version="$default_version"
  fi

  validate_release_version "$chosen_version" >/dev/null
  echo "$chosen_version"
}

update_project_versions() {
  local target_version="$1"

  python3 - "$MANIFEST_PATH" "$PYPROJECT_PATH" "$UV_LOCK_PATH" "$target_version" <<'PY'
import pathlib
import re
import sys

manifest_path = pathlib.Path(sys.argv[1])
pyproject_path = pathlib.Path(sys.argv[2])
uv_lock_path = pathlib.Path(sys.argv[3])
target_version = sys.argv[4]

def replace_single(path: pathlib.Path, pattern: str, repl: str, flags: int = 0) -> None:
    content = path.read_text(encoding="utf-8")
    updated, count = re.subn(pattern, repl, content, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"failed to update version in {path}")
    path.write_text(updated, encoding="utf-8")

replace_single(
    manifest_path,
    r'^version:\s*[^\n]+\s*$',
    f'version: {target_version}',
    re.MULTILINE,
)
replace_single(
    pyproject_path,
    r'^version = "[^"]+"\s*$',
    f'version = "{target_version}"',
    re.MULTILINE,
)
replace_single(
    uv_lock_path,
    r'(?ms)(^\[\[package\]\]\nname = "dify-yuhe-openai"\nversion = ")([^"]+)(")',
    rf'\g<1>{target_version}\g<3>',
)
PY
}

current_git_branch() {
  local branch

  branch="$(git -C "$ROOT_DIR" symbolic-ref --quiet --short HEAD || true)"
  if [[ -z "$branch" ]]; then
    echo "git HEAD is detached, cannot publish from detached HEAD" >&2
    exit 1
  fi

  echo "$branch"
}

require_clean_worktree

CURRENT_VERSION="$(read_synced_project_version)"
TARGET_VERSION="$(select_release_version "$CURRENT_VERSION" "${1:-}")"
ensure_target_version_is_publishable "$CURRENT_VERSION" "$TARGET_VERSION"

PLUGIN_NAME="$(read_manifest_field name)"
PLUGIN_VERSION_DIGITS="$(version_to_digits "$TARGET_VERSION")"
RELEASE_TAG="v${TARGET_VERSION}"
PACKAGE_FILE="$ROOT_DIR/dist/${PLUGIN_NAME}_${PLUGIN_VERSION_DIGITS}.difypkg"
REMOTE_URL="$(git -C "$ROOT_DIR" remote get-url "$ORIGIN_REMOTE")"
GITHUB_REPO="$(parse_github_repo "$REMOTE_URL")"
CURRENT_BRANCH="$(current_git_branch)"

echo "Current version: $CURRENT_VERSION"
echo "Target version: $TARGET_VERSION"
echo "Repository: $GITHUB_REPO"
echo "Branch: $CURRENT_BRANCH"

update_project_versions "$TARGET_VERSION"

if [[ "$(read_synced_project_version)" != "$TARGET_VERSION" ]]; then
  echo "failed to verify synchronized project version after update" >&2
  exit 1
fi

git -C "$ROOT_DIR" add "$MANIFEST_PATH" "$PYPROJECT_PATH" "$UV_LOCK_PATH"
git -C "$ROOT_DIR" commit -m "release: prepare v${TARGET_VERSION}"

"$PACKAGE_SCRIPT"

if [[ ! -f "$PACKAGE_FILE" ]]; then
  echo "package not found after build: $PACKAGE_FILE" >&2
  exit 1
fi

RELEASE_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
TEMP_BRANCH="release-tmp/${PLUGIN_NAME}-v${PLUGIN_VERSION_DIGITS}-$(date +%Y%m%d%H%M%S)"

echo "Publishing release tag: $RELEASE_TAG"
echo "Release commit: $RELEASE_COMMIT"
echo "Package asset: $PACKAGE_FILE"
echo "Temporary remote branch: $TEMP_BRANCH"

git -C "$ROOT_DIR" push "$ORIGIN_REMOTE" "HEAD:refs/heads/$TEMP_BRANCH"
TEMP_BRANCH_PUSHED=1

gh release create \
  "$RELEASE_TAG" \
  "$PACKAGE_FILE" \
  --repo "$GITHUB_REPO" \
  --target "$RELEASE_COMMIT" \
  --title "$RELEASE_TAG" \
  --notes "Plugin package for ${PLUGIN_NAME} ${TARGET_VERSION}"

git -C "$ROOT_DIR" push "$ORIGIN_REMOTE" "HEAD:refs/heads/$CURRENT_BRANCH"
git -C "$ROOT_DIR" fetch --tags "$ORIGIN_REMOTE" >/dev/null 2>&1 || true
git -C "$ROOT_DIR" push "$ORIGIN_REMOTE" ":refs/heads/$TEMP_BRANCH"
TEMP_BRANCH_PUSHED=0
TEMP_BRANCH=""

echo "Release completed: $RELEASE_TAG"
echo "Branch pushed: $CURRENT_BRANCH"
