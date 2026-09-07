# 🏥 DevKit 진단 가이드

호스트와 컨테이너 양쪽의 진단 명령을 다룹니다. 디버거 세팅은
[DEBUGGING.md](DEBUGGING.md)에 있습니다.

---

## 🏥 진단 유틸리티 & 헬스 체크

### 🖥️ 1. 호스트 측 진단 명령어 (Host Utilities)
* **`make gpus`**: 호스트 PC의 GPU (NVIDIA/iGPU) 가속 및 VRAM 상태 조회.
* **`make check`**: Docker CLI/데몬 · Compose v2 · BuildKit 사전 점검, `.env` ↔ `.env.example` 키 누락 대조,
  WSL2 진단, NVIDIA Container Toolkit 미설정 감지(해결 명령 동반). `build`/`start`의 선행 의존성입니다.
* **`make status`**: 프로젝트 요약 + **`[Detected Host Wiring]`** (GPU 디바이스, WSL 라이브러리, 디스플레이,
  XDG/Xauthority, ssh-agent, git 신원, 컨테이너 UID/GID) — 자동 감지 결과를 한눈에 확인.
* **`make clean-cache`**: 호스트 감지 캐시(`.docker_cache/detected-env.mk`) 무효화 → 다음 `make` 실행 시 재감지.
* **`make verify`**: 키트 계약 전체(개수는 README 의 `make verify` 행)를 실행으로 검증합니다 — docker 도 `.env` 도 필요 없습니다. 실패 메시지의
  슬러그(`[env-bridge]` 등)가 어느 계약인지 알려주고, 각 검사가 왜 있는지는 `scripts/verify_repo.sh`의 슬러그
  헤더에 적혀 있습니다. 계약을 추가하는 규칙은 [CONTRIBUTING.md](../.github/CONTRIBUTING.md#계약을-추가할-때).

### 🐳 2. 컨테이너 내부 진단 숏컷 (In-Container Utilities)

#### `hwcheck` — 6개 섹션 종합 스캔 (약 0.8초, `--brief`로 경고만 출력)

| 섹션 | 내용 |
| :--- | :--- |
| 1/6 System | CPU 모델·코어·SIMD, RAM 사용률, 디스크 여유 |
| 2/6 Network & ROS | IP, 인터페이스 MTU, 시각 동기화, ROS 배포판/RMW/Domain ID |
| 3/6 GPU | `/dev/nvidiactl` · `/dev/dri` · `/dev/dxg` 노드, NVIDIA VRAM, ROCm |
| 4/6 Display & GUI | X11 소켓·Xauthority, Wayland, XDG, **OpenGL 렌더러·Mesa 버전·가속 여부**, **Vulkan 디바이스**, **로더 경로**(`libGL`/`libEGL`/`libvulkan`/`libcuda`) |
| 5/6 Identity & Permissions | **uid/gid·소속 그룹**, 워크스페이스/`build`/`install`/`/cache` **소유권·쓰기 가능 여부**, GPU 디바이스 접근 권한, root 실행 경고 |
| 6/6 Dev Toolchain | Python, uv/colcon/rosdep/ccache/vcs, venv, 시리얼·CAN 주변장치 |

> 5/6 섹션은 컨테이너에서 가장 흔한 두 가지 실패를 직접 판정합니다 —
> **바인드 마운트 UID/GID 불일치**(`Permission denied`)와 **`video`/`render` 그룹 미가입**(GPU 디바이스 접근 불가).
> 불일치 시 해결 명령(`make clean-cache && make build`)까지 함께 출력합니다.

#### `gpus` — 렌더링 스택 전체 리포트 (약 2초)

`[Hardware]`(NVIDIA/CUDA/cuDNN, DRI 노드, WSL2 D3D12 + `/usr/lib/wsl/lib` 마운트 여부) ·
`[Display]`(X11/Wayland 소켓, XDG) · `[OpenGL / GLX]`(vendor/renderer/version/Mesa/direct/가속/VRAM, **llvmpipe 소프트웨어 렌더링 경고**) ·
`[EGL]` · `[Vulkan]`(디바이스/타입/API/드라이버) · `[Loader]`(실제 해석된 라이브러리 경로) ·
`[Active configuration]`(GPU_MODE, `MESA_*`/`__GLX_*`/`LIBGL_*` 전체, `LD_LIBRARY_PATH`, 영속화 파일 상태).

* **`gpu <mode>`**: 렌더링 모드 전환 (`auto`/`nvidia`/`tegra`/`intel`/`amd`/`igpu`/`cpu`).
  `tegra`는 컨테이너 내부 전용입니다 — Jetson은 `/dev/nvidiactl`이 없어 일반 NVIDIA 탐지에 걸리지 않습니다.
  결과가 `~/.gpu_env.sh`에 기록되어 이후 새 셸에도 동일하게 적용됩니다.
* **`gpu_check` / `vulkan_check`**: 한 줄짜리 빠른 렌더러 확인.
* **`check_deps`**: `install/` 내 누락된 `*.so` 라이브러리를 `ldd`로 탐지.

> 진단 프로브(`glxinfo`/`eglinfo`/`vulkaninfo`)는 모두 `timeout` 보호됩니다 — `DISPLAY`가 설정되었지만
> 서버에 닿지 못하는 상황에서 진단이 멈추지 않도록 하기 위함이며, `make verify` [render-probes]이 이를 강제합니다.
> `eglinfo`는 모든 플랫폼을 초기화하느라 ~1.8초가 걸려 `hwcheck`에서는 제외하고 `gpus`에서만 조회합니다.
