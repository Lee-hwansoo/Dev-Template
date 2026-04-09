#!/bin/bash
# =============================================================================
# scripts/welcome.sh
# Container Welcome Message (MOTD) and quick-start guide
#
# Displays project metadata (ROS version, GPU mode) and a summarized list
# of core helper commands and shortcuts for a better onboarding experience.
# =============================================================================

# Load logging utility for shared color variables (P-3: unified color source)
SOURCE_LOG="/docker_dev/scripts/utils_logging.sh"
[ ! -f "$SOURCE_LOG" ] && SOURCE_LOG="$(dirname "${BASH_SOURCE[0]}")/utils_logging.sh"
[ -f "$SOURCE_LOG" ] && source "$SOURCE_LOG"

# Fallback: ensure color variables exist if utils_logging.sh is missing
if [ -z "${NC:-}" ]; then
    CYAN='\033[0;36m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'
    YELLOW='\033[1;33m'; NC='\033[0m'
fi

print_devkit_banner WELCOME
echo -e "  Project: ${BLUE}${COMPOSE_PROJECT_NAME}${NC} | ROS: ${YELLOW}${ROS_DISTRO:-None}${NC} | GPU: ${YELLOW}${GPU_MODE:-auto}${NC}"
echo -e ""
echo -e "  ${BLUE}Core Helpers:${NC}"
echo -e "    ${GREEN}hw_check${NC}      : Full hardware & environment diagnostics"
echo -e "    ${GREEN}gpu_status${NC}    : Detailed GPU & Display status"
echo -e "    ${GREEN}gpu_setup${NC}     : Auto-configure GPU mode (nvidia/igpu/cpu)"
echo -e "    ${GREEN}cb / cbm / cbr${NC}: colcon build (standard / metas / release)"
echo -e "    ${GREEN}mkenv / activate${NC}: Create & Activate python venv"
echo -e "    ${GREEN}sync_deps${NC}     : Sync external repos from .repos file"
echo -e "    ${GREEN}check_deps${NC}    : Verify missing runtime libraries in install/"
echo -e ""
echo -e "  ${BLUE}Quick Shortcuts:${NC}"
echo -e "    ${GREEN}rt / rn / rl${NC}  : ros2 topic / node / launch"
echo -e "    ${GREEN}s / sb${NC}        : Source workspace / Source bashrc"
echo -e "    ${GREEN}la / ll${NC}       : Detailed ls (all / long format)"
echo -e "    ${GREEN}h / help${NC}       : Show full Alias & Shortcut Guide"
echo -e ""
echo -e ""
echo -e "  Workspace: ${CYAN}/workspace${NC} (mapped from host)"
