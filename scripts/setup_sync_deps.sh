#!/bin/bash
# =============================================================================
# scripts/setup_sync_deps.sh
# Synchronize third-party repos via vcs (.repos) and apply overlay files.
# Usage: setup_sync_deps.sh [--force] [--rosdep]
#
# Options:
#   --force    Reset imported third-party repositories before updating.
#   --rosdep   Run rosdep install after source synchronization.
#
# Environment:
#   SYNC_TARGET_DIR                Where sources land (default: src/thirdparty).
#   DEVKIT_VCS_ALLOW_FAILURE=1     Warn instead of failing on vcs errors.
#   DEVKIT_ROSDEP_ALLOW_FAILURE=1  Warn instead of failing on rosdep errors.
# =============================================================================
set -euo pipefail

# The path SSOT first: WS_ROOT must not come from WORKSPACE_PATH directly (make
# exports the CONTAINER path to host recipes too), and the --force fence below
# compares user paths against it, so it also has to be normalized — both of
# which util_paths.sh already gets right.
source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }
devkit_require "util_logging.sh"
LOG_PREFIX="[Sync Deps]"
# Strip colour when piped/redirected or NO_COLOR is set (see util_logging.sh).
declare -F devkit_auto_color >/dev/null 2>&1 && devkit_auto_color

DEPS_DIR="${WS_ROOT}/dependencies"
REPOS_FILE="${DEPS_DIR}/dependencies.repos"
OVERLAY_DIR="${DEPS_DIR}/overlay"
# SYNC_TARGET_DIR is documented workspace-relative, so anchor it to WS_ROOT:
# left relative it follows the caller's cwd and the --force fence below (which
# compares against ${WS_ROOT}/*) rejects it.
TARGET_DIR="${SYNC_TARGET_DIR:-src/thirdparty}"
case "$TARGET_DIR" in /*) ;; *) TARGET_DIR="${WS_ROOT}/${TARGET_DIR}" ;; esac

_truthy() { case "${1,,}" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

# --- Argument parsing ---------------------------------------------------------
FORCE_MODE=false
DO_ROSDEP=false

for arg in "$@"; do
    case "$arg" in
        --force)  FORCE_MODE=true ;;
        --rosdep) DO_ROSDEP=true ;;
        -h|--help)
            echo "Usage: setup_sync_deps.sh [--force] [--rosdep]"
            echo "  --force    Reset third-party repos to HEAD before update."
            echo "  --rosdep   Run rosdep install after sync."
            exit 0 ;;
        *) log_error "Unknown option: $arg"; exit 2 ;;
    esac
done

mkdir -p "$TARGET_DIR"

# =============================================================================
# 1. VCS Repository Import + Pull + Submodule Update
# =============================================================================
print_section "VCS Repository Import"

# Reproducibility lint (static, runs even without vcstool): a branch name in
# `version:` makes the build float. Warn, never block — during development a
# branch is a legitimate choice.
if [ -f "$REPOS_FILE" ]; then
    UNPINNED="$(awk '
        /^[[:space:]]{2}[^[:space:]#]/ { repo = $1; sub(/:$/, "", repo) }
        /^[[:space:]]+version:/ {
            v = $2
            if (v !~ /^[0-9a-f]{7,40}$/ && v !~ /^v?[0-9]+\.[0-9]+/) print "    - " repo " -> " v
        }' "$REPOS_FILE" 2>/dev/null || true)"
    if [ -n "$UNPINNED" ]; then
        log_warn "Unpinned repositories (branch refs make builds non-reproducible):"
        echo "$UNPINNED"
        log_info "Pin them to a tag or full commit hash for reproducible builds."
    fi
fi

if ! command -v vcs >/dev/null 2>&1; then
    log_warn "vcstool (vcs) not found. Skipping repository import."
elif [ ! -f "$REPOS_FILE" ]; then
    log_info "No .repos file found at ${REPOS_FILE}. Skipping."
else
    log_info "Running vcs import → ${TARGET_DIR} ..."
    if ! vcs import "$TARGET_DIR" < "$REPOS_FILE"; then
        if _truthy "${DEVKIT_VCS_ALLOW_FAILURE:-false}"; then
            log_warn "vcs import failed. Continuing (DEVKIT_VCS_ALLOW_FAILURE=1)."
        else
            log_error "vcs import failed. Fix dependencies/dependencies.repos or set DEVKIT_VCS_ALLOW_FAILURE=1."
            exit 1
        fi
    fi

    # Force-reset: discard local changes in third-party repos
    if [ "$FORCE_MODE" = true ]; then
        # 'git clean -ffdx' outside the workspace is a foot-gun; refuse unless
        # the user explicitly opted in.
        case "$TARGET_DIR" in
            "${WS_ROOT}"/*|/tmp/*) ;;
            *)  if ! _truthy "${DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET:-false}"; then
                    log_error "--force would 'git clean -ffdx' outside the workspace: ${TARGET_DIR}"
                    log_error "Set DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET=1 to allow."
                    exit 2
                fi ;;
        esac
        log_warn "Force mode: resetting all third-party repos to HEAD..."
        while IFS= read -r -d '' git_dir; do
            repo_dir="$(dirname "$git_dir")"
            repo_name="$(basename "$repo_dir")"
            if ! (cd "$repo_dir" && git reset --hard HEAD && git clean -ffdx); then
                log_warn "Failed to reset: $repo_name"
            fi
        done < <(find "$TARGET_DIR" -type d -name ".git" -prune -print0)
    fi

    # Pull: only branch-tracking repos (skip detached HEAD / fixed tags)
    log_info "Running vcs pull (branch-tracking repos only)..."
    for repo_dir in "$TARGET_DIR"/*/; do
        [ -d "$repo_dir" ] || continue
        repo_name="$(basename "$repo_dir")"
        if (cd "$repo_dir" && git symbolic-ref -q HEAD >/dev/null 2>&1); then
            if ! vcs pull "$repo_dir"; then
                if _truthy "${DEVKIT_VCS_ALLOW_FAILURE:-false}"; then
                    log_warn "vcs pull failed for ${repo_name}. Continuing."
                else
                    log_error "vcs pull failed for ${repo_name}. Set DEVKIT_VCS_ALLOW_FAILURE=1 to continue."
                    exit 1
                fi
            fi
        else
            log_info "Skipping pull for ${repo_name} (fixed version / detached HEAD)."
        fi
    done

    # Submodule update
    log_info "Updating git submodules..."
    for repo_dir in "$TARGET_DIR"/*/; do
        [ -d "$repo_dir/.git" ] || [ -f "$repo_dir/.git" ] || continue
        repo_name="$(basename "$repo_dir")"
        if ! (cd "$repo_dir" && git submodule update --init --recursive); then
            if _truthy "${DEVKIT_VCS_ALLOW_FAILURE:-false}"; then
                log_warn "Submodule update failed for ${repo_name}. Continuing."
            else
                log_error "Submodule update failed for ${repo_name}. Set DEVKIT_VCS_ALLOW_FAILURE=1 to continue."
                exit 1
            fi
        fi
    done

    log_ok "VCS synchronization complete."
fi

# =============================================================================
# 2. Overlay Application
# =============================================================================
print_section "Overlay Application"
if [ -d "$OVERLAY_DIR" ]; then
    log_info "Applying overlays from ${OVERLAY_DIR} ..."
    while IFS= read -r -d '' item; do
        cp -a -- "$item" "$TARGET_DIR/"
    done < <(
        find "$OVERLAY_DIR" -mindepth 1 -maxdepth 1 \
            ! \( -name "CATKIN_IGNORE" -o -name "COLCON_IGNORE" -o -name "*.md" \) -print0
    )
    log_ok "Overlays applied."
else
    log_info "No overlay directory found. Skipping."
fi

# =============================================================================
# 3. System Dependency Resolution (rosdep)
# =============================================================================
print_section "System Dependencies (rosdep)"
if [ "$DO_ROSDEP" = true ] && command -v rosdep >/dev/null 2>&1 && [ -n "${ROS_DISTRO:-}" ]; then
    log_info "Running rosdep install for ROS ${ROS_DISTRO}..."

    # apt-get update (with sudo if non-root)
    if [ "$(id -u)" -ne 0 ] && command -v sudo >/dev/null 2>&1; then
        sudo -n apt-get update -qq 2>/dev/null || log_warn "apt-get update failed; using existing APT metadata."
    else
        apt-get update -qq 2>/dev/null || log_warn "apt-get update failed; using existing APT metadata."
    fi

    SCAN_PATHS=("${WS_ROOT}/src" "$TARGET_DIR")
    if ! rosdep install --from-paths "${SCAN_PATHS[@]}" --ignore-src -r -y --rosdistro "$ROS_DISTRO"; then
        if _truthy "${DEVKIT_ROSDEP_ALLOW_FAILURE:-false}"; then
            log_warn "rosdep install failed. Continuing (DEVKIT_ROSDEP_ALLOW_FAILURE=1)."
        else
            log_error "rosdep install failed. Set DEVKIT_ROSDEP_ALLOW_FAILURE=1 to continue."
            exit 1
        fi
    fi
    log_ok "rosdep complete."
elif [ "$DO_ROSDEP" = true ]; then
    log_info "ROS environment not detected. Skipping rosdep."
fi

echo ""
log_ok "Dependency synchronization complete."
