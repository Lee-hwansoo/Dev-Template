#!/bin/bash
# =============================================================================
# config/init_ros_env.sh — the ROS 1 / ROS 2 environment (RMW, domain, DDS URI).
# =============================================================================

# Every expansion carries a default: this file is sourced from `set -u` contexts
# (docker/entrypoint.sh, scripts run with `set -euo pipefail`), where a bare
# ${ROS_DISTRO} aborts the caller before any DDS setting is applied.
if [ "${ROS_DISTRO:-humble}" = "noetic" ]; then
    # ROS 1 Networking Optimization: Use hostname instead of localhost for container mobility
    if [ -z "${ROS_HOSTNAME:-}" ] || [ "${ROS_HOSTNAME}" = "localhost" ]; then
        ROS_HOSTNAME="$(hostname)"
        export ROS_HOSTNAME
    fi
    export ROS_MASTER_URI="${ROS_MASTER_URI:-http://${ROS_HOSTNAME}:11311}"
else
    # ROS 2 Specifics
    export ROS_DOMAIN_ID=${ROS_DOMAIN_ID:-0}
    export RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-rmw_cyclonedds_cpp}

    # Auto-configure CycloneDDS defaults (Unicast Fallback for Bridge Networks)
    if [ "$RMW_IMPLEMENTATION" = "rmw_cyclonedds_cpp" ] && [ -z "${CYCLONEDDS_URI:-}" ]; then
        devkit_dds_cfg="${WS_CONFIG:-${WORKSPACE_PATH:-/workspace}/config}/cyclonedds.xml"
        [ -f "$devkit_dds_cfg" ] && export CYCLONEDDS_URI="file://${devkit_dds_cfg}"
        unset devkit_dds_cfg
    fi
fi
