#!/bin/bash
# =============================================================================
# config/init_ros_env.sh
# Centralized ROS environment orchestration for ROS1 (Noetic) and ROS2 (Humble)
# =============================================================================

# Every expansion carries a default: this file is sourced from `set -u` contexts
# (docker/entrypoint.sh, scripts run with `set -euo pipefail`), where a bare
# ${ROS_DISTRO} aborts the caller before any DDS setting is applied.
if [ "${ROS_DISTRO:-humble}" = "noetic" ]; then
    # ROS 1 Networking Optimization: Use hostname instead of localhost for container mobility
    if [ -z "${ROS_HOSTNAME:-}" ] || [ "${ROS_HOSTNAME}" = "localhost" ]; then
        ROS_HOSTNAME="$(hostname)"
        export ROS_HOSTNAME
        export ROS_MASTER_URI="http://${ROS_HOSTNAME}:11311"
    fi
else
    # ROS 2 Specifics
    export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}
    export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}

    # Auto-configure CycloneDDS defaults (Unicast Fallback for Bridge Networks)
    if [ "$RMW_IMPLEMENTATION" = "rmw_cyclonedds_cpp" ] && [ -z "${CYCLONEDDS_URI:-}" ]; then
        if [ -f "${WORKSPACE_PATH:-/workspace}/config/cyclonedds.xml" ]; then
            export CYCLONEDDS_URI="file://${WORKSPACE_PATH:-/workspace}/config/cyclonedds.xml"
        fi
    fi
fi
