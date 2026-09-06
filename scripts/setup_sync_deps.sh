#!/bin/bash
# =============================================================================
# scripts/setup_sync_deps.sh — import the third-party sources named in
# dependencies/dependencies.repos, apply the overlay files, and optionally run
# rosdep. `setup_sync_deps.sh --help` carries the flags; the knobs are
# SYNC_TARGET_DIR and the DEVKIT_*_ALLOW_FAILURE pair (see .env.example).
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
# Resolve before anything is created or destroyed here: the fence below compares
# against the workspace, and 'src/thirdparty/../../../outside' passed a string
# prefix test while pointing at another tree entirely.
TARGET_DIR="$(devkit_resolve_path "$TARGET_DIR")"
# bash 3.2 (macOS) has no ${var,,}.
_devkit_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

_truthy() { case "$(_devkit_lower "$1")" in 1|true|yes|on) return 0 ;; *) return 1 ;; esac; }

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

# 'git clean -ffdx' outside the workspace is a foot-gun. Checked BEFORE the
# directory is created or imported into, on the resolved path.
if [ "$FORCE_MODE" = true ]; then
    # No blanket /tmp exemption: DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET is the
    # explicit opt-in, and a wildcard for one directory made the fence advisory.
    case "${TARGET_DIR}/" in
        "$(devkit_resolve_path "$WS_ROOT")"/*) ;;
        *)  if ! _truthy "${DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET:-false}"; then
                log_error "--force would 'git clean -ffdx' outside the workspace: ${TARGET_DIR}"
                log_error "Set DEVKIT_ALLOW_EXTERNAL_SYNC_TARGET=1 to allow."
                exit 2
            fi ;;
    esac
fi

mkdir -p "$TARGET_DIR"

# =============================================================================
# 1. VCS Repository Import + Pull + Submodule Update
# =============================================================================
print_section "VCS Repository Import"

# Block-format .repos lint: releases require a full commit hash; development
# may use tags or branches. Omitted versions resolve the remote default branch.
if [ -f "$REPOS_FILE" ]; then
    # PyYAML when it is there (vcstool depends on it, so a real import brings
    # it): flow style, any indentation and unknown fields all parse correctly.
    if python3 -c 'import yaml' 2>/dev/null; then
        UNPINNED="$(python3 - "$REPOS_FILE" <<'PYLINT' || echo "    ! .repos could not be parsed"
import re, sys, yaml
try:
    # BaseLoader keeps every scalar a string: safe_load turns an all-digit
    # commit hash into an int and a leading-zero one loses its zeros.
    doc = yaml.load(open(sys.argv[1]), Loader=yaml.BaseLoader) or {}
except yaml.YAMLError as exc:
    print(f"    ! .repos is not valid YAML: {exc}"); raise SystemExit(0)
repos = doc.get("repositories") or {}
if not isinstance(repos, dict):
    print("    ! 'repositories:' is not a mapping"); raise SystemExit(0)
for name, spec in repos.items():
    version = spec.get("version") if isinstance(spec, dict) else None
    version = "" if version is None else str(version)
    if not re.fullmatch(r"[0-9a-fA-F]{40}", version):
        print(f"    - {name} -> {version or '<missing version>'}")
PYLINT
)"
    else
        # No parser: read what we can and FAIL CLOSED. An unreadable structure
        # is not proof that a dependency is pinned, and letting it through is
        # how `version: main` in flow style reached a release build.
        UNPINNED="$(awk '
            function check() {
                if (repo != "" && (length(v) != 40 || tolower(v) ~ /[^0-9a-f]/))
                    print "    - " repo " -> " (v == "" ? "<missing version>" : v)
            }
            /^[[:space:]]*(#.*)?$/ { next }
            /^repositories:[[:space:]]*(\{\})?[[:space:]]*(#.*)?$/ { next }
            /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ {
                check(); repo = $1; sub(/:$/, "", repo); v = ""; next
            }
            /^[[:space:]]+version:/ {
                v = $0; sub(/^[[:space:]]+version:[[:space:]]*/, "", v)
                sub(/[[:space:]]+#.*/, "", v); sub(/[[:space:]]+$/, "", v)
                gsub(/[\042\047]/, "", v)
                next
            }
            repo != "" && /^    [^[:space:]#][^:]*:/ { next }   # any other field
            { print "    ! unreadable without a YAML parser, line " NR ": " $0 }
            END { check() }' "$REPOS_FILE")"
    fi
    LAYOUT="$(grep '^    ! ' <<< "$UNPINNED" || true)"
    UNPINNED="$(grep -v '^    ! ' <<< "$UNPINNED" || true)"
    if [ -n "$LAYOUT" ]; then
        log_warn "Lines this pin check could not read:"
        echo "$LAYOUT"
        # Fail closed: unread is not the same as pinned.
        [ "${DEVKIT_REQUIRE_PINNED:-0}" != "1" ] || {
            log_error "DEVKIT_REQUIRE_PINNED=1 and the .repos file could not be fully read."
            log_info "Install python3-yaml so the pin check can parse it, or simplify the file."
            exit 1; }
    fi
    if [ -n "$UNPINNED" ]; then
        if [ "${DEVKIT_REQUIRE_PINNED:-0}" = "1" ]; then
            log_error "Unpinned repositories, and DEVKIT_REQUIRE_PINNED=1:"
            echo "$UNPINNED"
            log_info "Pin them to full commit hashes, or set DEVKIT_REQUIRE_PINNED=0."
            exit 1
        fi
        log_warn "Unpinned repositories (tags and branches can move):"
        echo "$UNPINNED"
        log_info "Pin them to full commit hashes for reproducible builds."
    fi
fi

# One answer for "does this .repos declare anything", used by every branch
# below. Matching only a line that STARTS with url: missed flow style; matching
# any url: counted the commented-out example in the shipped template, which made
# every stock workspace demand vcstool. Drop comment lines, then look for a url.
repos_declared() {
    [ -f "$REPOS_FILE" ] \
        && grep -vE '^[[:space:]]*#' "$REPOS_FILE" \
        | grep -qE '(^|[[:space:],{])url:[[:space:]]*[^[:space:]]'
}

if ! command -v vcs >/dev/null 2>&1; then
    if repos_declared; then
        log_error "dependencies.repos is populated but vcstool is missing. Add python3-vcstool to dependencies/apt.txt."
        exit 1
    fi
    log_info "No external repositories to import."
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
