#!/bin/bash
# =============================================================================
# scripts/setup_ros_gpg.sh — verify, and on request update, the ROS repository
# GPG fingerprints pinned in scripts/util_apt_helper.sh (`make update-gpg`):
# the live archive key, and the separate one snapshots.ros.org signs with.
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
    log_warn "This is unexpected. Compare both against ros/rosdistro's ros.key and ros.asc,"
    log_warn "and check discourse.ros.org for a key rotation announcement."
fi

# We use the key fingerprint as primary (typically same as .asc)
LATEST_FP="$FP_KEY"

CURRENT_FP=$(grep "^ROS_GPG_FINGERPRINT=" "$TARGET_FILE" | cut -d'"' -f2 || true)

if [ -z "$CURRENT_FP" ]; then
    log_error "Could not find current fingerprint in $TARGET_FILE"
    exit 1
fi

# The snapshot archive is signed by a DIFFERENT key, and a keyserver lookup
# keyed on the fingerprint we already hold cannot discover a rotation. Verify
# from the other end: import the PINNED key into an isolated keyring and require
# gpg itself to accept a snapshot signature under it.
#
# What this proves and what it does not: foxy/final is frozen, so a pass means
# the pin still verifies THAT archive. It cannot tell you the project has not
# begun signing NEW snapshots with a different key — nothing offline can.
SNAPSHOT_PROBE_URL="${SNAPSHOT_PROBE_URL:-http://snapshots.ros.org/foxy/final/ubuntu/dists/focal/InRelease}"
SNAPSHOT_KEY_URL="${SNAPSHOT_KEY_URL:-https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x}"

# verify_signed_by <document-url> <fingerprint> -> 0 verified, 1 mismatch, 2 unverifiable
# Trusts ONLY the pinned key: it is imported into an empty keyring and the
# import itself is checked, so a keyserver that answers with something else
# cannot become the thing we verify against.
verify_signed_by() {
    local doc_url="$1" pin="$2" home doc key rc
    home="$(mktemp -d "${TMPDIR:-/tmp}/devkit-gpgh.XXXXXX")" || return 2
    chmod 700 "$home"
    doc="$(mktemp "${TMPDIR:-/tmp}/devkit-doc.XXXXXX")"
    key="$(mktemp "${TMPDIR:-/tmp}/devkit-pin.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -rf '$home' '$doc' '$key'" RETURN

    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "${SNAPSHOT_KEY_URL}${pin}" -o "$key" || return 2
    gpg --homedir "$home" --batch --quiet --import "$key" 2>/dev/null || return 2
    gpg --homedir "$home" --batch --with-colons --fingerprint 2>/dev/null \
        | awk -F: '/^fpr:/{print $10}' | grep -qx "$pin" || return 2
    curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$doc_url" -o "$doc" || return 2

    # Exit status AND a VALIDSIG naming the pin. Reading a key id out of gpg's
    # chatter is not verification — a forged document announces whatever it likes.
    local status
    status="$(gpg --homedir "$home" --batch --status-fd 1 --verify "$doc" 2>/dev/null)"; rc=$?
    [ "$rc" -eq 0 ] || return 1
    # VALIDSIG's LAST field is the PRIMARY key fingerprint, which is what the pin
    # names; the first is the signing key and may be a subkey.
    awk -v pin="$pin" '$1 == "[GNUPG:]" && $2 == "VALIDSIG" && $NF == pin { found = 1 }
                       END { exit found ? 0 : 1 }' <<< "$status" || return 1
    return 0
}

SNAPSHOT_FP=$(grep "^ROS_SNAPSHOT_GPG_FINGERPRINT=" "$TARGET_FILE" | cut -d'"' -f2 || true)
if [ -z "$SNAPSHOT_FP" ]; then
    log_error "No ROS_SNAPSHOT_GPG_FINGERPRINT in $TARGET_FILE; a ROS_SNAPSHOT_DATE build cannot verify its archive."
    exit 1
fi
SNAPSHOT_STATE=unverified
# '|| rc=$?': a bare call would let set -e abort before the case can report.
snapshot_rc=0
verify_signed_by "$SNAPSHOT_PROBE_URL" "$SNAPSHOT_FP" || snapshot_rc=$?
case $snapshot_rc in
    0) SNAPSHOT_STATE=ok
       log_ok "Snapshot archive signature verifies under the pin (${SNAPSHOT_FP:0:16}…)." ;;
    1) SNAPSHOT_STATE=mismatch
       log_warn "${SNAPSHOT_PROBE_URL} does not verify under the pinned ${SNAPSHOT_FP}."
       log_warn "Confirm the replacement against the key the archive operator publishes and the"
       log_warn "rotation announcement on discourse.ros.org, then edit ROS_SNAPSHOT_GPG_FINGERPRINT"
       log_warn "in ${TARGET_FILE} by hand — an unauthenticated fetch must not rewrite a trusted key." ;;
    *) log_warn "Could not verify ${SNAPSHOT_PROBE_URL} (offline, or the key server did not answer)." ;;
esac

# The two pins are independent, so the live-key path must not swallow the
# snapshot result: "verified", "stale" and "not checked" are three outcomes and
# only the first may exit 0.
finish() {
    case "$SNAPSHOT_STATE" in
        ok) exit "${1:-0}" ;;
        mismatch) log_error "The snapshot key pin is stale; a ROS_SNAPSHOT_DATE build would fail with NO_PUBKEY."; exit 1 ;;
        *)  log_error "The snapshot key pin was NOT verified; re-run with network access before trusting it."; exit 1 ;;
    esac
}

if [ "$CURRENT_FP" = "$LATEST_FP" ]; then
    log_ok "Live archive fingerprint is already up to date: $CURRENT_FP"
    finish 0
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
        finish 0
    fi
fi

log_info "Updating $TARGET_FILE..."
tmp_target=$(mktemp "${TMPDIR:-/tmp}/devkit-gpg-update.XXXXXX")
sed "s/^ROS_GPG_FINGERPRINT=\"$CURRENT_FP\"/ROS_GPG_FINGERPRINT=\"$LATEST_FP\"/" "$TARGET_FILE" > "$tmp_target"
cat "$tmp_target" > "$TARGET_FILE"
rm -f "$tmp_target"

log_ok "Live archive fingerprint successfully updated to $LATEST_FP"
finish 0
