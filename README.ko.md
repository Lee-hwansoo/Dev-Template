<!-- markdownlint-disable MD041 -->
<!-- markdownlint-disable MD033 -->

<p align="center">
  <img src="docs/images/logo.png" width="220" alt="DevKit Logo">
</p>

<h1 align="center">All-in-One Docker DevKit</h1>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ko.md">한국어</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/ROS-Noetic-blue?logo=ros" alt="ROS1">
  <img src="https://img.shields.io/badge/ROS2-Humble-red?logo=ros" alt="ROS2">
  <img src="https://img.shields.io/badge/Python-3.10-3776AB?logo=python" alt="Python">
  <img src="https://img.shields.io/badge/C%2B%2B-17-00599C?logo=c%2B%2B" alt="C++">
  <img src="https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker" alt="Docker">
</p>

<p align="center">
  본 저장소는 호스트 시스템을 오염시키지 않고 <b>C++, Python(uv), ROS 1 / ROS 2</b> 개발을 수행할 수 있도록 설계된 <b>독립 개발 환경 템플릿</b>입니다. 복잡한 설정 없이 어떤 프로젝트에서든 즉시 개발을 시작하세요.
</p>

## 💡 핵심 가치 (Why this Template?)

- **Zero-Pollution (격리)**: 호스트 PC에는 Docker만 설치하세요. 모든 라이브러리와 의존성은 컨테이너가 관리하여 시스템 충돌을 방지합니다.
- **Hardware Agnostic (범용성)**: NVIDIA, Intel, AMD GPU를 자동 감지합니다. **X11은 물론 최신 Wayland 환경**에서도 하드웨어 가속을 즉시 제공합니다.
- **Production Ready (운영)**: 개발 환경 아티팩트를 그대로 운영 이미지로 빌드하는 **Bake & Switch** 전략과 **의존성 자동 검증(Sanity Check)** 기능을 내장하고 있습니다.
- **Unified Workspace (표준)**: 모든 프로젝트가 동일한 디렉토리 구조(`src`, `build`, `install`)를 따라 팀 협업과 유지보수가 비약적으로 쉬워집니다.

## 🌟 주요 기능 (Features)

- **지능형 진단 엔진**: `make status` 시 호스트의 GPU, 아키텍처(AMD64/ARM64), 디스플레이 서버 및 **Wayland 소켓 경로**를 정밀 진단하여 최적의 환경을 자동 구성합니다.
- **Unified Workspace (Everything is a Package)**: 모든 프로젝트(C++, Python, ROS)가 **`src/` (소스), `build/` (빌드), `install/` (아티팩트)** 표준 구조를 강제하여 개발과 배포의 일관성을 극대화합니다.
- **APT Snapshot 기반 완벽한 재현성**: `APT_SNAPSHOT_DATE`를 통해 특정 시점의 패키지 버전을 고정하여 100% 재현성을 보장합니다. 호스트 터미널에서 `date -u +%Y%m%dT%H%M%SZ`를 실행해 얻은 UTC 날짜를 `.env`에 입력하면 그 시점으로 환경이 영구 동결됩니다.
- **런타임 의존성 가디언 (Sanity Check)**: 배포 이미지 빌드 시 `ldd`를 활용하여 실행 파일 및 라이브러리의 의존성 누락을 자동 검사, 실행 시점의 'Shared library not found' 에러를 원천 차단합니다.
- **초경량/고보안 배포 (Bake & Switch)**: 배포용 이미지 빌드 시 소스 코드를 제외하고 `install/` 아티팩트만 포함하여 보안성과 효율성을 동시에 잡았습니다.
- **Multi-Arch 빌드 지원**: 단일 Dockerfile로 x86(Intel/AMD) 및 ARM64(Jetson, Apple Silicon) 환경 모두에서 오버헤드 없이 해당 CPU의 네이티브 성능으로 구동됩니다.
- **일관된 권한 체계 (Root Unity)**: 개발과 배포 환경 모두 `root` 유저를 사용하여 호스트 볼륨 마운트 시의 권한 충돌을 방지했습니다.
- **완벽한 Zero-Pollution (Sudo-Free 아키텍처)**: 호스트 스토리지 정리(`make clean`) 시 `sudo` 권한을 요구하지 않도록 초경량 1회용 컨테이너를 스폰하여 무권한 삭제(Sudo-Free)를 수행합니다. 작업 직후 컨테이너와 이미지가 스스로 자폭하여 로컬 환경에 어떠한 찌꺼기도 남기지 않습니다.
- **CI/CD 강건성 (비대화형 파이프라인 지원)**: 대화형 프롬프트를 자동으로 우회하는 `FORCE=1` 플래그 및 플랫폼의 `CI=true` 환경변수 자동 감지 기능이 내장되어 있어, GitHub Actions나 GitLab CI 같은 자동화 서버 환경에서도 멈춤 없이 완벽하게 동작합니다.

---

## 🎯 아키텍처 철학 및 기술 포지셔닝

DevKit은 단순한 가상화 환경 구축 도구(Tool)를 넘어, 프로젝트의 전체 생애 주기를 관리하는 **종합 아키텍처 템플릿(Architecture Template)**을 지향합니다.

기존의 개발 도구들이 컨테이너 환경의 격리나 단일 프레임워크 지원에 집중되어 있는 반면, DevKit은 **ROS 및 범용 C++/Python 코어 개발 환경, 멀티 GPU 네이티브 패스스루, 프로덕션 배포 파이프라인**을 단일 시스템으로 통합하여 제공합니다. 이를 통해 프레임워크(ROS, 순수 C++, Python)에 구애받지 않고 일관된 베스트 프랙티스 워크스페이스 구조를 조직 내에 강제할 수 있으며, 개발 환경부터 운영 환경까지 하나의 흐름으로 이어지는 일관성을 보장합니다.

> ※ Bake & Switch: 개발 환경에서 검증된 레이어를 기반으로, 실행에만 필요한 런타임 종속성만 남긴 채 프로덕션 이미지를 굽고 현장에 즉시 배포하는 전략

| 시스템 | ROS 특화 | GPU 자동감지 | 멀티-아키텍처(x86/ARM) | 재현성 (Reproducibility) | 운영 배포 (Production) | 진입 장벽 |
| --- | --- | --- | --- | --- | --- | --- |
| **DevKit** | O (순수 C++/Python 포함) | O (NVIDIA/Intel/AMD) | O (OS Native) | Pinned (APT 스냅샷) | O (Bake & Switch) | 낮음 |
| VS Code Dev Containers | X (범용 중심) | X | O (보편적 지원) | 보통 | X | 낮음 |
| Rocker | O | O (NVIDIA/Intel) | O (Docker 기반) | X | X | 낮음 |
| NVIDIA Isaac ROS | O | NVIDIA 전용 | X (Jetson/x86 한정) | Image-pinned | O | 중간 |
| ADE (Apex.AI) | O (Autoware 중심) | 수동 설정 | O (보편적 지원) | 보통 | X | 중간 |
| RoboStack (Conda) | O | X (패키지에 의존) | O (OS 의존적) | 보통 (Conda 의존) | X | 낮음 |
| Distrobox / Toolbx | X | O (호스트 자원 공유) | O (호스트 커널 공유) | X (호스트 종속적) | X | 낮음 |
| Singularity (Apptainer) | X | O (NVIDIA/AMD 옵션) | O (보편적 지원) | 높음 (단일 이미지 파일) | O (HPC 중심) | 높음 |
| Nix / NixOS Flakes | 어려움 | 수동 설정 | O (완벽한 크로스 빌드) | 극강 (OS Level Pinned) | O | 매우 높음 |
| Earthly | X | 수동 설정 | O (보편적 지원) | 보통 (빌드 격리) | X (빌더 중심) | 중간 |

> **참고:** Bazel은 압도적인 빌드 캐싱을 제공하나 컨테이너 기반 개발환경보다는 순수 빌드 도구에 가까워 위 표에서는 제외하였으며, 하단 상세 비교에서 특징을 확인하실 수 있습니다.

<!-- markdownlint-disable MD033 -->
<details>
<summary><b>🔍 각 시스템별 장단점 상세 비교 (클릭하여 펼치기)</b></summary>

### 1. VS Code Dev Containers (Microsoft)

- **유사점**: `devcontainer.json`으로 컨테이너 기반 격리 환경 제공
- **우위**: VS Code / GitHub Codespaces와 네이티브 통합, 커뮤니티 템플릿 풍부
- **한계**: GPU 자동 감지 부재, ROS 특화 워크플로우 부재, 배포 이미지 생성 전략 부재

### 2. Rocker (Open Robotics)

- **유사점**: ROS 개발을 위한 컨테이너에 NVIDIA/Intel GPU, X11/Wayland 패스스루 지원
- **우위**: ROS 커뮤니티의 성숙하고 널리 사용되는 표준 도구, 플러그인 확장성
- **한계**: 워크스페이스 구조 강제성 없음, APT 스냅샷 등 엄격한 재현성 보장 부족, 운영 이미지 빌드(Bake) 파이프라인 부재

### 3. NVIDIA Isaac ROS

- **유사점**: ROS 2 + GPU 개발환경 컨테이너화
- **우위**: NVIDIA 하드웨어에 극도로 최적화된 성능, cuVS/CUDA 라이브러리 네이티브 통합
- **한계**: NVIDIA 생태계 종속 (AMD/Intel 미지원), 오픈소스 커스터마이징의 한계

### 4. Bazel (Google)

- **유사점**: 완벽하게 통제되는 의존성과 빌드 환경을 통한 재현성(Reproducibility) 추구
- **우위**: 거대한 모노레포에서의 압도적인 캐싱 최적화, 완벽하게 격리된 밀폐형(Hermetic) 빌드
- **한계**: ROS / GPU / 파이썬 모던 스택(uv 등)과 연동 시 극심한 고통 수반, 기존 CMake/colcon 생태계를 `BUILD` 파일로 다시 짜야 하는 천문학적인 유지보수 비용과 러닝 커브 발생 (개발/디버깅 환경 자체를 제공하는 컨테이너 환경이라기보단 빌드 도구에 가까움)

### 5. Nix / NixOS Flakes

- **유사점**: 패키지 버전 고정을 통한 완전한 재현성
- **우위**: Docker 없이도 운영체제 레벨의 재현성 보장, 극강의 의존성 결정론
- **한계**: 함수형 패키지 관리에 대한 가파른 학습 곡선, ROS/GPU 환경 구성의 복잡함, 높은 팀 온보딩 비용

### 6. Earthly

- **유사점**: Makefile + Dockerfile 개념을 통합한 빌드 자동화
- **우위**: CI/CD 대규모 자동화 파이프라인 통합 및 병렬 캐싱 전략 우수
- **한계**: 대화형 로컬 개발 환경(셸 진입, 디스플레이/GPU 패스스루 등)보다는 '빌드 자동화 도구'에 집중되어 있음

### 7. ADE (Agile Development Environment by Apex.AI)

- **유사점**: ROS(주로 Autoware) 생태계에 특화된 컨테이너 기반 개발 환경 도구
- **우위**: Base, System, User 등 다중 Docker 이미지의 볼륨을 겹쳐서(Overlay) 배포하는 데 최적화됨
- **한계**: 다중 이미지 레이어 설계가 가벼운 단일 프로젝트 단위에서는 오버헤드가 될 수 있으며, 프로덕션 배포 파이프라인(Bake)보다는 로컬 개발 편의에 집중되어 있음

### 8. RoboStack (Conda)

- **유사점**: ROS 1/2 환경을 로컬 시스템에 쉽게 설치할 수 있도록 지원
- **우위**: Docker 같은 격리된 컨테이너 없이, macOS나 Windows에서도 `conda` 환경만으로 ROS를 가볍게 구동 가능
- **한계**: 시스템 레벨의 격리(Isolation)가 이루어지지 않아 OS 패키지 충돌 위험이 존재하며, 컨테이너 기반의 완벽한 운영 배포(Production) 파이프라인이 부재함

### 9. Distrobox / Toolbx

- **유사점**: 호스트 OS 위에 리눅스 개발 환경을 격리된 컨테이너로 제공
- **우위**: 컨테이너가 호스트의 홈 디렉토리, X11/Wayland, 오디오, USB 등을 `root` 없이 마법처럼 전부 공유하여 네이티브 머신처럼 매끄럽게 동작함
- **한계**: 호스트와 너무 강하게 결합되어 있어 진정한 의미의 '순수 격리 및 재현성'을 잃을 수 있으며, 프로젝트 단위의 아티팩트 분리나 ROS 특화 편의성을 제공하지 않음

### 10. Singularity / Apptainer

- **유사점**: Docker를 대체할 수 있는 고성능 격리 컨테이너 솔루션
- **우위**: Root 권한이 필요 없는(Rootless) 구조 덕분에 대학원 연구실, HPC 클러스터 등 보안이 엄격한 환경에서 널리 쓰임
- **한계**: 생태계가 과학 컴퓨팅 및 슈퍼컴퓨터에 집중되어 있어 데스크톱 수준의 개발 편의성(GUI 패스스루 등) 확보가 까다로우며, 일반적인 ROS/웹 개발자에게는 낯설고 진입 장벽이 높음

</details>
<!-- markdownlint-enable MD033 -->

---

## 🏗 멀티스테이지 도커 아키텍처 (Multi-stage Architecture)

본 템플릿은 빌드 속도와 캐시 효율을 극대화하기 위해 세분화된 빌드 파이프라인을 사용합니다.

```mermaid
graph TD
    A[Base OS] --> B[dev-base-tools <br/> Utilities/Build/GUI]
    B --> C[dev-core <br/> Python & Core Config]
    C --> D[dev <br/> Dev Targets]
    C --> E[builder <br/> Bake]
    E --> F[runtime <br/> Lightweight Prod]
```

---

## 🚀 표준 워크스페이스 구조 (Standard Layout)

모든 프로젝트는 언어와 프레임워크에 상관없이 다음 구조를 따릅니다.

- **`src/`**: 모든 소스 코드 및 빌드 설정 (CMakeLists.txt, pyproject.toml 등)
- **`build/`**: 컴파일러와 빌드 시스템이 사용하는 임시 빌드 공간
- **`install/`**: 최종 실행 파일, 라이브러리, Python 가상환경(`.venv`)이 모이는 **배포 아티팩트** 폴더
  - *Note: Python 가상환경을 `install/` 내부에 두어 배포 시 소스 없이도 독립적인 실행이 가능하도록 설계되었습니다. IDE 호환성을 위해 프로젝트 루트에 `.venv` 심볼릭 링크가 생성됩니다.*

```mermaid
graph LR
    subgraph "Dev Mode (make dev / ros)"
        SRC["호스트: src/<br/>(Bind Mount :rw)"] -.->|실시간 동기화| WS_SRC["/workspace/src"]
        NV_BUILD[("Named Volume<br/>build_data")] === WS_BUILD["/workspace/build"]
        NV_INSTALL[("Named Volume<br/>install_data")] === WS_INSTALL["/workspace/install"]
    end

    subgraph "Prod Mode (make *prod)"
        BAKED["컴파일된 아티팩트<br/>(COPY --from=builder)"] === PROD_INSTALL["/workspace/install"]
        NO_SRC["소스코드 제외 (격리)"] -.-> PROD_SRC["/workspace/src"]
        style NO_SRC fill:#ffcccc,color:#333,stroke:#f00,stroke-dasharray: 5 5
    end
```

---

## 🚀 빠른 시작 가이드 (Quick Start)

### 1. 템플릿 복사 및 새로운 프로젝트 생성

호스트 PC에서 독립된 새 프로젝트 폴더를 만들고 템플릿 파일들을 복사합니다. (또는 GitHub의 **Use this template** 버튼 사용)

```bash
# 템플릿 복사
mkdir -p /path/to/my_new_project
cp -r /path/to/project_template/* /path/to/my_new_project/
cp -r /path/to/project_template/.[!.]* /path/to/my_new_project/

cd /path/to/my_new_project
```

### 2. 환경 변수 초기화 및 설정 (핵심 ⭐️)

`make setup`을 통해 프로젝트 전용격리 환경을 구성하기 위한 `.env` 파일을 생성합니다.

```bash
make setup
nano .env
```

`.env` 파일 내에서 **BASE_IMAGE와 ROS_DISTRO를 짝지어 선택**하고 다음 항목을 수정해야 합니다.

```ini
COMPOSE_PROJECT_NAME=my_new_project         # 도커 리소스 고유 식별자 (필수 변경)

# WORKSPACE_PATH=/path/to/my_new_project    # 프로젝트 절대 경로 (선택 사항, 기본값: 현재 경로)

# ROS 2 (기본)
BASE_IMAGE=ubuntu:22.04
ROS_DISTRO=humble

# ROS 1 (레거시 전환 시)
# BASE_IMAGE=ubuntu:20.04
# ROS_DISTRO=noetic
```

### 3. SSH 호스트 키 보안 설정 (선택 사항)

도커 컨테이너에서 깃(Git) 서버와 원활히 통신하려면 호스트의 개인키 권한을 확인해야 합니다.

```bash
# 호스트 PC에서 실행
chmod 600 ~/.ssh/id_rsa  # 또는 id_ed25519
```

### 4. 개발 환경 시작 및 상태 확인

```bash
make status         # 현재 프로젝트 설정 및 GPU/아키텍처/툴킷 자동 감지
make build-ros      # ROS 이미지 빌드 (Multi-Arch 자동 대응)
make ros            # ROS 컨테이너 시작 및 진입 (GPU 자동 감지)
# 또는
make dev            # 순수 C++/Python 컨테이너 시작 (GPU 자동 감지)
```

---

## 💻 GPU 및 개발 환경 실행 방법

시스템이 최적의 모드를 자동으로 선택합니다.

| 환경 구분     | 실행 (GPU 자동 감지) | 중지 (Stop)            | 재시작 (Restart)       | 셸 진입 (기본 창)    | 새 창 띄우기 (GUI)  |
| :------------ | :------------------- | :--------------------- | :--------------------- | :------------------- | :------------------ |
| **ROS 환경**  | **`make ros`**       | **`make ros-stop`**    | **`make ros-restart`** | **`make ros-shell`** | **`make ros-term`** |
| **순수 개발** | **`make dev`**       | **`make dev-stop`**    | **`make dev-restart`** | **`make dev-shell`** | **`make dev-term`** |

> **Tip:** `make status`를 통해 현재 시스템이 NVIDIA GPU와 Container Toolkit을 올바르게 인식하고 있는지, 그리고 현재 아키텍처(AMD64/ARM64)가 무엇인지 확인할 수 있습니다.

---

## 🛠 컨테이너 내부 개발 워크플로우

어떤 프로젝트든 접속 후 동일한 단축키(Alias)로 일관된 UX를 경험할 수 있습니다.

### 🏁 첫 접속 시 초기화 및 빌드 시나리오 (First Setup & Build)

새 프로젝트를 시작하거나 템플릿을 처음 복사한 뒤 컨테이너 쉘에 들어왔다면, 아래 순서대로 1회 초기화를 진행하세요. (개발 환경은 On-Demand 방식이므로 수동 세팅이 필요합니다.)

```bash
# 1. 🐍 Python 가상환경 생성 및 의존성 다운로드
mkenv             # /workspace/install/.venv 생성 및 루트 링킹
uvs               # (권장) pyproject.toml 기반 의존성 초고속 설치 (uv sync)
# uvp -r dependencies/requirements.txt  # (대안) requirements.txt 사용자용

# 2. 📦 ROS 및 C++ 서드파티 의존성 다운로드
sync_deps         # dependencies.repos 클론 및 rosdep 의존성 자동 설치

# 3. 🔨 소스 코드 빌드 시작
cb                # ROS: colcon build 수행 (RelWithDebInfo 기본)
# mbuild          # 순수 C++: cmake & make 수행
```

### 📋 통합 명령어 사전

| 명령어           | 설명                     | 특징                                                                  |
| :--------------- | :----------------------- | :-------------------------------------------------------------------- |
| **`h` / `help`** | **단축키 가이드**        | 전체 Alias 및 유틸리티 사용법 일람 출력                               |
| **`hw_check`**   | 하드웨어 상태 진단       | GPU 가속 여부 및 **XWayland/Wayland 상태**, 렌더러 진단               |
| **`mbuild`**     | **일반 C++ 빌드**        | `src/` 소스를 빌드하여 `install/`에 설치                              |
| **`mkenv`**      | **Python 가상환경 생성** | `install/.venv` 경로 및 **디렉토리 자동 생성**, 루트 심볼릭 링크 생성 |
| **`cb`**         | **ROS 빌드**             | `src/` 소스를 빌드하여 `install/`에 설치                              |
| **`sync_deps`**  | 의존성 동기화            | `.repos` 기반 소스 다운로드 및 `src/thirdparty` 병합                  |
| **`check_deps`** | 런타임 의존성 검증       | `install/` 내 누락된 공유 라이브러리(`*.so`) 검사                     |

### 💡 유용한 약어 (Common Aliases)

| 구분         | 약어           | 설명                 | 기능                                       |
| :----------- | :------------- | :------------------- | :----------------------------------------- |
| **ROS 빌드** | `cb` / `cbr`   | Colcon 빌드          | `RelWithDebInfo` / `Release` 프로필로 빌드 |
|              | `cbp`, `cbt`   | 특정 패키지 / 테스트 | `--packages-select`, `colcon test`         |
|              | `s`            | 워크스페이스 소싱    | `source install/setup.bash`                |
| **Python**   | `activate`     | venv 활성화          | `source install/.venv/bin/activate`        |
|              | `uvs`, `uvr`   | uv 명령어            | `uv sync`, `uv run`                        |
| **GPU/HW**   | `gpu_status`   | GPU 상태 요약        | 현재 렌더러 및 가속 상태 확인              |
|              | `gpu_setup`    | GPU 자동 감지/설정   | 하드웨어 재검색 및 환경 변수 초기화        |
|              | `vulkan_check` | Vulkan API 확인      | `vulkaninfo` 요약 출력                     |
| **Utils**    | `k` / `k9`     | 프로세스 종료        | 일반 종료(`killall`) / 강제 종료(`-9`)     |
| **Nav**      | `cw`, `cs`     | 디렉토리 이동        | `/workspace`, `/workspace/src` 이동        |

---

## 🧹 유지관리 및 정리 명령어

호스트 터미널에서 프로젝트 상태를 관리하기 위한 통합 명령어입니다.

| 명령어                     | 설명                    | 특징                                                                         |
| :------------------------- | :---------------------- | :--------------------------------------------------------------------------- |
| **`make stats`**           | **리소스 모니터링**     | 서버 전체 컨테이너의 CPU/Memory 및 **모든 GPU(NVIDIA/Intel/AMD)** 상태 확인  |
| **`make top`**             | **상세 모니터링**       | CPU 코어별 점유율 및 **GPU 프로세스(NVIDIA/Intel/AMD)** 상세 상태 확인       |
| **`make status`**          | 프로젝트 상태 요약      | 컨테이너 실행 여부, **진단 엔진 결과** 등 출력                               |
| **`make check-host`**      | 호스트 환경 사전 점검   | GPU 드라이버 및 X11 권한 상태를 확인하여 빌드 전 에러 차단                   |
| **`make logs`**            | 실시간 로그 스트리밍    | 현재 실행 중인 컨테이너의 출력을 실시간으로 확인 (종료 시 Ctrl+C)            |
| **`make down`**            | 서비스 중지             | 현재 프로젝트와 관련된 모든 컨테이너를 안전하게 중지 및 제거                 |
| **`make clean`**           | 빌드 결과물 삭제        | **`/workspace` 내의 build, install, log** 볼륨 및 임시 볼륨 삭제             |
| **`make clean-cache`**     | 컴파일 캐시 명시적 삭제 | 호스트 측 `.docker_cache`(ccache, uv, apt) 폴더를 강제로 삭제                |
| **`make clean-all`**       | **프로젝트 초기화**     | 프로젝트와 관련된 **모든 이미지, 볼륨, 호스트 캐시**를 삭제                  |
| **`make docker-clean`**    | **도커 시스템 정리**    | 시스템 전체의 빌드 캐시 및 미사용 이미지를 삭제 (글로벌 초기화)              |
| **`make env-check`**       | **환경 변수 체크**      | `.env` 설정 누락 여부를 `.env.example` 기준으로 자동 검사                    |

> 💡 **Tip (비대화형 강제 실행 및 CI 모드)**
> 데이터 유실 방지를 위해 `clean` 계열 명령어 실행 시 기본적으로 삭제 동의(`[Y/N]`)를 묻습니다.
> 만약 묻지 않고 즉시 삭제하거나 자동화 쉘 스크립트에 넣으려면 **`make clean FORCE=1`** 처럼 `FORCE=1` 인자를 덧붙이세요.
> (※ GitHub Actions, GitLab CI 등 자동화 플랫폼에서는 `CI=true` 환경 변수가 자동 주입되므로 스크립트를 수정하지 않아도 프롬프트를 스스로 영리하게 건너뜁니다!)

---

## 🚀 운영(Production) 배포 워크플로우

배포 환경은 **Bake & Switch** 전략을 통해 소스 코드 없이 동작합니다.

```mermaid
graph TD
    A[Source Code] -->|make build-ros-prod| B(Builder Image)
    B -->|Compile & Install| C{install/ Artifacts}
    C -->|Copy| D(Runtime Image)
    D -->|make ros-prod| E[Production Service]
```

### ⚠️ 배포 전 필수 권장 사항 (Data Hygiene)

운영 이미지를 빌드하기 전, **`make clean`**을 실행하는 것을 강력히 권장합니다.

**권장 빌드 순서:**

1. **`make clean`**: 기존 빌드 찌꺼기 및 격리된 볼륨 데이터를 완전히 초기화합니다.

2. **`make build-ros-prod`**: 깨끗한 상태에서 배포용 이미지를 빌드(Bake)합니다.

- **이유:** 연결 모드(Bind Mount) 사용 시 호스트에 남은 잔여 파일이나 구 버전의 빌드 아티팩트가 배포 이미지에 포함되는 것을 방지하고, 네임드 볼륨의 데이터를 초기화하여 깨끗한 상태에서 빌드를 보장합니다.

### 1. 배포 이미지의 특징 (`Dockerfile.prod`)

- **소스 코드 제외**: 빌드 단계(Builder)에서 생성된 `install/` 아티팩트만 최종 런타임 이미지로 복제합니다.
- **자동 의존성 검증 (Sanity Check)**: 빌드 과정 중 `ldd`를 통해 필요한 공유 라이브러리가 모두 포함되었는지 검사하여 런타임 안정성을 보장합니다.
- **결정성 극대화**: APT 스냅샷과 `uv sync --frozen`을 통해 환경의 완벽한 일관성을 유지합니다.

### 2. 배포 서비스 제어 명령어 (자동 GPU 감지)

| 환경 구분       | 실행 명령어                          | 특징                                        |
| :-------------- | :----------------------------------- | :------------------------------------------ |
| **ROS 배포**    | **`make ros-prod`**                  | 최적화된 ROS 아티팩트 기반 서비스 시작      |
|                 | **`make ros-prod-stop`**             | ROS 배포 서비스 중지                        |
| **순수 배포**   | **`make dev-prod`**                  | 가벼운 C++/Python 아티팩트 전용 서비스 시작 |
|                 | **`make dev-prod-stop`**             | 순수 배포 서비스 중지                       |
| **이미지 추출** | **`make save-ros`** / **`save-dev`** | 배포용 이미지를 압축 파일(`.tar.gz`)로 추출 |
| **이미지 복원** | **`make load-ros`** / **`load-dev`** | 압축 파일에서 이미지를 도커 시스템으로 복원 |

### 3. 오프라인 배포 가이드 (Offline Deployment)

네트워크가 제한된 타겟 서버에 프로젝트를 배포할 때는 도커 이미지를 추출하여 전송합니다.

```bash
# 1. 배포용 이미지 빌드 (Bake)
make build-ros-prod  # 또는 make build-dev-prod

# 2. 이미지 추출 (Makefile 기반 자동화)
make save-ros        # 추출 완료 후 프로젝트 루트에 {project}-ros-{distro}.tar.gz 생성

# 3. 타겟 서버로 전송 (필수 파일: .tar.gz, .env, docker-compose.prod.yml, Makefile)
# .tar.gz 파일을 타겟 서버의 프로젝트 루트 디렉토리에 위치시켜야 합니다.

# 4. 타겟 서버에서 복원 및 실행
make load-ros        # 루트의 아카이브 파일을 자동으로 찾아 이미지 로드
make ros-prod        # 서비스 시작 (또는 docker compose -f docker-compose.prod.yml up -d)
```

---

## 📡 운영 환경(Prod)의 원격 시각화 가이드

배포된 운영 환경은 리소스 절약을 위해 **Headless 모드**로 동작합니다. 시각화는 네트워크로 연결된 **내 노트북의 Dev 환경**을 활용하세요.

- **ROS 2**: 로봇(Prod)과 노트북(Dev)의 `.env` 내 `ROS_DOMAIN_ID`를 동일하게 맞춘 후, 노트북에서 `rviz2`를 켭니다.
- **ROS 1**: `.env`의 `ROS_MASTER_URI`를 로봇의 IP로 일치시켜 연결합니다.
- **일반 개발**: 서버에서 FastAPI 웹 대시보드나 WebSockets로 데이터를 제공하고, 노트북 브라우저에서 확인하는 방식을 권장합니다.

---

## 📦 외부 의존성 관리 전략 (SSOT Determinism)

이 템플릿의 의존성 관리에는 아키텍처를 관통하는 명확한 **대원칙**이 있습니다:

- **개발 환경 (Dev)**: 시스템 패키지(APT)를 제외한 Python 의존성이나 ROS 패키지는 **자동으로 설치되지 않습니다**. 유연한 개발을 위해 소스 코드 디렉토리(`src/`)를 실시간 마운트한 뒤, 내부 쉘에서 단축키(`mkenv`, `sync_deps`)를 통해 **On-Demand(수동)로 한 번 설치해 주어야 합니다.**
- **운영 배포 환경 (Prod)**: 사용자의 어떠한 수동 조작도 없이, Dockerfile 빌드 과정 중에 Python 패키지와 ROS/C++ 의존성이 **이미지 내부에 100% 완벽하게 설치(Bake-in)** 되어 영구적으로 구워집니다.

이러한 분리 원칙 아래, 각 생태계별로 아래와 같은 체계적인 의존성 관리법을 제공합니다.

```mermaid
graph LR
    subgraph "System (APT)"
        APT["apt.txt / apt_ros.txt"] --> |BuildKit Cache| DOCKER["빌드 시 자동 설치<br/>(Dockerfile)"]
    end

    subgraph "Python (uv)"
        PYPROJ["pyproject.toml"] --> |uv sync| DOCKER
    end

    subgraph "C++ (CMake)"
        FETCH["FetchDependencies.cmake"] --> |colcon build| TARGET_B["임시 빌드 공간<br/>(build/)"]
    end

    subgraph "ROS (vcs)"
        REPOS["dependencies.repos"] --> |sync_deps 실행| TARGET_S["로컬 소스 병합<br/>(src/thirdparty/)"]
    end
```

### 1. Python Layer (`uv` + `pyproject.toml`)

Python 의존성은 초고속 패키지 매니저 `uv`를 통해 완전히 결정론적으로 관리됩니다.

- **다중 패키지 명세 지원 및 충돌 방지**: 템플릿의 파이썬 생태계는 초고속 `uv`를 코어 엔진으로 사용합니다. `pyproject.toml`을 통한 완벽한 버전 관리(`uv sync`)가 최우선 권장 방식이며, 기존의 직관적인 `requirements.txt` 방식(`uv pip`)도 지원합니다. 단, 의존성 충돌을 원천 차단하기 위해 두 파일이 동시 존재할 경우 `pyproject.toml`만 단독 실행(Mutual Exclusion)되도록 설계되었습니다.
- **외부 패키지 및 Git 연동**: 외부 소스를 가져올 때는 `pyproject.toml`의 `[tool.uv.sources]`를 사용하여 특정 브랜치나 커밋을 고정하는 방식이 가장 강력하게 권장됩니다. (별도의 클론 과정 불필요)
- **하드웨어 가속(GPU/CPU) 분리**: 무거운 딥러닝 라이브러리(예: PyTorch)는 아래 예시처럼 `optional-dependencies`로 분리하세요.

  ```toml
  # pyproject.toml 구조 예시
  [project.optional-dependencies]
  cpu = ["torch==2.9.1"]
  gpu = ["torch==2.9.1"]

  [tool.uv.sources]
  torch = [
      { index = "pytorch-cpu", extra = "cpu" },
      { index = "pytorch-cu128", extra = "gpu" },
  ]
  ```

  이후 `.env` 파일의 `UV_SYNC_FLAGS="--extra gpu"`를 설정하면, 템플릿이 도커 빌드 시 알아서 해당 환경에 맞는 패키지만 최적화하여 설치합니다.

### 2. C++ & ROS Layer (`CMake` + `dependencies.repos`)

C++ 및 ROS 환경에서는 성격에 따라 두 가지 도구를 조합하여 의존성을 조작할 수 있습니다.

- **`FetchDependencies.cmake` (빌드 타임 링킹)**: 프로젝트의 `CMakeLists.txt` 빌드 시점에 특정 라이브러리를 GitHub 등에서 즉시 다운로드하여 정적/동적 링킹할 때 사용합니다. 사용자는 직접 이 파일을 열어 `nlohmann_json`, `spdlog` 등 프로젝트에 필요한 C++ 의존성을 자유롭게 추가하고 조작할 수 있습니다.
- **`dependencies.repos` (소스 레벨 동기화)**: 외부 라이브러리 소스를 직접 가져와 내 프로젝트와 동시에 뜯어고치며 개발(Editable)해야 할 때 유용합니다.
  - **자동 동기화**: `dependencies/dependencies.repos`에 명시하면 컨테이너 시작 시(`make dev` 또는 `make ros`) `src/thirdparty` 폴더에 자동으로 클론됩니다.
  - **오버레이**: `dependencies/overlay/` 디렉토리에 위치한 파일들은 동기화가 끝난 후 타겟 소스 위로 안전하게 병합(덮어쓰기)됩니다.

### 3. 빌드 속도 및 의존성 최적화 (`config/colcon.meta`)

거대한 외부 C++/ROS 라이브러리(Eigen3, GTSAM, Librealsense2 등)를 소스째 빌드하면, 데모나 테스트 컴파일 때문에 빌드 시간이 매우 오래 걸리거나 런타임 충돌(Eigen ODR Violation)이 발생할 수 있습니다.

- 템플릿에 내장된 `config/colcon.meta` 파일은 `colcon build` 실행 시 특정 라이브러리에만 커스텀 CMake 옵션을 자동으로 주입합니다.
- **주요 예시**: 내장된 설정은 불필요한 테스트(`BUILD_TESTING=OFF`) 컴파일을 원천 차단하여 빌드 시간을 단축하고, 시스템 라이브러리 강제 사용(`GTSAM_USE_SYSTEM_EIGEN=ON`)을 통해 메모리 충돌을 예방합니다.
- **커스터마이징 (ROS)**: 이 파일에 해당 패키지의 이름과 CMake 옵션 배열을 주입하여 전체 워크스페이스 빌드를 지휘(Orchestration)하세요.
- **커스터마이징 (C++)**: `colcon`이 없는 순수 C++ 빌드에서는 `.env`의 `CMAKE_EXTRA_ARGS` 변수를 활용합니다.
  - 소수 옵션: `CMAKE_EXTRA_ARGS="-DBUILD_TESTING=OFF -DGTSAM_USE_SYSTEM_EIGEN=ON"` 형태로 직접 주입합니다.
  - 다수 옵션: 별도의 설정 파일(예: `config/cmake_cache.cmake`)에 `set(BUILD_TESTING OFF CACHE BOOL "" FORCE)` 형태로 적은 뒤, `.env`에 `CMAKE_EXTRA_ARGS="-C /workspace/config/cmake_cache.cmake"`라고 적어서 파일째로 한 번에 주입하는 방식을 권장합니다.

### 4. System Layer (APT 패키지)

- **방법**: 프로젝트에 필요한 OS 리눅스 패키지는 `dependencies/apt.txt` (일반) 또는 `dependencies/apt_ros.txt` (ROS 전용)에 기입합니다.
- 배포 런타임 이미지 에도 포함되어야 하는 패키지는 줄 끝에 `# runtime` 주석을 달면 자동 필터링됩니다. 빌드 시 BuildKit 캐시를 활용하여 초고속으로 설치됩니다.

---

## ⚠️ 보안 및 아키텍처 제약 사항 (Security Notes)

1. **`root` 권한 일관성**: 개발 및 배포 컨테이너 모두 `root` 유저로 실행됩니다. 이는 마운트된 호스트 볼륨의 파일 소유권 문제를 해결하고 장치 접근성을 높이기 위한 설계입니다.
2. **`privileged: true`**: ROS 개발 시 센서, USB, CAN 통신 등의 장치를 자유롭게 사용하기 위해 개발용 컨테이너는 특권 모드로 실행됩니다.
3. **`network_mode: host`**: ROS의 DDS 통신 성능을 위해 호스트 네트워크를 직접 사용합니다. 여러 프로젝트 실행 시 `.env`의 `ROS_DOMAIN_ID`를 고유하게 설정하여 간섭을 피하세요.

---

## 📄 라이선스 및 사용 안내 (License & Usage)

본 **DevKit** 저장소의 뼈대 코드와 각종 설정 파일들은 **[MIT-0 (MIT No Attribution)](LICENSE)** 형식으로 배포됩니다.

- **출처 표기 불필요**: 이 템플릿의 원본 출처나 원작자를 여러분의 코드에 굳이 명시하실 필요가 전혀 없습니다. 상용(Commercial), 사내 프라이빗망, 개인 오픈소스 등 어떠한 형태의 목적이라도 완전하게 자유롭게 활용하세요.
- **자유로운 교체**: 템플릿을 복사하여 새로운 프로젝트를 시작할 때는, 더 이상 템플릿의 눈치를 보지 마시고 루트 경로의 `LICENSE` 파일을 지우거나 **여러분의 프로젝트 성격에 맞는 자체 라이선스 파일로 마음껏 덮어씌워 사용하면 됩니다.**
