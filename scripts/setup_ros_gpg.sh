#!/bin/bash
# =============================================================================
# scripts/setup_ros_gpg.sh — verify, and on request update, the ROS repository
# GPG fingerprint pinned in scripts/util_apt_helper.sh (`make update-gpg`).
# =============================================================================

set -eo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/../config/util_paths.sh" 2>/dev/null || { echo "  [ERROR] Cannot load config/util_paths.sh (broken checkout?)" >&2; exit 1; }  # host-only: never fall back to world-writable /tmp
devkit_require "util_logging.sh"
LOG_PREFIX="[GPG Update]"

TARGET_FILE="${WS_SCRIPTS}/util_apt_helper.sh"
[ ! -f "$TARGET_FILE" ] && TARGET_FILE="$(dirname "${BASH_SOURCE[0]}")/util_apt_helper.sh"

ROS_KEY_URL="https://raw.githubusercontent.com/ros/rosdistro/master/ros.key"
ROS_ASC_URL="https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc"

usage() {
    cat <<'EOF'
Usage: setup_ros_gpg.sh [--check|--update]

Verify the ROS repository GPG fingerprint used by util_apt_helper.sh.

Options:
  --check    Exit non-zero if the recorded fingerprint is stale.
  --update   Update util_apt_helper.sh without an interactive prompt.
  -h, --help Show this help.
EOF
}

# Command line arguments
CHECK_ONLY=false
AUTO_UPDATE=false
for arg in "$@"; do
    case $arg in
        --check) CHECK_ONLY=true ;;
        --update) AUTO_UPDATE=true ;;
        -h|--help) usage; exit 0 ;;
        *) log_error "Unknown option: $arg"; usage >&2; exit 2 ;;
    esac
done

fetch_fingerprint() {
    local url=$1
    local tmp_key
    tmp_key=$(mktemp "${TMPDIR:-/tmp}/devkit-ros-key.XXXXXX")

    if ! curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$url" -o "$tmp_key"; then
        rm -f "$tmp_key"
        log_error "Failed to download key from $url"
        return 1
    fi

    local fp
    fp=$(gpg --with-colons --import-options show-only --import "$tmp_key" 2>/dev/null | awk -F: '/^fpr/{print $10; exit}')
    rm -f "$tmp_key"
    if [ -z "$fp" ]; then
        log_error "Downloaded key has no readable fingerprint: $url"
        return 1
    fi
    echo "$fp"
}

log_info "Fetching current ROS GPG key fingerprints..."
FP_KEY=$(fetch_fingerprint "$ROS_KEY_URL" || true)
FP_ASC=$(fetch_fingerprint "$ROS_ASC_URL" || true)

if [ -z "$FP_KEY" ] || [ -z "$FP_ASC" ]; then
    log_error "Could not retrieve fingerprints from official sources. Check your internet connection."
    exit 1
fi

if [ "$FP_KEY" != "$FP_ASC" ]; then
    log_warn "Fingerprints for ros.key and ros.asc do not match!"
    log_warn "  ros.key (ROS 2): $FP_KEY"
    log_warn "  ros.asc (ROS 1): $FP_ASC"
    log_warn "This is unexpected. Please verify manually at https://www.ros.org/reps/rep-2000.html"
fi

# We use the key fingerprint as primary (typically same as .asc)
LATEST_FP="$FP_KEY"

CURRENT_FP=$(grep "^ROS_GPG_FINGERPRINT=" "$TARGET_FILE" | cut -d'"' -f2 || true)

if [ -z "$CURRENT_FP" ]; then
    log_error "Could not find current fingerprint in $TARGET_FILE"
    exit 1
fi

if [ "$CURRENT_FP" = "$LATEST_FP" ]; then
    log_ok "Fingerprint is already up to date: $CURRENT_FP"
    exit 0
fi

log_warn "Fingerprint mismatch detected!"
log_warn "  Current (in code): $CURRENT_FP"
log_warn "  Latest (from web): $LATEST_FP"

if [ "$CHECK_ONLY" = "true" ]; then
    log_error "Check failed (GPG drift detected). Please run 'make update-gpg' locally."
    exit 1
fi

if [ "$AUTO_UPDATE" != "true" ]; then
    log_warn "This rewrites tracked source to trust a new GPG key."
    # printf, not a log verb: the answer is typed on the same line as the ask.
    printf "  Update the fingerprint in util_apt_helper.sh? [y/N]: "
    read -r ans
    if [[ ! "$ans" =~ ^[yY]$ ]]; then
        log_info "Update cancelled by user."
        exit 0
    fi
fi

log_info "Updating $TARGET_FILE..."
tmp_target=$(mktemp "${TMPDIR:-/tmp}/devkit-gpg-update.XXXXXX")
sed "s/^ROS_GPG_FINGERPRINT=\"$CURRENT_FP\"/ROS_GPG_FINGERPRINT=\"$LATEST_FP\"/" "$TARGET_FILE" > "$tmp_target"
cat "$tmp_target" > "$TARGET_FILE"
rm -f "$tmp_target"

log_ok "Fingerprint successfully updated to $LATEST_FP"
