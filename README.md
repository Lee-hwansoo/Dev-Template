# 🚀 All-in-One Docker Dev Environment Template

[![ROS1](https://img.shields.io/badge/ROS-Noetic-blue?logo=ros)](https://www.ros.org/)
[![ROS2](https://img.shields.io/badge/ROS2-Humble-red?logo=ros)](https://docs.ros.org/en/humble/index.html)
[![Python](https://img.shields.io/badge/Python-3.11-3776AB?logo=python)](https://www.python.org/)
[![C++](https://img.shields.io/badge/C%2B%2B-17-00599C?logo=c%2B%2B)](https://isocpp.org/)
[![Docker](https://img.shields.io/badge/Docker-Enabled-2496ED?logo=docker)](https://www.docker.com/)

본 저장소는 호스트 시스템을 오염시키지 않고 **C++, Python(uv), ROS 1 / ROS 2** 개발을 수행할 수 있도록 설계된 **독립 개발 환경 템플릿**입니다. 복잡한 설정 없이 어떤 프로젝트에서든 즉시 개발을 시작하세요.

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
- **네이티브 Multi-Arch 지원**: 단일 Dockerfile로 인텔 PC와 ARM 기반(Jetson, M1/M2) 환경을 모두 지원합니다.
- **일관된 권한 체계 (Root Unity)**: 개발과 배포 환경 모두 `root` 유저를 사용하여 호스트 볼륨 마운트 시의 권한 충돌을 방지했습니다.

---

## 🏗 멀티스테이지 도커 아키텍처 (Multi-stage Architecture)

본 템플릿은 빌드 속도와 캐시 효율을 극대화하기 위해 세분화된 빌드 파이프라인을 사용합니다.

- `Base OS` ➔ `Tools/GUI (캐시 최적화)` ➔ `Python (uv)` ➔ `Dev (개발 환경)` ➔ `Builder (Bake)` ➔ `Runtime (초경량 배포)`

---

## 🚀 표준 워크스페이스 구조 (Standard Layout)

모든 프로젝트는 언어와 프레임워크에 상관없이 다음 구조를 따릅니다.

- **`src/`**: 모든 소스 코드 및 빌드 설정 (CMakeLists.txt, pyproject.toml 등)
- **`build/`**: 컴파일러와 빌드 시스템이 사용하는 임시 빌드 공간
- **`install/`**: 최종 실행 파일, 라이브러리, Python 가상환경(`.venv`)이 모이는 **배포 아티팩트** 폴더
  - *Note: Python 가상환경을 `install/` 내부에 두어 배포 시 소스 없이도 독립적인 실행이 가능하도록 설계되었습니다. IDE 호환성을 위해 프로젝트 루트에 `.venv` 심볼릭 링크가 생성됩니다.*

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
make status         # 현재 프로젝트 설정 및 GPU/아키텍처/툴킷 자동 감지 상태 확인
make build-ros      # ROS 이미지 빌드 (Multi-Arch 자동 대응)
make ros            # ROS 컨테이너 시작 및 진입 (GPU 자동 감지)
# 또는
make dev            # 순수 C++/Python 컨테이너 시작 (GPU 자동 감지)
```

---

## 💻 GPU 및 개발 환경 실행 방법

시스템이 최적의 모드를 자동으로 선택합니다.

| 환경 구분 | 실행 명령어 (GPU 자동 감지) | 셸 진입 (기존 창) | 새 창 띄우기 (GUI) |
| :--- | :--- | :--- | :--- |
| **ROS 환경** | **`make ros`** | **`make ros-shell`** | **`make ros-term`** |
| **순수 개발** | **`make dev`** | **`make dev-shell`** | **`make dev-term`** |

> **Tip:** `make status`를 통해 현재 시스템이 NVIDIA GPU와 Container Toolkit을 올바르게 인식하고 있는지, 그리고 현재 아키텍처(AMD64/ARM64)가 무엇인지 확인할 수 있습니다.

---

## 🛠 컨테이너 내부 개발 워크플로우

어떤 프로젝트든 동일한 UX를 제공합니다.

| 명령어 | 설명 | 특징 |
| :--- | :--- | :--- |
| **`hw_check`** | 하드웨어 상태 진단 | GPU 가속 여부 및 **XWayland/Wayland 상태**, 렌더러 진단 |
| **`mbuild`** | **일반 C++ 빌드** | `src/` 소스를 빌드하여 `install/`에 설치 |
| **`mkenv`** | **Python 가상환경 생성** | `install/.venv` 경로에 생성 및 **루트 심볼릭 링크 자동 생성** |
| **`cb`** | **ROS 빌드** | `src/` 소스를 빌드하여 `install/`에 설치 |
| **`sync_deps`** | 의존성 동기화 | `.repos` 기반 소스 다운로드 및 `src/thirdparty` 병합 |

### 💡 유용한 약어 (Common Aliases)

| 구분 | 약어 | 설명 | 기능 |
| :--- | :--- | :--- | :--- |
| **ROS 빌드**| `cb` / `cbr` | Colcon 빌드 | `RelWithDebInfo` / `Release` 프로필로 빌드 |
| | `cbp`, `cbt` | 특정 패키지 / 테스트 | `--packages-select`, `colcon test` |
| | `s` | 워크스페이스 소싱 | `source install/setup.bash` |
| **Python** | `activate` | venv 활성화 | `source install/.venv/bin/activate` |
| | `uvs`, `uvr` | uv 명령어 | `uv sync`, `uv run` |
| **GPU/HW** | `gpu_status` | GPU 상태 요약 | 현재 렌더러 및 가속 상태 확인 |
| | `vulkan_check`| Vulkan API 확인 | `vulkaninfo` 요약 출력 |
| **Nav** | `cw`, `cs` | 디렉토리 이동 | `/workspace`, `/workspace/src` 이동 |

---

## 🧹 유지관리 및 정리 명령어

호스트 터미널에서 프로젝트 상태를 관리하기 위한 통합 명령어입니다.

| 명령어 | 설명 | 특징 |
| :--- | :--- | :--- |
| **`make status`** | 프로젝트 상태 요약 | 컨테이너 실행 여부, **진단 엔진 결과** 등 출력 |
| **`make check-host`** | 호스트 환경 사전 점검 | GPU 드라이버 및 X11 권한 상태를 확인하여 빌드 전 에러 차단 |
| **`make logs`** | 실시간 로그 스트리밍 | 현재 실행 중인 컨테이너의 출력을 실시간으로 확인 (종료 시 Ctrl+C) |
| **`make down`** | 서비스 중지 | 현재 프로젝트와 관련된 모든 컨테이너를 안전하게 중지 및 제거 |
| **`make clean`** | 빌드 결과물 삭제 | **`/workspace` 내의 build, install, log** 볼륨 및 임시 볼륨 삭제 |
| **`make clean-cache`** | 컴파일 캐시 명시적 삭제 | 호스트 측 `.docker_cache`(ccache, uv, apt) 폴더를 강제로 삭제 |
| **`make clean-builder`** | 도커 빌드 캐시 정리 | Docker BuildKit 내부 캐시를 비워 호스트 디스크 용량 확보 |
| **`make clean-all`** | 시스템 전체 초기화 | 모든 도커 볼륨 및 호스트 캐시를 삭제하여 초기화 |
| **`make scale-basic N=2`** | 서비스 수평 확장 | (고급) `basic` 서비스를 N개로 확장 (예: `docker compose up --scale basic=2`) |

---

## 🚀 운영(Production) 배포 워크플로우

배포 환경은 **Bake & Switch** 전략을 통해 소스 코드 없이 동작합니다.

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

| 환경 구분 | 실행 명령어 | 특징 |
| :--- | :--- | :--- |
| **ROS 배포** | **`make ros-prod`** | 최적화된 ROS 아티팩트 기반 서비스 시작 |
| **순수 배포** | **`make dev-prod`** | 가벼운 C++/Python 아티팩트 전용 서비스 시작 |

### 3. 오프라인 배포 가이드 (Offline Deployment)

네트워크가 제한된 타겟 서버에 프로젝트를 배포할 때는 도커 이미지를 추출하여 전송합니다.

```bash
# 1. 배포용 이미지 빌드 (Bake)
make build-ros-prod  # 또는 make build-dev-prod

# 2. 이미지 추출 및 타겟 서버로 전송
docker save my_project/ros-runtime:latest | gzip > release.tar.gz

# 3. 타겟 서버에서 로드 및 실행
docker load < release.tar.gz
docker compose -f docker-compose.prod.yml up -d
```

---

## 📡 운영 환경(Prod)의 원격 시각화 가이드

배포된 운영 환경은 리소스 절약을 위해 **Headless 모드**로 동작합니다. 시각화는 네트워크로 연결된 **내 노트북의 Dev 환경**을 활용하세요.

- **ROS 2**: 로봇(Prod)과 노트북(Dev)의 `.env` 내 `ROS_DOMAIN_ID`를 동일하게 맞춘 후, 노트북에서 `rviz2`를 켭니다.
- **ROS 1**: `.env`의 `ROS_MASTER_URI`를 로봇의 IP로 일치시켜 연결합니다.
- **일반 개발**: 서버에서 FastAPI 웹 대시보드나 WebSockets로 데이터를 제공하고, 노트북 브라우저에서 확인하는 방식을 권장합니다.

---

## 📦 외부 의존성 관리 전략 (SSOT Determinism)

### 1. System Layer (APT)

- **방법:** `dependencies/apt.txt` (일반) 또는 `dependencies/apt_ros.txt` (ROS 전용)에 패키지 기입. 배포 런타임에도 필요한 패키지는 뒤에 `# runtime` 주석 추가.
- **효과:** BuildKit 캐시 마운트(`/cache/apt`)로 인해 패키지 추가 시 전체 레이어를 다시 받지 않고 즉시 설치됩니다.

### 2. Language Layer (C++/Python)

- **C++:** `FetchDependencies.cmake`를 활용한 빌드 타임 의존성 해결.
- **Python:** 초고속 패키지 매니저 `uv`(`uv.lock`) 기반 결정성 있는 가상환경 구축. (호스트 캐시 `/cache/uv` 활용)

### 3. Workspace Layer (vcstool)

- **방법:** `dependencies/dependencies.repos`에 소스 기반 의존성 명시.
- **자동 동기화:** 컨테이너 시작 시(`entrypoint.sh`), `src/thirdparty` 디렉토리가 비어 있다면 `sync_deps.sh`가 자동으로 실행되어 외부 소스를 다운로드합니다.
- **오버레이:** `dependencies/overlay/`의 파일이 다운로드된 `/workspace/src/thirdparty` 소스 위로 안전하게 병합(덮어쓰기)됩니다.

---

## ⚠️ 보안 및 아키텍처 제약 사항 (Security Notes)

1. **`root` 권한 일관성**: 개발 및 배포 컨테이너 모두 `root` 유저로 실행됩니다. 이는 마운트된 호스트 볼륨의 파일 소유권 문제를 해결하고 장치 접근성을 높이기 위한 설계입니다.
2. **`privileged: true`**: ROS 개발 시 센서, USB, CAN 통신 등의 장치를 자유롭게 사용하기 위해 개발용 컨테이너는 특권 모드로 실행됩니다.
3. **`network_mode: host`**: ROS의 DDS 통신 성능을 위해 호스트 네트워크를 직접 사용합니다. 여러 프로젝트 실행 시 `.env`의 `ROS_DOMAIN_ID`를 고유하게 설정하여 간섭을 피하세요.
