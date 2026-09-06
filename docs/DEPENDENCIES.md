# 📦 DevKit 의존성 관리 가이드

`src/pyproject.toml`(Python), `CMake`/`dependencies.repos`(C++·ROS),
`dependencies/apt*.txt`(시스템 패키지) 세 레이어를 다룹니다.
기본 워크플로우는 [DEVELOPMENT.md](DEVELOPMENT.md)에 있습니다.

---

## 🖥️ 호스트 전제 (Host Prerequisites)

아래 세 레이어는 **컨테이너 안**의 의존성입니다. 그 앞에 호스트에 있어야 하는 것들이며,
필수 항목은 `make build` 전에 `scripts/check_preflight.sh` 가 검사합니다
(`make check`). 검사 대상과 이 표는 계약 `[host-prereqs]` 로 묶여 있어 한쪽만
바뀌면 `make verify` 가 실패합니다.

| 도구 | 필요 시점 | 없으면 |
| :--- | :--- | :--- |
| **Docker Engine** + Compose v2 `2.24+` + BuildKit/buildx | 항상 | preflight 차단 |
| **python3** | `make verify`, 호스트 환경 감지 | preflight 차단 |
| **git** | `make adopt`, 아티팩트의 `git_commit`, `safe.directory` 설정 | preflight 차단 |
| **curl**, **gpg** | `make update-gpg` (아카이브 서명키 확인) | preflight 경고 |
| **xauth** | GUI/X11 전달 (컨테이너가 읽을 쿠키를 씀) | preflight 경고 |
| **nvidia-container-toolkit** | `GPU_MODE=nvidia` 로 빌드/실행할 때 | 해당 모드에서만 차단 |
| **apptainer** 또는 **singularity** | `make bake-dev` / `make bake-prod`, `make run-sif` | 해당 명령이 명확히 실패 |
| **sbatch / srun** | `SIF_MODE=slurm` 제출 호스트 | 해당 명령이 명확히 실패 |

> `vcstool` 은 호스트가 아니라 **이미지 안**에 있습니다 — `dependencies/apt_ros.txt` 의
> `python3-vcstool` 이며 `sync_deps` 는 컨테이너 셸에서 실행됩니다.
> GPU 드라이버 자체(`nvidia-smi`)는 호스트에 있어야 하지만 DevKit 이 설치하지 않습니다.

---

## ⚙️ 고급 의존성 제어 및 커스텀 (Advanced Dependency Management)

### 1. Python 레이어 (`src/pyproject.toml` & `uv`)
`pyproject.toml`을 통해 CPU/GPU 환경에 따른 파이썬 패키지(예: PyTorch 등) 분기 및 인덱스 설정을 관리합니다.
아래 블록은 템플릿 `pyproject.toml`에 **주석으로** 들어 있습니다 — 템플릿의 lock 을 작게 유지하고, 필요 없는
프로젝트가 torch 해석 비용을 내지 않게 하기 위해서입니다. 필요하면 주석을 풀고 `mksync`로 lock 을 갱신하세요.

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
> **`UV_EXTRA` 는 선언합니다** — `.env.example`(팀 공유) 또는 `.env`(로컬)에 적으면 `uvs`/`mksync`가
> `uv sync --extra <값>`으로 씁니다. 감지 결과에서 유도하지 않습니다: extra 는 **빌드한 기계가 아니라
> 배포 대상**을 기술하므로, GPU 없는 CI 러너에서도 `UV_EXTRA=gpu` 이미지를 빌드할 수 있어야 합니다.
> 수동으로 덮어쓰려면 `.env`에 `UV_SYNC_FLAGS="--extra gpu"`를 지정하거나 `mksync --extra gpu`를 실행하세요 — 둘 다 `pyproject.toml` 이 그 extra 를 선언한 뒤의 이야기입니다.

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
  `auto` 는 `nvcc` 가 있으면 CUDA 를 켭니다(없으면 `-DWITH_CUDA=OFF`). 판단 기준은 빌드 호스트의 GPU 가 아니라
  툴체인입니다 — GPU 없는 빌더에서도 CUDA 이미지를 만들 수 있어야 하기 때문입니다. 감지된 GPU 아키텍처만
  컴파일합니다(`-DCUDA_ARCH_BIN=<compute_cap>+PTX`). 값만 확인하려면 `gpu opencv_args`.

#### 동기화 실패 정책

`sync_deps` / `setup_sync_deps.sh`(그리고 그것을 부르는 `mksync`·첫 실행 동기화·prod 빌더)는 vcs import·pull·submodule·rosdep 이
실패하면 **즉시 중단**합니다 — 의존성이 빠진 워크스페이스나 배포물이 조용히 만들어지는 것을 막기 위해서입니다.
오프라인·사설 저장소 등으로 일부만 받고 진행해야 할 때만 `DEVKIT_VCS_ALLOW_FAILURE=1`(vcs 계열) 또는
`DEVKIT_ROSDEP_ALLOW_FAILURE=1`(rosdep)로 fail-open 을 명시적으로 켭니다(`.env` 또는 `make start … DEVKIT_VCS_ALLOW_FAILURE=1`).
릴리스는 `DEVKIT_REQUIRE_PINNED=1`(prod bake 기본)로 `.repos` 의 모든 항목이 40자 커밋 해시인지도 검사합니다 — [DEPLOY.md 재현성](DEPLOY.md#-재현성-reproducibility--현재-보장-범위).

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
| `builder` | `builder-base-*` → `prod-builder` | `# dev`, `# gui` 제외 |
| `runtime` | `prod-runtime` | `# runtime` 태그가 붙은 항목만 |

> [!IMPORTANT]
> **`ros_distro` 인자를 생략하면 `apt_ros.txt`는 아예 읽지 않습니다.** ROS apt 저장소를 설정하지 않는 비-ROS 스테이지
> (`dev`, 그리고 `PROD_ENV=dev` 의 `prod-builder`·`prod-runtime`)가 `ros-*` 패키지를 요구해 빌드가 실패하는 것을 막는 계약이며,
> `make verify` [apt-tag-filter]이 이를 자동 검증합니다.
>
> 선택 결과는 설치 없이 미리 확인할 수 있습니다:
> ```bash
> DEVKIT_DRY_RUN=1 DEVKIT_DEPS_DIR=./dependencies \
>   bash scripts/util_apt_helper.sh install-packages runtime humble
> ```

---

## 🔌 opt-in 기능 되살리기

기본 이미지를 가볍게 두기 위해 꺼 놓은 것들입니다. 전부 **주석 한 줄을 풀고 다시 빌드**하는 방식이며,
`make verify` 가 예시가 낡지 않았는지 검사합니다.

| 기능 | 켜는 방법 | 그 다음 |
| :--- | :--- | :--- |
| **`make term` (terminator 2×2 터미널)** | `dependencies/apt.txt` 의 `# terminator # gui` → `terminator # gui` | `make build && make start && make term`. 다른 터미널을 쓰려면 그 패키지를 `# gui` 로 추가하고 `.env` 에 `TERMINAL=<이름>` |
| **터미널 폰트 (D2Coding)** | [github.com/naver/d2codingfont](https://github.com/naver/d2codingfont/releases) 의 zip 을 `dependencies/D2Coding.zip` 으로 저장 → `config/terminator_config` 에서 `use_system_font = True` 를 `False` 로 바꾸고 `font`·`title_font` 두 줄의 주석 해제 | `make build`. 이미지 빌드는 GitHub 에서 아무것도 내려받지 않으므로 파일이 없으면 시스템 폰트를 씁니다 |
| **`clang-format` (mlint 의 C/C++ 절반)** | `dependencies/apt.txt` 의 `# clang-format # dev` → `clang-format # dev` | `make build`. 에디터는 C/C++ 확장 내장 복사본을 쓰므로 CLI 검사가 필요할 때만 |
| **PyTorch cpu/gpu extras** | `src/pyproject.toml` 의 `# --- opt-in example: begin/end ---` 사이 모든 줄과, 아래 `[tool.uv]` 테이블 안의 `# conflicts = …` 한 줄에서 앞의 `# ` 를 지움 | `.env.example`(팀) 또는 `.env` 에 `UV_EXTRA=cpu` 나 `gpu` → 컨테이너에서 `mksync` → `git add src/uv.lock` 커밋. 확인은 `pyt`(torch 가 보는 장치) |

> extras 예시의 `conflicts` 줄이 예시 블록 밖에 있는 이유: `[tool.uv]` 테이블은 이미 `package = false` 로
> 선언되어 있고, TOML 은 같은 테이블을 두 번 선언할 수 없기 때문입니다.

