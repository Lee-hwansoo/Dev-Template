# 🐞 DevKit 디버깅 & 트러블슈팅 가이드

본 문서는 **DevKit** 환경에 통합된 전문 디버깅 에코시스템 활용법을 안내합니다. VSCode 연동을 통해 Docker 컨테이너 내부에서 구동되는 **C++, Python, ROS 1/2** 애플리케이션을 브레이크포인트 단위로 디버깅할 수 있습니다.

> [!TIP]
> **디버거 환경은 실제로 소싱한 것**: 모든 launch 프로필은 `.vscode/.debug.env`(`envFile`)를 읽습니다. 이 파일은
> pre-launch 태스크가 `mdebugenv` 로 씁니다 — ROS·오버레이(`install/` 또는 ROS 1 `devel/`)·venv·GPU 라이브러리 경로를
> 컨테이너에서 소싱한 그대로입니다. 정적 경로 사본은 없습니다. 손으로 갱신하려면 컨테이너에서 `mdebugenv`.

---

## 📌 목차

1. [🛠️ 사전 준비 및 빌드 설정](#️-사전-준비-및-빌드-설정)
2. [🔌 프로세스 연결 방법](#-프로세스-연결-방법)
3. [🎯 C++ 디버깅 (GDB)](#-c-디버깅-gdb)
4. [🐍 Python 디버깅 (debugpy)](#-python-디버깅-debugpy)
5. [🤖 ROS Launch 파일 디버깅](#-ros-launch-파일-디버깅)
6. [⚙️ 태스크 시스템 (tasks.json)](#️-태스크-시스템-tasksjson)
7. [🔍 고급 트러블슈팅](#-고급-트러블슈팅)

---

## 🛠️ 사전 준비 및 빌드 설정

### 1. 디버그 심볼 포함 빌드
디버거(브레이크포인트, 변수 값 추적)가 정상 작동하려면 소스 코드에 **Debug 심볼**이 포함되어야 합니다.

| 빌드 모드 | CLI 명령어 (ROS 워크스페이스) | VSCode 빌드 태스크 (Ctrl+Shift+B) |
| :--- | :--- | :--- |
| **Debug** (권장) | `cbuild --debug` | `🔨 colcon: Build (Debug)` |
| **RelWithDebInfo** | `cbuild` (기본값) | `🔨 colcon: Build (RelWithDebInfo)` |
| **Release** | `cbuild --release` | `🔨 colcon: Build (Release)` |

---

## 🔌 프로세스 연결 방법

### 방법 A: Dev Containers 연결 (권장)
VS Code 프로세스 자체를 컨테이너 안에서 돌립니다. `.devcontainer/devcontainer.json` 이 `make start` 가 쓰는 것과
같은 compose 서비스를 가리키므로 마운트·환경이 CLI 와 동일합니다.
1. `make setup`(또는 설정 변경 후 `make ide-config`) — 이 호스트가 해석한 GPU 프로필과 `CONTAINER_USER` 를
   `devcontainer.json` 의 `service`/`remoteUser` 에 써 넣습니다. 추적 파일이지만 호스트마다 다른 값이니 **그 diff 는 커밋하지 마세요**.
   docker compose 가 없는 호스트(SLURM 제출 노드)에서는 건너뜁니다.
2. 개발 컨테이너 시작: `make start ENV=ros`
3. **Ctrl+Shift+P** ➔ `Dev Containers: Reopen in Container` (이미 떠 있는 컨테이너에 붙습니다).
4. **특징**: 컨테이너 네이티브 성능, 자동 IntelliSense 헤더 탐색, 셸 터미널 완전 통합.
   `ENV`, `GPU_MODE`, 컨테이너 사용자, 마운트를 바꿨다면 `make ide-config` 를 다시 실행하고 컨테이너를 다시 여세요.

### 방법 B: 호스트 사이드 개발
호스트 OS에서 코드 편집기를 구동하면서 컨테이너와 연동합니다.
1. VSCode에서 일반적인 방식으로 워크스페이스 오픈.
2. 상태 표시줄에서 IntelliSense 프로필을 호스트용으로 전환합니다
   (`c_cpp_properties.json`: `Host (Linux/WSL)` 또는 `Host (macOS)`; 컨테이너 내부 편집은
   `Docker (Container)`). 호스트 프로필은 컨테이너 환경변수를 읽을 수 없으므로 C/C++ 표준을
   `.env` 기본값(c11 / c++17)으로 고정해 둡니다.

---

## 🎯 C++ 디버깅 (GDB)

GDB 디버그 엔진을 통해 C++ 실행 파일 및 ROS 노드를 라인 단위로 탐색합니다.

### 1. 실행 파일 직접 디버깅
* **`🐛 C++: Launch Executable (GDB)`**: Debug 빌드 후 선택한 이진 파일을 GDB로 즉시 실행.
* **`🐛 C++: Launch (GDB, skip build)`**: 코드 수정 없이 디버거만 빠르게 재실행.

### 2. 구동 중인 프로세스에 디버거 부착 (Attach)
* **`🐛 C++: Attach to Process (GDB)`**: 이미 가동 중인 ROS 노드 프로세스를 검색하여 GDB를 실시간 연결.

### 3. ROS 전용 노드 디버깅
* **ROS 2**: `🤖 ROS2: C++ Node (GDB Direct)` (`--ros-args` 및 리매핑 파라미터 보장)
* **ROS 1**: `🐢 ROS1: C++ Node (GDB Direct)` (`__name` 및 Master URI 보장)

---

## 🐍 Python 디버깅 (debugpy)

`debugpy` 엔진을 통해 파이썬 스크립트 및 ROS 파이썬 노드를 디버깅합니다.

### 1. 단일 파일 디버깅
임의의 `*.py` 파일을 연 상태에서 **F5** ➔ **`🐍 Python: Debug Current File`** 선택.
인자를 넘겨야 하면 **`🐍 Python: Debug with Args`** — 파일 경로를 먼저 묻습니다.

### 2. 원격 프로세스 Attach (Advanced)
배경에서 구동 중인 파이썬 노드에 디버거 부착:
1. 소스 코드에 수신 리스너 삽입:
   ```python
   import debugpy
   debugpy.listen(("0.0.0.0", 5678))
   debugpy.wait_for_client()  # 클라이언트 접속까지 대기
   ```
2. **F5** ➔ **`🐍 Python: Attach to debugpy (Remote)`** 선택.

---

## 🤖 ROS Launch 파일 디버깅

전체 시스템 런치 파일과 개별 노드를 한 번에 디버깅합니다.

* **ROS 2 Launch**: **`🤖 ROS2: Launch File`** 선택 (빌드 후 `mdebugenv` 가 환경을 씁니다).
  코드를 고치지 않았다면 빌드를 건너뛰는 **`🤖 ROS2: Launch File (skip build)`** 가 빠릅니다.
* **ROS 1 Launch**: **`🐢 ROS1: roslaunch`** 선택 (터미널에서 `roscore` 실행 필요).
* **단일 노드**: **`🤖 ROS2: Run Node`** — 패키지와 실행 파일 이름을 묻습니다. ROS 1 파이썬 노드는 **`🐢 ROS1: Python Node`** — `rosrun` 은 bash 스크립트라 파이썬 디버거가 붙을 수 없으므로 노드 파일을 직접 띄우고 `__name:=` 을 넘깁니다. C++ 노드는 위의 GDB Direct 프로필.

### 런치와 노드를 동시에 (Compound)

런치 파일을 띄우면서 그 안의 노드에 디버거를 붙이는 조합입니다. F5 목록에서 하나만 고르면
두 세션이 함께 시작됩니다.

| Compound | 구성 |
| :--- | :--- |
| **`🚀 Full Debug: ROS2 Launch + C++ Attach`** | `🤖 ROS2: Launch File` + `🐛 C++: Attach to Process (GDB)` |
| **`🚀 Full Debug: ROS2 Launch + Python Attach`** | `🤖 ROS2: Launch File` + `🐍 Python: Attach to debugpy (Remote)` |
| **`🚀 Full Debug: ROS1 roslaunch + C++ Attach`** | `🐢 ROS1: roslaunch` + `🐛 C++: Attach to Process (GDB)` |
| **`🚀 Full Debug: ROS1 roslaunch + Python Attach`** | `🐢 ROS1: roslaunch` + `🐍 Python: Attach to debugpy (Remote)` |

> Attach 쪽은 대상 프로세스가 떠 있어야 붙습니다 — C++ 는 프로세스 선택 목록에서, Python 은
> 노드 안에 `debugpy.listen(("0.0.0.0", 5678))` 이 있어야 합니다(위 2절).

---

## ⚙️ 태스크 시스템 (tasks.json)

**Ctrl+Shift+B** 또는 Task 메뉴를 통해 유용한 유지보수 태스크를 즉시 실행할 수 있습니다.

| 태스크 카테고리 | 주요 수행 태스크 |
| :--- | :--- |
| **진단 (Diagnostics)** | `✅ DevKit: Verify (Script-only)`, `🚀 Full Hardware & GPU Check`, `⚡ GPU Status & Diagnostics`, `🔍 Check Dependencies (Sanity)` |
| **유지보수 (Maintenance)** | `🧹 Clean Workspace`, `🔄 Sync Repos (.repos only)`, `📦 Sync Repos + rosdep (system deps)`, `🐍 Python: uv sync`, `📊 Build Cache Statistics (ccache)` |
| **ROS 빌드 & 테스트** | `🔨 colcon: Build (Debug)`, `🔨 colcon: Build Package`, `🧪 colcon: Test`, `🧪 colcon: Test Results` |
| **순수 CMake 빌드** | `🔨 cmake: Build (Debug)`, `🔨 cmake: Build (Release)` |
| **품질 루프** | `🧪 Project: Test (mtest)`, `🎨 Project: Lint (mlint)`, `🎨 Project: Lint --fix` |

> [!NOTE]
> 라벨은 `.vscode/tasks.json`이 단일 진실 공급원이며, `scripts/verify_repo.sh`의
> check [vscode-json]이 각 태스크가 호출하는 셸 함수·스크립트가 실제로 존재하는지
> 검사합니다(제거된 내부 함수를 계속 호출해 "command not found"로 끝난 적이 있습니다).

---

## 🔍 고급 트러블슈팅

### 🛑 브레이크포인트(빨간 점)가 작동하지 않을 때
1. **Debug 빌드 모드 확인**: 컴파일 옵션에 `-DCMAKE_BUILD_TYPE=Debug`가 적용되어 있는지 검사하세요.
2. **Source File Mapping**: `launch.json` 내의 `sourceFileMap` 경로가 `/workspace/src` ➔ `${workspaceFolder}/src`로 매핑되어 있는지 확인하세요.

### 🛑 C++ 빨간 밑줄 (IntelliSense 오류)이 뜰 때
1. **compile_commands.json 생성**: `cbuild` 또는 빌드 태스크를 1회 실행하여 `build/compile_commands.json`을 새로 고치세요.
2. **IntelliSense DB 재설정**: **Ctrl+Shift+P** ➔ `C/C++: Reset IntelliSense Database` 실행.

### 🛑 GDB "Operation Not Permitted" 에러 시
컨테이너 내부에서 아래 명령을 실행하여 ptrace 권한을 해제하세요:
```bash
echo 0 > /proc/sys/kernel/yama/ptrace_scope
```
