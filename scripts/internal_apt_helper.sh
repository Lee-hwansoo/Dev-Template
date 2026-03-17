#!/bin/bash
# scripts/internal_apt_helper.sh
# ── Build-time APT Management Utility ──────────────────────────────────────
# This script is used during Docker builds to handle APT snapshots and
# filter user-defined packages from apt.txt and apt_ros.txt.

set -e

COMMAND=$1

# 0. Initialize APT for Docker (Keep cache for BuildKit mounts)
init_apt() {
    rm -f /etc/apt/apt.conf.d/docker-clean
    echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache
    echo "[APT Helper] Docker APT cache preservation enabled."
}

# 1. Configure APT Snapshot and disable Valid-Until checks
setup_snapshot() {
    local date=$1
    if [ "$date" != "latest" ] && [ -n "$date" ]; then
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            # [Ubuntu 24.04+ (DEB822 Format)]
            echo "APT::Snapshot \"$date\";" > /etc/apt/apt.conf.d/99-snapshot
        elif [ -f /etc/apt/sources.list ]; then
            # [Ubuntu 20.04 / 22.04 (Legacy Format)]
            echo 'Acquire::Check-Valid-Until "false";' > /etc/apt/apt.conf.d/99-disable-valid-until
            sed -i "s|http://archive.ubuntu.com/ubuntu/|http://snapshot.ubuntu.com/ubuntu/$date/|g" /etc/apt/sources.list
            sed -i "s|http://security.ubuntu.com/ubuntu/|http://snapshot.ubuntu.com/ubuntu/$date/|g" /etc/apt/sources.list
            sed -i "s|http://ports.ubuntu.com/ubuntu-ports/|http://snapshot.ubuntu.com/ubuntu-ports/$date/|g" /etc/apt/sources.list
        fi
        echo "[APT Helper] Snapshot configured for: $date"
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
    echo "[APT Helper] ROS repository configured for: $distro ($codename)"
}
# 2. Install user-defined packages with optional filtering
install_packages() {
    local filter=$1  # "all" (dev/builder) or "runtime" (production)
    local distro=$2
    local apt_file="/tmp/apt.txt"
    local ros_file="/tmp/apt_ros.txt"

    local pkgs=""
    local grep_pattern='^[^#]+'
    [ "$filter" == "runtime" ] && grep_pattern='^[^#]+ # runtime'

    # Extract packages from apt.txt
    if [ -f "$apt_file" ]; then
        pkgs=$(grep -E "$grep_pattern" "$apt_file" | sed 's/ # runtime.*//' | xargs || true)
    fi

    # Extract packages from apt_ros.txt and handle ${ROS_DISTRO} variable
    if [ -f "$ros_file" ]; then
        local ros_pkgs
        ros_pkgs=$(grep -E "$grep_pattern" "$ros_file" | sed 's/ # runtime.*//' | sed "s/\${ROS_DISTRO}/$distro/g" | xargs || true)
        pkgs="$pkgs $ros_pkgs"
    fi

    pkgs=$(echo "$pkgs" | xargs) # Clean whitespace

    if [ -n "$pkgs" ]; then
        echo "[APT Helper] Installing ($filter) packages: $pkgs"
        apt-get update
        apt-get install -y --no-install-recommends $pkgs
    else
        echo "[APT Helper] No packages matched filter: $filter"
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
        install_packages "$2" "$3"
        ;;
    *)
        echo "Usage: $0 {init-apt|configure-snapshot|setup-ros-repo|install-packages} [args...]"
        exit 1
        ;;
esac
