#!/bin/bash
# scripts/internal_apt_helper.sh
# ── Build-time APT Management Utility ──────────────────────────────────────

set -e
COMMAND=$1

# 로깅 유틸리티 로드 (도커 빌드 중에는 경로가 다를 수 있음)
SOURCE_LOG="/tmp/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"
LOG_PREFIX="[APT Helper]"

# 0. Initialize APT for Docker (Keep cache for BuildKit mounts)
init_apt() {
    rm -f /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    log_info "Docker APT cache preservation enabled."
}

# 1. Configure APT Snapshot and disable Valid-Until checks
setup_snapshot() {
    local date=$1
    if [ "$date" != "latest" ] && [ -n "$date" ]; then
        # [Common] Disable Valid-Until for snapshots
        echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99-disable-valid-until

        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            # [Ubuntu 24.04+ (DEB822 Format)]
            echo "APT::Snapshot \"$date\";" > /etc/apt/apt.conf.d/99-snapshot
        elif [ -f /etc/apt/sources.list ]; then
            # [Ubuntu 20.04 / 22.04 (Legacy Format)]
            sed -i "s|http://archive.ubuntu.com/ubuntu/|http://snapshot.ubuntu.com/ubuntu/$date/|g" /etc/apt/sources.list
            sed -i "s|http://security.ubuntu.com/ubuntu/|http://snapshot.ubuntu.com/ubuntu/$date/|g" /etc/apt/sources.list
            sed -i "s|http://ports.ubuntu.com/ubuntu-ports/|http://snapshot.ubuntu.com/ubuntu-ports/$date/|g" /etc/apt/sources.list
        fi
        log_info "Snapshot configured for: $date"
    fi
}

# 1-1. Setup ROS Repository (GPG keys and source lists)
setup_ros_repo() {
    local distro=$1
    [ -z "$distro" ] && return

    # Ensure dependencies for adding repos
    apt-get update && apt-get install -y --no-install-recommends curl gnupg2

    # Get Ubuntu codename without lsb_release
    local codename
    codename=$(grep '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2)
    if [ -z "$codename" ]; then codename=$(grep '^UBUNTU_CODENAME=' /etc/os-release | cut -d= -f2); fi

    if [ "$distro" = "noetic" ]; then
        curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.asc | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros/ubuntu $codename main" > /etc/apt/sources.list.d/ros1-latest.list
    else
        curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $codename main" > /etc/apt/sources.list.d/ros2.list
    fi
    log_info "ROS repository configured for: $distro ($codename)"
}
# 2. Install user-defined packages with optional filtering
install_packages() {
    local filter=$1  # "all" (dev/builder) or "runtime" (production)
    local distro=$2
    local dep_dir=${3:-"/opt/dependencies"} # Default dependency directory

    local apt_file="/tmp/apt.txt"
    local ros_file="/tmp/apt_ros.txt"

    # Fallback to centralized dependency directory if /tmp files don't exist
    [ ! -f "$apt_file" ] && [ -f "${dep_dir}/apt.txt" ] && apt_file="${dep_dir}/apt.txt"
    [ ! -f "$ros_file" ] && [ -f "${dep_dir}/apt_ros.txt" ] && ros_file="${dep_dir}/apt_ros.txt"

    # Detect target ROS version tag
    local target_tag="none"
    local other_tag="ros1|ros2"
    if [ -n "$distro" ]; then
        if [ "$distro" == "noetic" ]; then
            target_tag="ros1"
            other_tag="ros2"
        else
            target_tag="ros2"
            other_tag="ros1"
        fi
    fi

    local grep_pattern='^[^#]+'
    [ "$filter" == "runtime" ] && grep_pattern='^[^#]+ # runtime'

    local pkgs=""

    # helper for filtering
    filter_pkg_list() {
        local file=$1
        local pattern=$2
        if [ -f "$file" ]; then
            # 1. Get lines matching basic pattern (e.g. # runtime)
            # 2. Exclude lines explicitly tagged for the "other" version (e.g. # runtime,ros1)
            # 3. Handle variables (${ROS_DISTRO}) and clean up comments
            grep -E "$pattern" "$file" | \
            grep -v -E " #.*,(${other_tag})| # (${other_tag})" | \
            sed "s/\${ROS_DISTRO}/$distro/g" | \
            sed 's/ #.*//' | xargs || true
        fi
    }

    # Extract packages from apt.txt
    if [ -f "$apt_file" ]; then
        pkgs=$(filter_pkg_list "$apt_file" "$grep_pattern")
    fi

    # Extract packages from apt_ros.txt
    if [ -n "$distro" ] && [ -f "$ros_file" ]; then
        local ros_pkgs
        ros_pkgs=$(filter_pkg_list "$ros_file" "$grep_pattern")
        pkgs="$pkgs $ros_pkgs"
    fi

    pkgs=$(echo "$pkgs" | xargs) # Clean whitespace

    if [ -n "$pkgs" ]; then
        if [ -n "$distro" ]; then
            log_info "Installing ($filter) packages for $distro ($target_tag): $pkgs"
        else
            log_info "Installing ($filter) packages: $pkgs"
        fi
        if ! apt-get update; then
            log_error "'apt-get update' failed."
            if [ -f /etc/apt/apt.conf.d/99-snapshot ]; then
                log_info "TIP: An APT Snapshot is active. If this persists, the snapshot date might be invalid or the repository might be down."
            fi
            exit 1
        fi
        read -r -a pkg_array <<< "$pkgs"
        apt-get install -y --no-install-recommends "${pkg_array[@]}"
    else
        log_info "No packages matched filter ($filter, $target_tag)"
    fi
}

case "$COMMAND" in
    "init-apt")
        init_apt
        ;;
    "configure-snapshot")
        setup_snapshot "$2"
        ;;
    "setup-ros-repo")
        setup_ros_repo "$2"
        ;;
    "install-packages")
        install_packages "$2" "$3" "$4"
        ;;
    *)
        echo "Usage: $0 {init-apt|configure-snapshot|setup-ros-repo|install-packages} [args...]"
        exit 1
        ;;
esac
