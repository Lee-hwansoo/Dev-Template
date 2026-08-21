#!/bin/bash
# =============================================================================
# scripts/util_apt_helper.sh
# Build-time APT repository setup and tag-filtered package installation
# =============================================================================
set -eo pipefail

COMMAND="${1:-}"
shift || true

export DEBIAN_FRONTEND=noninteractive
export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1

# =============================================================================
# Pinned ROS archive signing key — Single Source of Truth
# -----------------------------------------------------------------------------
# The keyring is the entire trust anchor for packages.ros.org, so the downloaded
# key is fingerprint-checked against this value before it is installed.
#   STRICT_GPG_CHECK=true (default) → a mismatch aborts the build
#   STRICT_GPG_CHECK=false          → a mismatch warns and continues (opt-in)
# `make update-gpg` (scripts/setup_ros_gpg.sh) rewrites the line below after
# verifying upstream; keep the exact `ROS_GPG_FINGERPRINT="..."` spelling.
# =============================================================================
ROS_GPG_FINGERPRINT="C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654"
# NVIDIA CUDA repository signing key (id 3bf863cc), same trust policy as above.
NVIDIA_GPG_FINGERPRINT="EB693B3035CD5710E231E123A4B469963BF863CC"

# Private loggers on purpose: this script runs in `docker build` RUN layers
# where it is the ONLY file bind-mounted, so it cannot source util_logging.sh.
log_info() { echo -e "  \033[0;34m[APT]\033[0m $*"; }
log_ok()   { echo -e "  \033[0;32m[APT]\033[0m $*"; }
log_error(){ echo -e "  \033[0;31m[APT]\033[0m $*" >&2; }

# verify_key_fingerprint <key_file> <pinned_fp> <label> <rotation_hint>
# Shared trust policy for every downloaded repo key: the keyring is the entire
# trust anchor, so the fingerprint is compared against the pin BEFORE install.
# STRICT_GPG_CHECK=true (default) aborts on mismatch; false warns and continues.
verify_key_fingerprint() {
    local key_file="$1" pinned="$2" label="$3" hint="$4" actual_fp
    actual_fp="$(gpg --with-colons --import-options show-only --import "$key_file" 2>/dev/null \
                 | awk -F: '/^fpr/{print $10; exit}' || true)"
    if [ -z "$actual_fp" ]; then
        log_error "Downloaded ${label} key has no readable GPG fingerprint."
        return 1
    elif [ "$actual_fp" != "$pinned" ]; then
        if [ "${STRICT_GPG_CHECK:-true}" = "true" ]; then
            log_error "FATAL: ${label} GPG fingerprint mismatch."
            log_error "  expected: ${pinned}"
            log_error "  actual:   ${actual_fp}"
            log_error "Aborting (STRICT_GPG_CHECK=true). ${hint}"
            return 1
        fi
        echo -e "  \033[0;33m[APT]\033[0m ${label} GPG fingerprint mismatch (expected ${pinned}, got ${actual_fp}). Continuing (STRICT_GPG_CHECK=false); ${hint}" >&2
    else
        log_ok "${label} GPG key fingerprint verified: ${actual_fp}"
    fi
}

# =============================================================================
# Tag-based package selection (SSOT: dependencies/apt.txt, dependencies/apt_ros.txt)
# -----------------------------------------------------------------------------
# select_packages <filter> [distro]  → one package per line on stdout
#
#   filter=all      dev images        : everything except the opposite ROS family
#   filter=builder  prod build stages : excludes '# dev' and '# gui' entries
#   filter=runtime  deploy artifacts  : keeps ONLY '# runtime' entries
#
#   distro empty → apt_ros.txt is skipped entirely. This is what keeps the
#   non-ROS stages (dev, prod-dev-*) from requesting ros-* packages on images
#   that never configured the ROS apt repository.
# =============================================================================
select_packages() {
    local filter="$1" distro="${2:-}"
    local deps_dir="${DEVKIT_DEPS_DIR:-${WORKSPACE_PATH:-/workspace}/dependencies}"
    local other_tag="none" file files=()

    # A missing manifest must fail loudly: silently installing nothing would
    # produce an image that only breaks much later, at runtime.
    if [ ! -f "${deps_dir}/apt.txt" ]; then
        log_error "APT manifest not found: ${deps_dir}/apt.txt (set DEVKIT_DEPS_DIR to override)"
        return 1
    fi

    if [ -n "$distro" ]; then
        case "$distro" in
            noetic|melodic|kinetic) other_tag="ros2" ;;
            *)                      other_tag="ros1" ;;
        esac
    fi

    files=("${deps_dir}/apt.txt")
    [ -n "$distro" ] && files+=("${deps_dir}/apt_ros.txt")

    for file in "${files[@]}"; do
        [ -f "$file" ] || continue
        awk -v mode="$filter" -v distro="$distro" -v other_tag="$other_tag" '
            /^[[:space:]]*($|#)/ { next }
            {
                comment = ""
                line = $0
                if (match(line, /#/)) {
                    comment = substr(line, RSTART + 1)
                    line    = substr(line, 1, RSTART - 1)
                }
                if (mode == "runtime" && comment !~ /(^|[[:space:],])runtime([[:space:],]|$)/) next
                if (mode == "builder" && comment ~  /(^|[[:space:],])(dev|gui)([[:space:],]|$)/) next
                if (other_tag != "none" && comment ~ "(^|[[:space:],])" other_tag "([[:space:],]|$)") next
                gsub(/\$\{ROS_DISTRO\}|\$ROS_DISTRO/, distro, line)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
                if (line != "") print line
            }
        ' "$file"
    done
}

case "$COMMAND" in
    init-apt)
        log_info "Initializing APT package lists..."
        # BuildKit cache mounts on /var/cache/apt only help if apt keeps the .deb
        # files: drop the stock docker-clean hook and opt into retention.
        rm -f /etc/apt/apt.conf.d/docker-clean
        echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
        apt-get update -y
        apt-get install -y --no-install-recommends curl ca-certificates gnupg lsb-release
        log_ok "APT initialized."
        ;;
    configure-snapshot)
        # Pin APT to a point-in-time Ubuntu snapshot so SOURCE_DATE_EPOCH builds are
        # actually reproducible. 'latest' (or empty) keeps the rolling mirrors.
        snap_date="${1:-latest}"
        if [ -z "$snap_date" ] || [ "$snap_date" = "latest" ]; then
            log_info "APT snapshot: latest (rolling mirrors; builds are not reproducible)"
            exit 0
        fi
        if ! [[ "$snap_date" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]; then
            log_error "APT_SNAPSHOT_DATE must be 'latest' or UTC format YYYYMMDDTHHMMSSZ (got: ${snap_date})"
            exit 2
        fi

        # snapshot.ubuntu.com is a single upstream. If it is down we must NOT quietly
        # fall back to rolling mirrors — that would void the reproducibility the
        # snapshot exists to guarantee. Fail loudly unless explicitly opted out.
        if command -v curl >/dev/null 2>&1 && \
           ! curl -fsS --connect-timeout 5 --max-time 10 -I "https://snapshot.ubuntu.com/" >/dev/null 2>&1; then
            case "${APT_SNAPSHOT_FALLBACK:-}" in
                1|true|yes|on)
                    log_error "snapshot.ubuntu.com unreachable — APT_SNAPSHOT_FALLBACK set, using rolling mirrors."
                    log_error "WARNING: build reproducibility (SOURCE_DATE_EPOCH) is VOIDED for this build."
                    exit 0 ;;
                *)
                    log_error "snapshot.ubuntu.com is unreachable (APT_SNAPSHOT_DATE=${snap_date})."
                    log_error "Fix connectivity, pick another snapshot date, or set APT_SNAPSHOT_FALLBACK=1"
                    log_error "to intentionally build against standard (non-reproducible) mirrors."
                    exit 1 ;;
            esac
        fi

        # Historical snapshots are past their Valid-Until date by definition.
        echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99-disable-valid-until

        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            # Ubuntu 24.04+ (deb822): APT resolves snapshots natively.
            echo "APT::Snapshot \"${snap_date}\";" > /etc/apt/apt.conf.d/99-snapshot
        elif [ -f /etc/apt/sources.list ]; then
            # Ubuntu 20.04 / 22.04 (legacy one-line format): rewrite the mirrors.
            # https: Check-Valid-Until is disabled above (snapshots are stale by
            # definition), so TLS is the only remaining anti-rollback control.
            tmp_sources="$(mktemp)"
            sed -e "s|https\?://archive.ubuntu.com/ubuntu/|https://snapshot.ubuntu.com/ubuntu/${snap_date}/|g" \
                -e "s|https\?://security.ubuntu.com/ubuntu/|https://snapshot.ubuntu.com/ubuntu/${snap_date}/|g" \
                -e "s|https\?://ports.ubuntu.com/ubuntu-ports/|https://snapshot.ubuntu.com/ubuntu-ports/${snap_date}/|g" \
                /etc/apt/sources.list > "$tmp_sources"
            cat "$tmp_sources" > /etc/apt/sources.list
            rm -f "$tmp_sources"
        fi
        log_ok "APT pinned to snapshot ${snap_date}."
        ;;
    setup-ros-repo)
        distro="${1:-humble}"
        # Guard first: a typo'd distro would otherwise configure the wrong
        # repository family and only fail much later, at package install.
        case "$distro" in
            humble|iron|jazzy|kilted|rolling|noetic|melodic|kinetic) ;;
            *)  log_error "Unknown ROS distro: '${distro}' (supported: humble iron jazzy kilted rolling noetic melodic kinetic)"
                exit 2 ;;
        esac
        log_info "Setting up ROS repository for ${distro}..."
        mkdir -p /usr/share/keyrings
        tmp_key="$(mktemp)"
        # ONE key for both families: ros.key is the binary form of ros.asc (same
        # fingerprint, verified below), it is what `signed-by=` expects, and it is
        # what upstream documents for noetic too. Fetching it directly also drops
        # a `gpg --dearmor -o "$tmp_key"` step that aborted EVERY ROS 1 build:
        # mktemp pre-creates the target, so gpg asked "Overwrite?" on /dev/tty —
        # which `docker build` does not have (gpg: cannot open '/dev/tty').
        curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o "$tmp_key"

        verify_key_fingerprint "$tmp_key" "$ROS_GPG_FINGERPRINT" "ROS" \
            "If upstream rotated the key, run 'make update-gpg' on the host." \
            || { rm -f "$tmp_key"; exit 1; }
        install -m 0644 "$tmp_key" /usr/share/keyrings/ros-archive-keyring.gpg
        rm -f "$tmp_key"

        case "$distro" in noetic|melodic|kinetic)
            echo "deb [signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu $(lsb_release -cs) main" > /etc/apt/sources.list.d/ros1.list
            ;;
        *)
            echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" > /etc/apt/sources.list.d/ros2.list
            ;;
        esac
        apt-get update -y
        log_ok "ROS repository configured."
        ;;
    setup-cuda-repo)
        cuda_version="${1:-}"
        if [ -z "$cuda_version" ]; then
            log_info "No CUDA version given — skipping CUDA repository setup."
            exit 0
        fi
        # Jetson/L4T: CUDA ships via the JetPack/L4T repos with a BSP-supplied
        # driver — the x86/sbsa channel below would install the wrong stack.
        if [ -f /etc/nv_tegra_release ] || grep -qs tegra /proc/device-tree/compatible 2>/dev/null; then
            log_info "Jetson/L4T detected — CUDA comes from the JetPack repos; skipping."
            exit 0
        fi
        os_version="$(. /etc/os-release && echo "${VERSION_ID//./}")"
        arch="$(dpkg --print-architecture)"
        repo_arch="x86_64"
        if [ "$arch" = "arm64" ]; then
            repo_arch="sbsa"
            # The Jetson probe above cannot see the TARGET device when
            # cross-building under qemu — warn instead of silently shipping
            # the server-ARM CUDA stack to an embedded board.
            log_info "arm64 build: using the sbsa (server ARM) CUDA channel."
            log_info "If this image targets Jetson, use an L4T base image instead — Jetson CUDA ships via JetPack."
        fi
        repo_url="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu${os_version}/${repo_arch}"
        log_info "Configuring NVIDIA CUDA repository (ubuntu${os_version}/${repo_arch})..."

        # NVIDIA's pin file keeps their repo ahead of Ubuntu's for CUDA packages.
        # This runs in the base stage of every image: fail with a diagnosis, not
        # a bare curl exit 22 nobody can interpret.
        if ! curl -fsSL "${repo_url}/cuda-ubuntu${os_version}.pin" \
                -o /etc/apt/preferences.d/cuda-repository-pin-600; then
            log_error "NVIDIA publishes no CUDA repo for this base (ubuntu${os_version}/${repo_arch})."
            log_error "Unset CUDA_VERSION in .env, or use a base image NVIDIA supports."
            exit 1
        fi

        # Only the key matching the pin below is fetched — a legacy-key fallback
        # would fail the fingerprint check by construction and misread as attack.
        tmp_key="$(mktemp)"
        curl -fsSL "${repo_url}/3bf863cc.pub" -o "$tmp_key" \
            || { log_error "Could not download the NVIDIA repository key from ${repo_url}."; rm -f "$tmp_key"; exit 1; }
        verify_key_fingerprint "$tmp_key" "$NVIDIA_GPG_FINGERPRINT" "NVIDIA CUDA" \
            "If NVIDIA rotated the key, update NVIDIA_GPG_FINGERPRINT after verifying upstream." \
            || { rm -f "$tmp_key"; exit 1; }
        gpg --dearmor --yes -o /usr/share/keyrings/cuda-archive-keyring.gpg < "$tmp_key"
        rm -f "$tmp_key"

        echo "deb [arch=${arch} signed-by=/usr/share/keyrings/cuda-archive-keyring.gpg] ${repo_url}/ /" \
            > /etc/apt/sources.list.d/cuda.list
        apt-get update -y
        log_ok "NVIDIA CUDA repository configured."
        ;;
    update-rosdep)
        distro="${1:-humble}"
        log_info "Updating rosdep database for ${distro}..."
        mkdir -p /root/.ros
        if ! command -v rosdep >/dev/null 2>&1; then
            apt-get update -y && apt-get install -y --no-install-recommends python3-rosdep
        fi
        rosdep init 2>/dev/null || true   # already-initialized is fine
        # A silently-empty rosdep cache surfaces much later, inside mksync: retry
        # once, accept an existing cache, otherwise fail the build here.
        if ! rosdep update --rosdistro "$distro" && ! rosdep update --rosdistro "$distro"; then
            if [ -d /root/.ros/rosdep ]; then
                log_info "rosdep update failed — reusing existing cache."
            else
                log_error "rosdep update failed and no cached database exists."
                exit 1
            fi
        fi
        log_ok "rosdep database updated."
        ;;
    install-packages)
        target="${1:-all}"
        distro="${2:-}"
        case "$target" in
            all|builder|runtime) ;;
            *) log_error "install-packages mode must be 'all', 'builder' or 'runtime' (got: ${target})"; exit 2 ;;
        esac

        # Command substitution (not a process substitution) so a manifest error
        # propagates instead of being swallowed into an empty package list.
        if ! pkg_list="$(select_packages "$target" "$distro")"; then
            exit 1
        fi
        pkgs=()
        [ -n "$pkg_list" ] && mapfile -t pkgs <<< "$pkg_list"

        # DEVKIT_DRY_RUN=1 prints the resolved selection without touching APT.
        # Used by scripts/verify_repo.sh to assert the filter contract.
        if [ "${DEVKIT_DRY_RUN:-}" = "1" ]; then
            [ "${#pkgs[@]}" -gt 0 ] && printf '%s\n' "${pkgs[@]}"
            exit 0
        fi

        if [ "${#pkgs[@]}" -eq 0 ]; then
            log_ok "No packages matched filter (${target}${distro:+, $distro}). Nothing to install."
            exit 0
        fi

        log_info "Installing ${#pkgs[@]} APT package(s) (${target}${distro:+, $distro}): ${pkgs[*]}"
        apt-get update -y
        apt-get install -y --no-install-recommends "${pkgs[@]}"
        log_ok "APT packages installed."
        ;;
    -h|--help|"")
        cat <<'EOF'
Usage: util_apt_helper.sh <command> [args...]

  init-apt
  configure-snapshot <latest|YYYYMMDDTHHMMSSZ>
  setup-ros-repo     <ros_distro>
  setup-cuda-repo    <cuda_version>
  update-rosdep      <ros_distro>
  install-packages   <all|builder|runtime> [ros_distro]
                     Omit ros_distro to skip dependencies/apt_ros.txt entirely.
                     DEVKIT_DRY_RUN=1 prints the selection instead of installing.
EOF
        ;;
    *)
        echo "Unknown command: $COMMAND" >&2
        exit 1
        ;;
esac
