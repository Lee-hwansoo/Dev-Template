#!/bin/bash
# =============================================================================
# scripts/sync_deps.sh
# Third-party dependency source code synchronization and overlay merge tool
#
# Features:
#   1. Batch Import/Pull of external repositories via vcstool (.repos)
#   2. Merge files from dependencies/overlay/ into the target workspace
#   3. Automatic verification of missing system dependencies based on rosdep
# =============================================================================

# Load logging utility
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[Sync Deps]"

# 1. Root Directory Detection (Hierarchical)
# Container volume (/workspace) takes priority, otherwise uses script location as base
if [ -d "/workspace/dependencies" ]; then
    PROJECT_ROOT="/workspace"
else
    # Consider the parent folder of scripts/sync_deps.sh as the root
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
fi

# 2. Path Configuration (Single Source of Truth)
# Use SYNC_TARGET_DIR if injected as an environment variable, otherwise default to src/thirdparty
REPOS_FILE="${PROJECT_ROOT}/dependencies/dependencies.repos"
OVERLAY_DIR="${PROJECT_ROOT}/dependencies/overlay"
TARGET_DIR="${PROJECT_ROOT}/${SYNC_TARGET_DIR:-src/thirdparty}"

mkdir -p "$TARGET_DIR"

# 3. vcstool Integration
if ! command -v vcs &>/dev/null; then
    log_warn "vcstool (vcs) not found. Skipping repository import."
elif [ -f "$REPOS_FILE" ]; then
    log_info "Running vcs import to $TARGET_DIR ..."
    vcs import "$TARGET_DIR" < "$REPOS_FILE" || log_warn "vcs import completed with some warnings."

    # Purge any previous overlays so the git working tree is clean for pulling
    log_info "Cleaning up previous overlays in git repositories to prevent merge conflicts..."
    find "$TARGET_DIR" -type d -name ".git" -prune -execdir git reset --hard HEAD \; -execdir git clean -fd \; &>/dev/null || true

    # Update existing repositories after checking for newly added ones
    log_info "Performing vcs pull to update existing repositories..."
    vcs pull "$TARGET_DIR" || log_warn "vcs pull completed with some warnings."
else
    log_info "No .repos file found at $REPOS_FILE."
fi

# 4. Package Overlay Application
if [ -d "$OVERLAY_DIR" ]; then
    HAS_FILES=$(find "$OVERLAY_DIR" -mindepth 1 -not -name "*.md" | wc -l)
    if [ "$HAS_FILES" -gt 0 ]; then
        log_info "Applying overlays from $OVERLAY_DIR ..."
        cp -a "$OVERLAY_DIR/." "$TARGET_DIR/"
        log_ok "Overlays applied successfully."
    fi
fi

# 5. System Dependency Resolution (rosdep)
# Skipped by default; runs only when --rosdep flag is present
DO_ROSDEP=false
for arg in "$@"; do
    if [ "$arg" == "--rosdep" ]; then
        DO_ROSDEP=true
        break
    fi
done

if [ "$DO_ROSDEP" = true ] && command -v rosdep &>/dev/null && [ -n "${ROS_DISTRO}" ]; then
    log_info "Checking rosdep dependencies for ${TARGET_DIR}..."
    apt-get update -qq || true
    if ! rosdep install --from-paths "$TARGET_DIR" --ignore-src -r -y --rosdistro "$ROS_DISTRO"; then
        log_warn "Some rosdep packages failed to install. Check the output above."
    else
        log_ok "rosdep check completed."
    fi
elif [ "$DO_ROSDEP" = false ] && command -v rosdep &>/dev/null; then
    log_info "Skipping rosdep install. (Use --rosdep to force check)"
fi
