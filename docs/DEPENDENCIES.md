# 📦 DevKit 의존성 관리 가이드

`src/pyproject.toml`(Python), `CMake`/`dependencies.repos`(C++·ROS),
`dependencies/apt*.txt`(시스템 패키지) 세 레이어를 다룹니다.
기본 워크플로우는 [DEVELOPMENT.md](DEVELOPMENT.md)에 있습니다.

---

## ⚙️ 고급 의존성 제어 및 커스텀 (Advanced Dependency Management)

### 1. Python 레이어 (`src/pyproject.toml` & `uv`)
`pyproject.toml`을 통해 CPU/GPU 환경에 따른 파이썬 패키지(예: PyTorch 등) 분기 및 인덱스 설정을 관리합니다.

```toml
[project.optional-dependencies]
cpu = [ "torch==2.11.0", "torchvision" ]
gpu = [ "torch==2.11.0", "torchvision" ]

[[tool.uv.index]]
name = "pytorch-cpu"
url = "https://download.pytorch.org/whl/cpu"
explicit = true

[[tool.uv.index]]
name = "pytorch-cu128"
url = "https://download.pytorch.org/whl/cu128"
explicit = true
```
> **`UV_EXTRA` 자동 선택**: `setup_gpu.sh`가 GPU를 감지하면 `~/.gpu_env.sh`에 `UV_EXTRA=gpu`(NVIDIA 계열) 또는
> `UV_EXTRA=cpu`를 기록하고, `uvs`/`mksync`가 이를 `uv sync --extra <값>`으로 사용합니다.
> 수동으로 덮어쓰려면 `.env`에 `UV_SYNC_FLAGS="--extra gpu"`를 지정하거나 `mksync --extra gpu`를 실행하세요.

`extras`(cpu/gpu)와 달리 **`[dependency-groups] dev`는 런타임 의존성이 아니라 도구**이며
`uv sync`가 기본으로 설치합니다 — `mtest`/`mlint`의 러너(`pytest`, `ruff`)가 여기 있습니다.
프로덕션 빌드(`DEVKIT_BUILD_TYPE=prod`)는 `--no-default-groups`로 제외하므로 배포 venv에는
들어가지 않습니다.

```toml
[dependency-groups]
dev = [ "ruff>=0.6", "pytest>=8" ]   # 정확한 버전은 파생 프로젝트의 uv.lock이 고정
```

### 2. C++ & ROS 레이어 (`CMake` + `dependencies.repos`)
- **`FetchDependencies.cmake`**: `CMakeLists.txt` 빌드 시점에 GitHub 라이브러리(예: `spdlog`, `nlohmann_json`)를 동적으로 다운로드 및 링크.
- **`dependencies.repos` & `overlay/`**: 외부 레포지토리 소스를 `src/thirdparty`로 자동 복사하며, `overlay/` 폴더 내 파일로 커스텀 덮어쓰기 보장.
- **`colcon.meta` & `CMAKE_EXTRA_ARGS`**: 대용량 외부 빌드 시간 단축(`BUILD_TESTING=OFF`) 및 GTSAM/Eigen 메모리 충돌(ODR Violation) 방지 옵션 주입.
  `colcon.meta` 는 `cbuild --meta` 로 전달됩니다(전달하지 않으면 colcon 이 읽지 않습니다).
- **`OPENCV_CUDA`**: OpenCV 를 소스에서 빌드하는 프로젝트를 위한 CMake 플래그를 `cbuild`/`mbuild` 에 **자동 주입**합니다.
  `auto` 는 NVIDIA 런타임과 `nvcc` 가 모두 있을 때만 CUDA 를 켜고(없으면 `-DWITH_CUDA=OFF`), 감지된 GPU 아키텍처만
  컴파일합니다(`-DCUDA_ARCH_BIN=<compute_cap>+PTX`). 값만 확인하려면 `gpu opencv_args`.

### 3. 시스템 패키지 태깅 규칙 (`dependencies/apt.txt`, `dependencies/apt_ros.txt`)

프로덕션 이미지 용량을 최소화하기 위해 패키지 줄 끝 주석에 태그를 지정합니다. 태그 해석은
`scripts/util_apt_helper.sh install-packages <all|builder|runtime> [ros_distro]`가 단독으로 담당합니다.

| 태그 | 의미 |
| :--- | :--- |
| `# runtime` | 배포 산출물에 반드시 포함될 실행 필수 패키지 |
| `# dev` | 개발 컨테이너 전용 빌드 도구 (프로덕션 빌더/런타임에서 제외) |
| `# gui` | RViz, RQT 등 GUI 전용 패키지 (프로덕션 헤드리스 빌드에서 제외) |
| `# ros1` / `# ros2` | 해당 ROS 세대에서만 설치 (`ros-${ROS_DISTRO}-*` 는 자동 치환) |
| *(태그 없음)* | 개발 이미지와 프로덕션 **빌더**에 설치, 런타임에서는 제외 |

**필터 모드별 선택 결과:**

| 모드 | 사용처 (Dockerfile 스테이지) | 선택 대상 |
| :--- | :--- | :--- |
| `all` | `dev`, `ros` (개발 이미지) | `# dev`/`# gui` 포함 전체 (반대 ROS 세대만 제외) |
| `builder` | `prod-*-builder` | `# dev`, `# gui` 제외 |
| `runtime` | `prod-*-runtime` | `# runtime` 태그가 붙은 항목만 |

> [!IMPORTANT]
> **`ros_distro` 인자를 생략하면 `apt_ros.txt`는 아예 읽지 않습니다.** ROS apt 저장소를 설정하지 않는 비-ROS 스테이지
> (`dev`, `prod-dev-builder`, `prod-dev-runtime`)가 `ros-*` 패키지를 요구해 빌드가 실패하는 것을 막는 계약이며,
> `make verify` [apt-tag-filter]이 이를 자동 검증합니다.
>
> 선택 결과는 설치 없이 미리 확인할 수 있습니다:
> ```bash
> DEVKIT_DRY_RUN=1 DEVKIT_DEPS_DIR=./dependencies \
>   bash scripts/util_apt_helper.sh install-packages runtime humble
> ```
