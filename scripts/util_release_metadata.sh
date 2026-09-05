#!/bin/bash
# =============================================================================
# scripts/util_release_metadata.sh — the manifest a baked artifact carries:
# template revision, reproducibility inputs and the resolved apt/pip sets.
# =============================================================================

set -euo pipefail

# The path SSOT (WS_VENV_PY, WS_ROOT) and the log verbs, before anything that
# reports. Sourced explicitly: a `docker build` RUN layer runs before the
# entrypoint writes the BASH_ENV file, so nothing has exported these yet.
# Best-effort — metadata must never fail a build; util_paths.sh stubs the verbs.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || true
devkit_require "util_logging.sh" 2>/dev/null || true
LOG_PREFIX="[Release Meta]"

usage() {
    cat <<'EOF'
Usage: util_release_metadata.sh [output_file]

Generate release metadata JSON for baked/runtime artifacts.
Set SOURCE_DATE_EPOCH to produce a reproducible build_date.
Set DEVKIT_BUILD_DATE to override build_date with an explicit ISO-8601 value.
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --*) log_error "Unknown option: $1"; usage >&2; exit 2 ;;
esac

OUTPUT_FILE="${1:-${WORKSPACE_PATH:-/workspace}/release/devkit-release.json}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
    log_error "Python is required to generate release metadata: $PYTHON_BIN"
    exit 127
fi

PYTHON_VERSION="$("$PYTHON_BIN" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"

mkdir -p -- "$(dirname "$OUTPUT_FILE")"
MANIFEST_DIR="$(dirname "$OUTPUT_FILE")"

# =============================================================================
# Build manifests: record what was ACTUALLY resolved.
# -----------------------------------------------------------------------------
# Some inputs cannot be pinned upstream — packages.ros.org publishes no snapshot
# mirror, and `rosdep` resolves at build time. Recording the exact versions that
# landed in the image makes such a build auditable and re-pinnable after the
# fact: diff two manifests to see what moved, or paste a line back into
# dependencies/apt.txt as `package=version` to freeze it.
# =============================================================================
APT_MANIFEST="${MANIFEST_DIR}/devkit-apt-manifest.txt"
PIP_MANIFEST="${MANIFEST_DIR}/devkit-pip-manifest.txt"
APT_COUNT=0; PIP_COUNT=0

if command -v dpkg-query >/dev/null 2>&1; then
    dpkg-query -W -f='${Package}=${Version}\n' 2>/dev/null | LC_ALL=C sort > "$APT_MANIFEST" || true
    APT_COUNT="$(wc -l < "$APT_MANIFEST" 2>/dev/null || echo 0)"
fi

if [ -x "${WS_VENV_PY:-}" ]; then
    "${WS_VENV_PY}" -m pip freeze 2>/dev/null | LC_ALL=C sort > "$PIP_MANIFEST" || true
elif command -v uv >/dev/null 2>&1; then
    uv pip freeze 2>/dev/null | LC_ALL=C sort > "$PIP_MANIFEST" || true
fi
[ -f "$PIP_MANIFEST" ] && PIP_COUNT="$(wc -l < "$PIP_MANIFEST" 2>/dev/null || echo 0)"

# One digest over both manifests: a single value that answers "is this the same
# dependency set as the build we validated?".
MANIFEST_SHA=""
if command -v sha256sum >/dev/null 2>&1; then
    MANIFEST_SHA="$(cat "$APT_MANIFEST" "$PIP_MANIFEST" 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
fi

export OUTPUT_FILE PYTHON_VERSION APT_COUNT PIP_COUNT MANIFEST_SHA
"$PYTHON_BIN" - <<'PY'
import datetime
import json
import os
import sys


def resolve_build_date():
    explicit = os.environ.get("DEVKIT_BUILD_DATE") or os.environ.get("BUILD_DATE")
    if explicit:
        return explicit

    source_epoch = os.environ.get("SOURCE_DATE_EPOCH")
    if source_epoch:
        try:
            epoch = int(source_epoch)
        except ValueError:
            print("[ERROR] SOURCE_DATE_EPOCH must be an integer Unix timestamp.", file=sys.stderr)
            sys.exit(2)
        return (
            datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z")
        )

    return (
        datetime.datetime.now(datetime.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )

metadata = {
    "project": os.environ.get("COMPOSE_PROJECT_NAME", "unknown"),
    "image_tag": os.environ.get("IMAGE_TAG", "latest"),
    "ros_distro": os.environ.get("ROS_DISTRO", "none"),
    "python": os.environ.get("PYTHON_VERSION") or "unknown",
    "cuda_version": os.environ.get("CUDA_VERSION", ""),
    "cudnn_version": os.environ.get("CUDNN_VERSION", ""),
    "opencv_cuda": os.environ.get("OPENCV_CUDA", "auto"),
    "git_commit": os.environ.get("GIT_COMMIT", "unknown"),
    "build_date": resolve_build_date(),
    # Reproducibility inputs, recorded so a build can be audited or re-pinned.
    "base_image": os.environ.get("BASE_IMAGE", "unknown"),
    "apt_snapshot": os.environ.get("APT_SNAPSHOT_DATE", "latest"),
    "source_date_epoch": os.environ.get("SOURCE_DATE_EPOCH", ""),
    "build_type": os.environ.get("DEVKIT_BUILD_TYPE", "dev"),
    "manifest": {
        "apt_packages": int(os.environ.get("APT_COUNT") or 0),
        "pip_packages": int(os.environ.get("PIP_COUNT") or 0),
        "sha256": os.environ.get("MANIFEST_SHA", ""),
        "files": ["devkit-apt-manifest.txt", "devkit-pip-manifest.txt"],
    },
}

with open(os.environ["OUTPUT_FILE"], "w", encoding="utf-8") as handle:
    json.dump(metadata, handle, ensure_ascii=False, separators=(",", ":"))
    handle.write("\n")
PY
