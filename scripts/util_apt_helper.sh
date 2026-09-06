#!/bin/bash
# =============================================================================
# scripts/util_apt_helper.sh — build-time APT: repository trust anchors and
# tag-filtered installation from dependencies/apt*.txt. Runs in a `docker build`
# layer with only this file bind-mounted, hence the private log verbs below.
# =============================================================================
set -eo pipefail

COMMAND="${1:-}"
shift || true

export DEBIAN_FRONTEND=noninteractive
export APT_KEY_DONT_WARN_ON_DANGEROUS_USAGE=1

# =============================================================================
# Pinned archive signing keys — the whole trust anchor for these repositories,
# so a downloaded key is fingerprint-checked against the value below before it
# is installed. STRICT_GPG_CHECK=true (default) aborts on mismatch, false warns.
# `make update-gpg` rewrites the line below — keep the exact spelling.
# =============================================================================
ROS_GPG_FINGERPRINT="C1CF6E31E6BADE8868B172B4F42ED6FBAB17C654"
# snapshots.ros.org uses a separate archive signing key.
ROS_SNAPSHOT_GPG_FINGERPRINT="4B63CF8FDE49746E98FA01DDAD19BAB3CBF125EA"
# NVIDIA CUDA repository signing key (id 3bf863cc), same trust policy as above.
NVIDIA_GPG_FINGERPRINT="EB693B3035CD5710E231E123A4B469963BF863CC"

# Private loggers: this is the ONLY file bind-mounted into its RUN layers.
log_info() { echo -e "  \033[0;34m[APT]\033[0m $*"; }
log_ok()   { echo -e "  \033[0;32m[APT]\033[0m $*"; }
log_error(){ echo -e "  \033[0;31m[APT]\033[0m $*" >&2; }

# verify_key_fingerprint <key_file> <pinned_fp> <label> <rotation_hint>
# One trust policy for every repo key: compare BEFORE install.
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
# select_packages <filter> [distro] → one package per line (SSOT:
# dependencies/apt*.txt)
#   all      dev images        : everything but the opposite ROS family
#   builder  prod build stages : drops '# dev' and '# gui'
#   runtime  deploy artifacts  : keeps ONLY '# runtime'
# An empty distro skips apt_ros.txt entirely, which is what stops the non-ROS
# stages from requesting ros-* on an image with no ROS repository.
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
    restore-docker-clean)
        # The inverse of init-apt's cache retention, for every stage that SHIPS.
        # keep-cache only serves BuildKit's cache mounts; left in place, runtime
        # `apt install` in the deployed image hoards .debs forever.
        rm -f /etc/apt/apt.conf.d/keep-cache
        printf 'DPkg::Post-Invoke { "rm -f /var/cache/apt/archives/*.deb /var/cache/apt/archives/partial/*.deb || true"; };\nAPT::Keep-Downloaded-Packages "false";\n' \
            > /etc/apt/apt.conf.d/docker-clean
        log_ok "APT cache retention restored to docker-clean."
        ;;
    purge-bootstrap)
        # init-apt's curl/gnupg/lsb-release have no job in a shipped stage, but
        # `purge -y` takes dependents along: ros-*-libcurl-vendor needs curl and
        # python3-rospkg needs lsb-release. Drop only what nothing installed
        # still depends on (Depends/Pre-Depends; not Suggests or Breaks).
        drop=""; kept=""
        for pkg in curl gnupg dirmngr lsb-release; do
            dpkg-query -W -f='${db:Status-Abbrev}' "$pkg" 2>/dev/null | grep -q '^ii' || continue
            if [ -n "$(apt-cache rdepends --installed --no-recommends --no-suggests --no-conflicts \
                           --no-breaks --no-replaces --no-enhances "$pkg" 2>/dev/null | sed '1,2d')" ]; then
                kept="$kept $pkg"
            else
                drop="$drop $pkg"
            fi
        done
        # shellcheck disable=SC2086  # deliberate word split over the package list
        [ -z "$drop" ] || apt-get purge -y --auto-remove $drop
        log_ok "Bootstrap tools purged:${drop:- none}.${kept:+ Kept, still depended on:$kept}"
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
            humble|iron|jazzy|kilted|rolling|foxy|noetic|melodic|kinetic) ;;
            *)  log_error "Unknown ROS distro: '${distro}' (supported: humble iron jazzy kilted rolling foxy noetic melodic kinetic)"
                exit 2 ;;
        esac
        case "$distro" in noetic|melodic|kinetic) family=ros ;; *) family=ros2 ;; esac
        # HTTP on purpose: packages.ros.org answers TLS with a *.osuosl.org
        # certificate, so https:// fails the hostname check and apt-get update
        # dies. Integrity comes from signed-by, which is apt's actual trust
        # model and what ROS's own install instructions use. Do not "fix" this
        # back to https until the certificate covers the name.
        repo="http://packages.ros.org/${family}/ubuntu"
        key_url=https://raw.githubusercontent.com/ros/rosdistro/master/ros.key
        fingerprint="$ROS_GPG_FINGERPRINT"
        if [ "${ROS_SNAPSHOT_DATE:-latest}" != latest ]; then
            [[ "$ROS_SNAPSHOT_DATE" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}|final)$ ]] || {
                log_error 'ROS_SNAPSHOT_DATE must be latest, YYYY-MM-DD, or final.'; exit 2;
            }
            repo="http://snapshots.ros.org/${distro}/${ROS_SNAPSHOT_DATE}/ubuntu"
            fingerprint="$ROS_SNAPSHOT_GPG_FINGERPRINT"
            key_url="https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${fingerprint}"
        fi
        log_info "Setting up ROS repository for ${distro}..."
        mkdir -p /usr/share/keyrings
        tmp_key="$(mktemp)"
        curl -fsSL "$key_url" -o "$tmp_key"

        verify_key_fingerprint "$tmp_key" "$fingerprint" "ROS" \
            "Check the upstream archive signing key; make update-gpg updates the live archive pin." \
            || { rm -f "$tmp_key"; exit 1; }
        if [ "${ROS_SNAPSHOT_DATE:-latest}" != latest ]; then
            gpg --batch --yes --dearmor --output "${tmp_key}.gpg" "$tmp_key"
            mv "${tmp_key}.gpg" "$tmp_key"
        fi
        install -m 0644 "$tmp_key" /usr/share/keyrings/ros-archive-keyring.gpg
        rm -f "$tmp_key"

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] $repo $(lsb_release -cs) main" > "/etc/apt/sources.list.d/${family}.list"
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
        while IFS= read -r pkg_line; do [ -n "$pkg_line" ] && pkgs+=("$pkg_line"); done <<< "$pkg_list"

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
  restore-docker-clean          Undo init-apt's cache retention (shipped stages)
  purge-bootstrap               Drop init-apt's curl/gnupg/lsb-release where nothing depends on them
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
        log_error "Unknown command: $COMMAND"
        exit 2
        ;;
esac
