# All-in-One Docker DevKit

[English](README.md) | [한국어](README.ko.md)

[![ROS1](https://img.shields.io/badge/ROS-Noetic-blue?logo=ros)](https://www.ros.org/)
[![ROS2](https://img.shields.io/badge/ROS2-Humble-red?logo=ros)](https://docs.ros.org/en/humble/index.html)
[![Python](https://img.shields.io/badge/Python-3.10-3776AB?logo=python)](https://www.python.org/)
[![C++](https://img.shields.io/badge/C%2B%2B-17-00599C?logo=c%2B%2B)](https://isocpp.org/)
[![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker)](https://www.docker.com/)

This repository provides an **isolated development environment template** designed to enable seamless **C++, Python(uv), and ROS 1 / ROS 2** development without polluting your host system. Start developing immediately across any project without complex configurations.

## 💡 Core Values

- **Zero-Pollution Isolation**: Only install Docker on your host machine. All libraries and dependencies are entirely managed by lightweight containers to prevent system conflicts.
- **Hardware Agnostic**: Auto-detects NVIDIA, Intel, and AMD GPUs. Provides instant hardware acceleration on both **X11 and modern Wayland environments**.
- **Production Ready**: Utilizes a **Bake & Switch** strategy to build deployment-ready production images directly from your development environment artifacts, complete with built-in **automatic dependency verification (Sanity Check)**.
- **Unified Workspace**: Every project follows an identical directory structure (`src`, `build`, `install`), drastically improving team collaboration and long-term maintainability.

## 🌟 Key Features

- **Intelligent Diagnostic Engine**: Running `make status` identifies the host's GPU architecture, CPU architecture (AMD64/ARM64), display protocols, and **Wayland socket paths** to automatically orchestrate the optimal runtime environment.
- **Unified Workspace (Everything is a Package)**: All projects (C++, Python, ROS) adhere to the standard **`src/` (Source), `build/` (Build), and `install/` (Artifacts)** structure, maximizing consistency between development and deployment workflows.
- **Perfect Reproducibility via APT Snapshots**: Guarantees 100% reproducibility by pinning package versions at a specific point in time using `APT_SNAPSHOT_DATE`. By setting a UTC date (obtained via `date -u +%Y%m%dT%H%M%SZ`) in your `.env` file, the environment is permanently frozen at that exact moment.
- **Runtime Dependency Guardian (Sanity Check)**: When building deployment images, it automatically inspects executables and libraries for missing dependencies using `ldd`, completely preventing 'Shared library not found' errors at runtime.
- **Ultra-lightweight & Secure Deployments (Bake & Switch)**: Deployment images exclude source code and only retain **production artifacts** from the `install/` directory, ensuring maximum security and runtime efficiency.
- **Native Multi-Arch Support**: Supports both Intel PCs and ARM-based (Jetson, Apple Silicon) environments seamlessly through a single Dockerfile.
- **Consistent Permission System (Root Unity)**: Uses the `root` user in both development and deployment environments to prevent tricky permission conflicts when mounting host volumes.
- **Zero-Pollution Cleanup (Sudo-Free Architecture)**: Spawns an ultra-lightweight disposable container to perform deletion tasks without requiring `sudo` privileges when cleaning host storage (`make clean`). The container and image are automatically removed immediately after the task, leaving no trace on your local environment.
- **CI/CD Robustness**: Includes a `FORCE=1` flag that bypasses interactive prompts, combined with auto-detection for the platform's `CI=true` environment variable, ensuring flawless execution without stalling in CI/CD pipelines (e.g., GitHub Actions, GitLab CI).

---

## 🏗 Multi-stage Docker Architecture

This template utilizes a granular container build pipeline to maximize speed and cache efficiency.

```mermaid
graph TD
    A[Base OS] --> B[dev-base-tools <br/> Utilities/Build/GUI]
    B --> C[dev-core <br/> Python & Core Config]
    C --> D[dev <br/> Dev Targets]
    C --> E[builder <br/> Bake]
    E --> F[runtime <br/> Lightweight Prod]
```

---

## 🚀 Standard Workspace Layout

Every project adheres to this layout, regardless of the underlying language or framework.

- **`src/`**: All source code and build configurations (CMakeLists.txt, pyproject.toml, etc.)
- **`build/`**: Temporary build space utilized by compilers and build systems.
- **`install/`**: The **deployment artifacts** directory where final executables, libraries, and Python virtual environments (`.venv`) are stored.
  - *Note: The Python virtual environment is intentionally placed inside `install/` so it can be executed independently without the source code upon deployment. For IDE compatibility, a `.venv` symlink is automatically created in the project root.*

```mermaid
graph LR
    subgraph "Dev Mode (make dev / ros)"
        SRC["Host: src/<br/>(Bind Mount :rw)"] -.->|Live Sync| WS_SRC["/workspace/src"]
        NV_BUILD[("Named Volume<br/>build_data")] === WS_BUILD["/workspace/build"]
        NV_INSTALL[("Named Volume<br/>install_data")] === WS_INSTALL["/workspace/install"]
    end

    subgraph "Prod Mode (make *prod)"
        BAKED["Compiled Artifacts<br/>(COPY --from=builder)"] === PROD_INSTALL["/workspace/install"]
        NO_SRC["Source Code Excluded"] -.-> PROD_SRC["/workspace/src"]
        style NO_SRC fill:#ffcccc,color:#333,stroke:#f00,stroke-dasharray: 5 5
    end
```

---

## 🚀 Quick Start Guide

### 1. Copy Template and Initialize Project

Create an isolated new project folder on your host machine and inject the template files (Or use the **Use this template** button on GitHub).

```bash
# Copy template
mkdir -p /path/to/my_new_project
cp -r /path/to/project_template/* /path/to/my_new_project/
cp -r /path/to/project_template/.[!.]* /path/to/my_new_project/

cd /path/to/my_new_project
```

### 2. Configure Environment Variables (Core ⭐️)

Run `make setup` to generate the `.env` file, which is used to configure your isolated project environment.

```bash
make setup
nano .env
```

Within the `.env` file, **select a matching `BASE_IMAGE` and `ROS_DISTRO` pair** and modify the following values:

```ini
COMPOSE_PROJECT_NAME=my_new_project         # Unique Docker resource identifier (Must be changed)

# WORKSPACE_PATH=/path/to/my_new_project    # Absolute project path (Optional, Default: current directory)

# ROS 2 (Default)
BASE_IMAGE=ubuntu:22.04
ROS_DISTRO=humble

# ROS 1 (For legacy systems)
# BASE_IMAGE=ubuntu:20.04
# ROS_DISTRO=noetic
```

### 3. SSH Host Key Security Configuration (Optional)

To enable seamless communication with Git servers from inside the Docker container, ensure your host's private key permissions correspond correctly.

```bash
# Execute on the Host PC
chmod 600 ~/.ssh/id_rsa  # or id_ed25519
```

### 4. Start Development Environment and Check Status

```bash
make status         # Auto-detect current project configuration, GPU, Architecture, and Toolkit
make build-ros      # Build ROS image (Automatic Multi-Arch support)
make ros            # Start and enter the ROS container (Auto-detects GPU)
# OR
make dev            # Start pure C++/Python container (Auto-detects GPU)
```

---

## 💻 Running the Environment and GPU Modes

The system automatically selects the optimal hardware mode for your workstation.

| Environment | Run Command (Auto GPU Detect) | Restart | Enter Shell (Default Window) | Open New Window (GUI) |
| :--- | :--- | :--- | :--- | :--- |
| **ROS Env** | **`make ros`** | **`make ros-restart`** | **`make ros-shell`** | **`make ros-term`** |
| **Pure Dev** | **`make dev`** | **`make dev-restart`** | **`make dev-shell`** | **`make dev-term`** |

> **Tip:** You can use `make status` to verify if the current system accurately recognizes an NVIDIA GPU and the Container Toolkit, and to confirm the active architecture (AMD64/ARM64).

---

## 🛠 In-Container Development Workflow

Experience a consistent UX across any project using standard aliases and shortcuts after connecting.

### 🏁 First Setup & Initialization Scenario

If you've entered the container shell for the first time, perform the following initialization. Since development environments are orchestrated on-demand, these initial setup steps are required.

```bash
# 1. 🐍 Create Python virtual environment and download dependencies
mkenv             # Create /workspace/install/.venv and root symlink
uvs               # (Recommended) Lightning-fast dependency installation via pyproject.toml (uv sync)
# uvp -r dependencies/requirements.txt  # (Alternative) For standard pip requirements

# 2. 📦 Download ROS and C++ Third-party Dependencies
sync_deps         # Clone dependencies.repos and auto-install rosdep system packages

# 3. 🔨 Orchestrate Source Code Build
cb                # ROS: Execute colcon build (RelWithDebInfo default)
# mbuild          # Pure C++: Execute standard cmake & make
```

### 📋 Unified Command Dictionary

| Command | Description | Action |
| :--- | :--- | :--- |
| **`h` / `help`** | **Shortcut Guide** | Print a full list of available Aliases and Utility usages |
| **`hw_check`** | Hardware Diagnostics | Check GPU acceleration, **XWayland/Wayland availability**, and detailed renderer diagnostics |
| **`mbuild`** | **Standard C++ Build** | Build `src/` source code and install it to the `install/` directory |
| **`mkenv`** | **Create Python venv** | **Auto-create directory** and attach a root symlink for the `install/.venv` path |
| **`cb`** | **ROS Build** | Build `src/` source code and install it to the `install/` directory |
| **`sync_deps`** | Sync Dependencies | Synchronize external repositories based on `.repos` and merge them into the `src/thirdparty` workspace |
| **`check_deps`** | Sanity Check | Verify missing shared libraries (`*.so`) inside `install/` |

### 💡 Common Aliases

| Category | Alias | Description | Function |
| :--- | :--- | :--- | :--- |
| **ROS Build** | `cb` / `cbr` | Colcon Build | Build with `RelWithDebInfo` / `Release` profile |
| | `cbp`, `cbt` | Target Package / Test | `--packages-select`, `colcon test` |
| | `s` | Source Workspace | `source install/setup.bash` |
| **Python** | `activate` | Activate venv | `source install/.venv/bin/activate` |
| | `uvs`, `uvr` | uv commands | `uv sync`, `uv run` |
| **GPU/HW** | `gpu_status` | GPU Status Summary | Check current renderer and hardware acceleration status |
| | `gpu_setup` | Auto-detect GPU | Rescan hardware layout and reset system environment variables |
| | `vulkan_check` | Check Vulkan API | Print `vulkaninfo` hardware summary |
| **Utils** | `k` / `k9` | Terminate Process | Graceful kill (`killall`) / Force kill (`-9`) |
| **Nav** | `cw`, `cs` | Move Directory | Traverse to `/workspace`, `/workspace/src` |

---

## 🧹 Maintenance and Cleanup Commands

Utilize these integrated tasks from your host terminal to manage the project lifecycle.

| Command | Description | Action |
| :--- | :--- | :--- |
| **`make stats`** | **Resource Monitoring** | Monitor overall CPU/Memory usage across all containers and check the status of **all GPUs (NVIDIA/Intel/AMD)** |
| **`make top`** | **Detailed Monitoring** | Detailed status of CPU utilization per core mapping and comprehensive **GPU processes (NVIDIA/Intel/AMD)** tracking |
| **`make status`** | Project Status Summary | Print whether containers are actively running, display **Diagnostic engine results**, and general layout |
| **`make check-host`** | Pre-check Host Env | Prevent build errors by analyzing the GPU driver layout and X11 permission structure beforehand |
| **`make logs`** | Real-time Log Streaming | Interface with the real-time output of currently running containers (Ctrl+C to exit) |
| **`make down`** | Stop Services | Safely suspend and remove all active containers linked to the current project |
| **`make clean`** | Delete Build Artifacts | Flush build, install, log directories inside **`/workspace`** alongside temporary volumes |
| **`make clean-cache`** | Flush Compile Cache | Force deletion of the comprehensive `.docker_cache` (ccache, uv, apt) folders on the host |
| **`make clean-all`** | **Project Reset** | Completely tear down **all images, volumes, and host caches** strictly tied to the project |
| **`make docker-clean`** | **Docker System Cleanup** | Purge entire system build caches and orphaned unused images (Global Reset) |
| **`make env-check`** | **Check Env Variables** | Auto-inspect for structural discrepancies of `.env` configurations against `.env.example` |
| **`make scale-basic N=2`** | Service Scaling | (Advanced) Horizontally scale the `basic` service to N instances (e.g., `docker compose up --scale basic=2`) |

> 💡 **Tip (Non-interactive Force Execution and CI Mode)**
> To fundamentally prevent data loss, the `clean` series commands require deletion consent (`[Y/N]`) by default.
> To bypass this restriction dynamically or inject it into an automated shell script, append the `FORCE=1` argument like **`make clean FORCE=1`**.
> (※ On automation platforms like GitHub Actions or GitLab CI, the `CI=true` environment variable is automatically detected, bypassing redundant prompts without requiring script modification!)

---

## 🚀 Production Deployment Workflow

The production environment operates completely without source code, leveraging the deterministic **Bake & Switch** strategy.

```mermaid
graph TD
    A[Source Code] -->|make build-ros-prod| B(Builder Image)
    B -->|Compile & Install| C{install/ Artifacts}
    C -->|Copy| D(Runtime Image)
    D -->|make ros-prod| E[Production Service]
```

### ⚠️ Pre-Deployment Recommendations (Data Hygiene)

Before baking the production image, executing **`make clean`** is strictly recommended.

**Recommended Build Sequence:**

1. **`make clean`**: Completely obliterates any existing build residues and flushes isolated volume data.

2. **`make build-ros-prod`**: Builds (Bakes) the pristine deployment image starting from a clean state.

- **Reason:** When using bind mounts, this strictly isolates and prevents stale files or outdated build artifacts left on the host from leaking into the deployment image.

### 1. Features of the Deployment Image (`Dockerfile.prod`)

- **Explicit Source Code Exclusion**: Only the `install/` artifacts generated strictly during the compilation stage (Builder) are cleanly replicated into the final runtime image.
- **Automatic Dependency Verification (Sanity Check)**: Assures absolute runtime stability by executing an `ldd` scan during the build to verify all essential shared libraries are structurally embedded.
- **Maximized Determinism**: Maintains perfect environmental parity and isolation using APT snapshots and `uv sync --frozen`.

### 2. Deployment Service Control Commands (Auto GPU Detection)

| Category | Execute Command | Action |
| :--- | :--- | :--- |
| **ROS Deployment** | **`make ros-prod`** | Spawns a dedicated service based on optimized ROS artifacts |
| **Pure Deployment** | **`make dev-prod`** | Spawns a lightweight service strictly for C++/Python artifacts |
| **Extract Image** | **`make save-ros`** / **`save-dev`** | Wraps the deployment image as an isolated compressed archive (`.tar.gz`) |
| **Restore Image** | **`make load-ros`** / **`load-dev`** | Ingests an image from an isolated compressed archive back into the registry |

### 3. Offline Deployment Guide

When migrating a framework to an isolated edge target server restricted natively from the network, physically transfer the extracted Docker image archive.

```bash
# 1. Build the deployment image (Bake)
make build-ros-prod  # Or make build-dev-prod

# 2. Extract the physical image (Makefile-based automation)
make save-ros        # Wraps {project}-ros-{distro}.tar.gz in the project root upon success

# 3. Transmit the physical elements safely (Required variables: .tar.gz, .env, docker-compose.prod.yml, Makefile)
# Place the structurally sound .tar.gz file in the target server's physical root directory.

# 4. Ingest and spawn inside the isolated target server
make load-ros        # Automatically isolates and ingests the archive file
make ros-prod        # Spin up the target service natively
```

---

## 📡 Remote Visualization Guide for Production Environments (Prod)

The finalized production environment inherently executes in a strict **Headless mode** for maximum efficiency. Strategically isolate visualization by utilizing your **networked Dev environment laptop**.

- **ROS 2**: Match the `ROS_DOMAIN_ID` locally inside the `.env` of both the robot (Prod) and laptop (Dev), then launch `rviz2` on your laptop.
- **ROS 1**: Assign the `ROS_MASTER_URI` natively inside the `.env` to the isolated robot's IP scheme.
- **General Dev**: It is universally recommended to push telemetry securely from the server via a modern FastAPI web dashboard or WebSockets locally to the laptop's browser.

---

## 📦 External Dependency Management Strategy (SSOT Determinism)

This template adheres to a clear core principle for managing dependencies:

- **Development Environment (Dev)**: Python dependencies and ROS packages (excluding system APT packages) are **never installed automatically**. For optimal flexibility, you must mount the source code directory (`src/`) and install dependencies **On-Demand (manually)** via shortcuts (`mkenv`, `sync_deps`) from your active shell.
- **Production Deployment Environment (Prod)**: To guarantee deployment stability, all Python packages and ROS/C++ dependencies are **100% baked-in** to the image without requiring any manual intervention during the Docker build sequence.

Under this separation principle, we provide systematic dependency management methods for each ecosystem below.

```mermaid
graph LR
    subgraph "System (APT)"
        APT["apt.txt / apt_ros.txt"] --> |BuildKit Cache| DOCKER["Auto-install on Build<br/>(Dockerfile)"]
    end

    subgraph "Python (uv)"
        PYPROJ["pyproject.toml"] --> |uv sync| DOCKER
    end

    subgraph "C++ (CMake)"
        FETCH["FetchDependencies.cmake"] --> |colcon build| TARGET_B["Temp Build Space<br/>(build/)"]
    end

    subgraph "ROS (vcs)"
        REPOS["dependencies.repos"] --> |Run sync_deps| TARGET_S["Local Source Merge<br/>(src/thirdparty/)"]
    end
```

### 1. Python Layer (`uv` + `pyproject.toml`)

Python dependencies are deterministically managed using the lightning-fast `uv` package manager.

- **Multiple Formats & Conflict Prevention**: The template exclusively relies on ultra-fast `uv` as its core engine. Managing versions via `pyproject.toml` (`uv sync`) is highly recommended, while legacy `requirements.txt` (`uv pip`) approaches are also supported. To prevent dependency conflicts natively, if both files exist together, only the `pyproject.toml` process will be executed (Mutual Exclusion).
- **External Packages and Git Integration**: When pulling external sources, specifying a target branch or commit directly via `[tool.uv.sources]` inside `pyproject.toml` is the strongly recommended approach.
- **Hardware Acceleration Separation (GPU/CPU)**: Heavy deep learning libraries (e.g., PyTorch) should be cleanly separated using `optional-dependencies`.

  ```toml
  # pyproject.toml structural isolation strategy
  [project.optional-dependencies]
  cpu = ["torch==2.9.1"]
  gpu = ["torch==2.9.1"]

  [tool.uv.sources]
  torch = [
      { index = "pytorch-cpu", extra = "cpu" },
      { index = "pytorch-cu128", extra = "gpu" },
  ]
  ```

  Assigning `UV_SYNC_FLAGS="--extra gpu"` in your `.env` file ensures the template automatically installs the correct, optimized packages during Docker build and setup.

### 2. C++ & ROS Layer (`CMake` + `dependencies.repos`)

For C++ and ROS environments, you can manage dependencies through two primary methods:

- **`FetchDependencies.cmake` (Build-time Linking)**: Use this to instantly download specific libraries from GitHub during the `CMakeLists.txt` build time for static/dynamic linking. You can directly edit this file to freely add required C++ dependencies like `nlohmann_json` or `spdlog`.
- **`dependencies.repos` (Source-level Sync)**: Useful for pulling uncompiled source code of external libraries that you need to modify alongside your own project (Editable mode).
  - **Auto Sync**: Define targets in `dependencies/dependencies.repos` to automatically clone them into the `src/thirdparty` directory upon container startup (`make dev` or `make ros`).
  - **Overlay Structure**: Files placed inside the `dependencies/overlay/` directory will safely overwrite the cloned source targets after synchronization completes.

### 3. Build Speed and Dependency Optimization (`config/colcon.meta`)

Building massive external C++/ROS libraries (Eigen3, GTSAM, Librealsense2, etc.) directly from source can result in excessively long build times due to test compilation, or cause runtime conflicts (e.g. Eigen ODR Violation).

- The built-in `config/colcon.meta` file solves this by automatically injecting custom CMake options into specific packages during a `colcon build`.
- **Core Examples**: The default configurations completely disable unnecessary test compilations (`BUILD_TESTING=OFF`) to speed up builds, and enforce the use of system libraries (`GTSAM_USE_SYSTEM_EIGEN=ON`) to prevent memory conflicts.
- **Customization (ROS)**: You can easily add package names and their custom CMake arguments to this file to orchestrate the entire workspace compile process.
- **Customization (C++)**: For pure C++ builds without `colcon`, utilize the `CMAKE_EXTRA_ARGS` variable in `.env`.
  - For a few options: Pass them directly, e.g., `CMAKE_EXTRA_ARGS="-DBUILD_TESTING=OFF -DGTSAM_USE_SYSTEM_EIGEN=ON"`.
  - For many options: Write them to a file (e.g., `config/cmake_cache.cmake` with `set(BUILD_TESTING OFF CACHE BOOL "" FORCE)`) and inject the file via `CMAKE_EXTRA_ARGS="-C /workspace/config/cmake_cache.cmake"`.

### 4. System Layer (APT Packages)

- **Method**: Specify any required OS-level Linux packages in `dependencies/apt.txt` (General) or `dependencies/apt_ros.txt` (ROS-specific).
- Packages that must also be present in the final deployment image should have a `# runtime` comment at the end of the line. These will be efficiently installed utilizing BuildKit cache during image generation.

---

## ⚠️ Security and Architectural Constraints (Security Notes)

1. **`root` Privilege Parity**: Both development and deployment containers operate as the `root` user. This resolves file ownership issues of mounted host volumes and elevates device accessibility.
2. **`privileged: true`**: To freely utilize devices like sensors, USBs, and CAN communications during ROS development, the development container runs in privileged mode.
3. **`network_mode: host`**: Directly uses the host network for optimal DDS communication performance in ROS. To prevent interference across multiple projects, configure a unique `ROS_DOMAIN_ID` in `.env`.

---

## 📄 License and Usage Guidelines (License & Usage)

The boilerplate code and configuration files in this **DevKit** repository are distributed under the **[MIT-0 (MIT No Attribution)](LICENSE)** license.

- **No Attribution Required**: There is absolutely no need to specify the original source or author of this template in your code. Freely utilize it completely unrestricted for any purpose including commercial, internal private networks, or personal open source.
- **Freely Replaceable**: When using this template for a new project, you can safely delete the root `LICENSE` file or comfortably overwrite it with a license that matches your project's needs.
