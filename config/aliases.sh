#!/bin/bash
# =============================================================================
# config/aliases.sh
# Comprehensive alias collection for ROS2, C++, Python (uv), and Diagnostics
#
# Loaded via ~/.bashrc using: source /docker_dev/config/aliases.sh
# Note: ROS-specific aliases are only defined if the ros2 command is available,
# ensuring compatibility with non-ROS dev targets.
# =============================================================================

# =============================================================================
# ROS (ROS1 & ROS2 Common)
# =============================================================================
if [ -d /opt/ros ]; then
    # --- Build (Unified Colcon) ----------------------------------------------
    # CMAKE_CXX_STANDARD is injected via .env -> docker-compose -> ENV
    alias cb='colcon build --symlink-install --install-base /workspace/install --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}'
    alias cbp='colcon build --symlink-install --install-base /workspace/install --cmake-args -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} --packages-select'

    # Release mode (Optimized)
    alias cbr='colcon build --symlink-install --install-base /workspace/install --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17}'
    alias cbrp='colcon build --symlink-install --install-base /workspace/install --cmake-args -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} --packages-select'
    alias cbt='colcon test'
    alias cbm='colcon build --symlink-install --metas /docker_dev/config/colcon.meta'
    alias s='source /workspace/install/setup.bash'
    alias sb='source ~/.bashrc'

    # --- Navigation ----------------------------------------------------------
    alias cw='cd /workspace'
    alias cs='cd /workspace/src'

    # --- ROS Commands --------------------------------------------------------
    # ROS 2 (Default)
    alias rt='ros2 topic list'
    alias rte='ros2 topic echo'
    alias rth='ros2 topic hz'
    alias rn='ros2 node list'
    alias rs='ros2 service list'
    alias rp='ros2 param list'
    alias rr='ros2 run'
    alias rl='ros2 launch'
    alias ri='ros2 interface show'

    # ROS 1 (Fallback if Noetic is detected)
    if [ "${ROS_DISTRO}" = "noetic" ]; then
        alias rt='rostopic list'
        alias rte='rostopic echo'
        alias rth='rostopic hz'
        alias rn='rosnode list'
        alias rs='rosservice list'
        alias rp='rosparam list'
        alias rr='rosrun'
        alias rl='roslaunch'
        alias ri='rosmsg show'
    fi

    alias rqt='rqt'

    # --- Gazebo / Simulation -------------------------------------------------
    alias gz='gazebo'
    alias gzs='ros2 launch gazebo_ros gazebo.launch.py' # ROS 2 standard
fi

# Navigation (Common)
alias cc='cd /docker_dev/config'

# =============================================================================
# Python / uv
# =============================================================================
alias uvs='uv sync --project /workspace/src'
alias uvr='uv run'
alias uvp='uv pip install'
alias uvl='uv pip list'

# Project-specific venv creation (located in /workspace/install for artifact separation + root symlink for IDE compatibility)
alias mkenv='mkdir -p /workspace/install && uv venv --python ${UV_PYTHON:-3.10} /workspace/install/.venv && ln -sf /workspace/install/.venv /workspace/.venv && echo "Created .venv in /workspace/install and linked to /workspace/.venv. Run: activate"'
alias activate='source /workspace/install/.venv/bin/activate'

# Python environment verification
alias pyv='python3 --version && uv --version'
alias uvpython='uv python list'

# =============================================================================
# Utils & Build
# =============================================================================
# Standard C++ build workflow (src -> build -> install)
alias mbuild='mkdir -p /workspace/build && cd /workspace/build && cmake ../src -DCMAKE_INSTALL_PREFIX=/workspace/install -DCMAKE_CXX_STANDARD=${CMAKE_CXX_STANDARD:-17} && make -j$(nproc) install && cd /workspace'

alias k='killall'
alias k9='killall -9'
alias g='git'
alias ll='ls -alF'
alias la='ls -A'
alias ccache-stat='ccache -s'
alias ccache-clear='ccache -C'
alias sync_deps='bash /docker_dev/scripts/sync_deps.sh'
alias check_deps='bash /docker_dev/scripts/check_deps.sh'

# =============================================================================
# Hardware Diagnostics
# =============================================================================
alias hw_check='bash /docker_dev/scripts/hardware_check.sh'
alias gpu_check='glxinfo 2>&1 | grep -E "OpenGL (vendor|renderer|version)" || echo "Error: glxinfo failed (no display?)"'
alias vulkan_check='vulkaninfo --summary 2>/dev/null | head -20 || echo "Vulkan not available"'
alias gpu_status='source /docker_dev/scripts/gpu_setup.sh status'
alias gpu_test='timeout 5 glxgears -info 2>&1 | head -10 || echo "GPU test failed (no display?)"'
alias gpu_setup='source /docker_dev/scripts/gpu_setup.sh auto && __gpu_status_impl'
alias use_intel='source /docker_dev/scripts/gpu_setup.sh intel && __gpu_status_impl'
alias use_amd='source /docker_dev/scripts/gpu_setup.sh amd && __gpu_status_impl'
alias use_nvidia='source /docker_dev/scripts/gpu_setup.sh nvidia && __gpu_status_impl'
alias use_cpu='source /docker_dev/scripts/gpu_setup.sh cpu && __gpu_status_impl'

# =============================================================================
# Help / Documentation
# =============================================================================
function __print_help() {
    # Ensure ANSI colors are defined for standalone shell usage (if utils_logging.sh wasn't sourced)
    [ -z "${NC}" ] && CYAN='\033[0;36m' && BLUE='\033[0;34m' && GREEN='\033[0;32m' && YELLOW='\033[1;33m' && NC='\033[0m'

    echo -e "${CYAN}======================================================================${NC}"
    echo -e "                  ${GREEN}Docker Dev Alias & Shortcut Guide${NC}                  "
    echo -e "${CYAN}======================================================================${NC}"
    echo -e ""
    echo -e "  ${BLUE}[ROS & Build]${NC}"
    echo -e "    ${GREEN}cb${NC} / ${GREEN}cbm${NC} / ${GREEN}cbr${NC}  : colcon build (standard / metas / release)"
    echo -e "    ${GREEN}s${NC} / ${GREEN}sb${NC}           : Source workspace / Source bashrc"
    echo -e "    ${GREEN}rt${NC} / ${GREEN}rn${NC} / ${GREEN}rl${NC}     : ros2 topic / node / launch list"
    echo -e "    ${GREEN}cw${NC} / ${GREEN}cs${NC}           : cd to /workspace or /workspace/src"
    echo -e ""
    echo -e "  ${BLUE}[Python & uv]${NC}"
    echo -e "    ${GREEN}mkenv${NC} / ${GREEN}activate${NC} : Create & Activate python venv"
    echo -e "    ${GREEN}uvs${NC} / ${GREEN}uvr${NC}        : uv sync / uv run"
    echo -e "    ${GREEN}pyv${NC}               : Show Python & uv versions"
    echo -e ""
    echo -e "  ${BLUE}[Hardware & GPU]${NC}"
    echo -e "    ${GREEN}hw_check${NC}          : Run full hardware diagnostics"
    echo -e "    ${GREEN}gpu_status${NC}        : Show detailed GPU & Display info"
    echo -e "    ${GREEN}gpu_setup ${NC}        : Auto-configure GPU mode"
    echo -e "    ${GREEN}use_cpu${NC} / ${GREEN}nvidia${NC}  : Force Software / NVIDIA rendering"
    echo -e ""
    echo -e "  ${BLUE}[Utils]${NC}"
    echo -e "    ${GREEN}ll${NC} / ${GREEN}la${NC}           : Detailed ls (all / long format)"
    echo -e "    ${GREEN}sync_deps${NC}        : Sync external repos from .repos file"
    echo -e "    ${GREEN}check_deps${NC}       : Check missing runtime libraries in install/"
    echo -e "    ${GREEN}ccache-stat${NC}       : Show compiler cache statistics"
    echo -e "    ${GREEN}h${NC} / ${GREEN}help${NC}         : Show this help guide"
    echo -e ""
    echo -e "${CYAN}======================================================================${NC}"
}
alias h='__print_help'
alias help='__print_help'
