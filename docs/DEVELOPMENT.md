# 📘 DevKit 개발자 워크플로우 & 툴체인 가이드

본 문서는 **DevKit** 생태계의 핵심 개발 워크플로우, 의존성 관리 방식, 빌드 툴체인 및 SIF 빌드 옵션을 상세히 다룹니다.

---

## 🏛️ 아키텍처: 단일 진실 공급원 (SSOT)

DevKit은 모든 워크스페이스 경로 및 환경 설정에 **Single Source of Truth (SSOT)** 원칙을 강제합니다. 전체 환경은 `${WORKSPACE_PATH}` (기본값: `/workspace`)를 기준으로 결합됩니다.

### 📍 표준화된 경로 전략
- **쉐도우 디렉토리 부재**: 모든 스크립트, 패키지 및 환경 설정은 워크스페이스 내에 엄격히 위치합니다.
- **상대 경로 견고성**: 스크립트 소싱 시 다음 오버레이 패턴을 통해 실행됩니다:
  1. `${WORKSPACE_PATH}/scripts/...` (공식 SSOT 경로)
  2. `$(dirname "${BASH_SOURCE[0]}")/...` (로컬 fallback)

### 📚 공유 라이브러리 — 규칙이 한 번만 정의되는 곳
이 목록은 **파생 프로젝트가 쓰라고 제공하는 API**입니다 — 인트리 호출자가 없는 심볼도
기능이며, check [provided-api]가 경로 집합과 로그 동사를 실행으로 검증합니다.
새 로직을 추가할 때는 아래 파일 중 해당 규칙의 소유자를 먼저 확인하세요. 복사본이 갈라지면
호출 지점마다 다르게 동작합니다(실제로 `apptainer_run.sh`가 런타임을 못 찾고 `singularity:
command not found`로 죽은 원인이었습니다). `scripts/verify_repo.sh`가 이 목록과 실제 파일
집합의 일치를 검사합니다.

| 파일 | 단일 정의 대상 |
| --- | --- |
| `config/util_paths.sh` | 워크스페이스 경로 전체(`WS_ROOT`·`WS_SRC`·`WS_CONFIG`·`WS_SCRIPTS`·`WS_DEPS`·`WS_BUILD`·`WS_INSTALL`·`WS_LOGS`·`WS_VENV`·`WS_VENV_PY`), `.env` 값 읽기(`devkit_env_value`), `devkit_require`, 로그 스텁 |
| `scripts/util_logging.sh` | 로그 동사(`log_ok`/`log_warn`/`log_detail`…), 배너·섹션, 스트림별 색상 판정 |
| `scripts/util_sif_common.sh` | SIF 런타임 바이너리, 아티팩트 이름, 호스트 환경 임포트, 엔트리포인트 경유 |
| `scripts/util_gpu_detect.sh` | GPU 벤더·디바이스 노드 감지 |
| `scripts/util_apt_helper.sh` | 빌드 타임 APT 저장소 신뢰 앵커 및 태그 필터 설치 |
| `scripts/util_cuda_apt.sh` | CUDA/cuDNN apt 프로파일 설치 |
| `scripts/util_setup_links.sh` | 워크스페이스 심볼릭 링크(`colcon.meta`, `.venv`, `compile_commands.json`) |
| `scripts/util_release_metadata.sh` | 릴리스 메타데이터 및 APT/pip 매니페스트 생성 |

---

## 🏁 통합 개발 워크플로우

컨테이너 진입 후 즉시 개발을 시작할 수 있는 통합 명령어 체계입니다.

### 1. 원클릭 가상환경 & 빌드 동기화 (`mksync`)

아래 단 하나의 명령어로 가상환경 생성, 의존성 동기화, 초기 빌드를 자동 수행합니다:

```bash
mksync
```

> [!TIP]
> **`mksync` 동작 시퀀스**:
> `mkenv` (venv 생성) ➔ `uvs` (`pyproject.toml` 파이썬 동기화) ➔ `sync_deps --rosdep` (vcs import + overlay + rosdep) ➔ **프로젝트 타입 판별 후 빌드**.
> - venv 는 `install/.venv` 에 만들어지고 **프로젝트 이름으로 명명**됩니다(`--prompt "$COMPOSE_PROJECT_NAME"`) —
>   프롬프트에 `(myproject-lee)` 로 보이므로 여러 워크스페이스를 오갈 때 어느 셸인지 한눈에 구분됩니다.
> - `uv sync` 는 venv 가 이미 가진 인터프리터에 고정됩니다(`--python`). 이게 없으면 uv 가 `UV_PYTHON` 과
>   불일치를 이유로 환경을 **재생성**해, `mksync --share`(noetic)가 만든 shared venv 가 pure 로 바뀌며 `rospy` 가 사라집니다.
> - **프로젝트 타입 판별**: `src/` 하위 3단계까지 탐색하여 `package.xml` → **ROS**(`cbuild`), `CMakeLists.txt` → **CPP**(`mbuild`), 둘 다 없으면 **PYTHON**(빌드 생략).
> - **`mksync --share`**: `--system-site-packages` 옵션으로 venv를 생성하여 ROS 1 `noetic` 환경에서 `rospy`, `catkin` 등 시스템 파이썬 패키지를 venv 내부에서 그대로 접근 가능하게 합니다.
> - **`ROS_DISTRO=noetic` 시 자동 적용**: `--share` 없이 `mksync`를 실행해도 `noetic` 환경이면 shared 모드가 자동으로 활성화됩니다.
> - **추가 인자 전달**: `--share`를 제외한 나머지 인자는 그대로 `uv sync`로 전달됩니다 (예: `mksync --extra gpu`).
> - `cbuild` / `mbuild` / `mksync` / `mkenv`는 모두 **함수**로 정의되어 있어 `docker build`의 비대화형 셸에서도 호출됩니다
>   (별칭은 비대화형 셸에서 전개되지 않으므로 빌드 진입점은 별칭으로 만들지 마세요 — `make verify` [build-entrypoints]이 이를 강제합니다).

### 2. 스타터 예제 노드 실행 테스트 (Starter Node Execution)

`src/example/`의 예제는 사용자의 실제 패키지가 프로젝트 타입 판별을 결정하도록 **빌드 시스템에 등록하지 않은 독립 파일**입니다.
따라서 아래와 같이 직접 실행/컴파일합니다:

```bash
# Python 스타터 노드 (ROS 2 / Pure Python 자동 판별)
python3 src/example/starter_node.py

# C++ 스타터 노드 컴파일 및 실행
mkdir -p build && g++ -std=c++17 src/example/starter_node.cpp -o build/starter_node
./build/starter_node
```

예제를 빌드 파이프라인에 편입하려면 `src/`에 `package.xml`(ROS) 또는 `CMakeLists.txt`(Pure C++)를 추가한 뒤
`mksync`(전체 동기화) 또는 `cbuild`/`mbuild`(빌드만)를 실행하세요.

### 3. 셸 환경의 단일 정의 (One Environment, Every Shell)

`config/init_bash.sh` **한 파일**이 DevKit 셸 환경을 정의하고, bash의 세 가지 호출 방식이 모두 이를 경유합니다:

| 호출 방식 | bash가 읽는 파일 | 경로 |
| :--- | :--- | :--- |
| 로그인 | `/etc/profile` | → `profile.d/devkit-*.sh` → `init_bash.sh` |
| 대화형 (`make shell`) | `/etc/bash.bashrc` | → 동일 훅 |
| **비대화형** (`bash -c`, CI) | **`$BASH_ENV`** | → 동일 훅 |

- **파일 상단**(환경)은 터미널 없이도 안전해야 하므로 출력이 없습니다. **하단**(프롬프트·MOTD·완성·심볼릭 링크)은
  `case $- in *i*)` 가드 아래에 있어 스크립트 셸에서는 실행되지 않습니다.
- `__DEVKIT_ENV_READY` 마커로 멱등 처리되어, 중첩 셸은 ROS/venv를 다시 소싱하지 않습니다 (오버헤드 약 10ms).
- `~/.bashrc`에는 **스냅샷을 굽지 않고** 훅을 가리키는 한 줄만 넣습니다 — 파일을 고치면 즉시 반영됩니다.

검증된 결과 (실이미지):

```
대화형 87개 : 비대화형 85개   차이 = LS_COLORS, __DEVKIT_MOTD_SHOWN (둘 다 대화형 전용)
비대화형 python3 -c "import rclpy"  → ok
```

#### 셸에 의존하지 않는 경로 (`/entrypoint.sh --env`)

위 훅들은 **bash 전용**입니다. `sh -c`, 바이너리 직접 exec, compose `command:`, k8s probe, VS Code 태스크 러너는
어떤 rc 파일도 거치지 않으므로 훅만으로는 원리적으로 덮을 수 없습니다.

그래서 엔트리포인트에 **exec 래퍼 모드**를 둡니다 — 부팅 때 확정된 환경을 불러온 뒤 대상을 그대로 `exec` 하므로,
셸을 전혀 거치지 않는 프로세스도 동일한 환경을 갖습니다:

```bash
docker exec <container> /entrypoint.sh --env python3 train.py
docker exec <container> /entrypoint.sh --env ./install/bin/app
docker exec <container> /entrypoint.sh --env sh -c 'echo $VIRTUAL_ENV'
```

실측 비교:

| 호출 | `WS_ROOT` |
| :--- | :--- |
| `docker exec c python3 …` | *없음* |
| `docker exec c /entrypoint.sh --env python3 …` | `/workspace` |

`make exec`가 이 경로를 사용하며(구버전 이미지에서는 bash로 폴백), `make verify` [env-bridge]이 존재를 강제합니다.
> `CMD` 안의 `$`는 make가 먼저 먹으므로 **두 번** 써야 컨테이너 셸에 도달합니다 —
> `make exec CMD='echo $$ROS_DISTRO'`. 단일 `$ROS_DISTRO`는 빈 문자열로 확장돼
> 명령이 조용히 잘린 문자열을 받습니다.

> [!TIP]
> 호스트에서는 그냥 **`make exec`** 를 쓰면 됩니다:
>
> ```bash
> make exec CMD='python3 -m pytest'        # 언어·프레임워크 무관
> make exec CMD='cmake --build build'
> make exec CMD='ros2 topic list'          # ROS 이미지에서만 의미 있음
> ```
>
> `exec`는 `ENV=ros`/`ENV=dev` 어느 이미지에서도 동일하게 동작합니다 — 컨테이너 셸에 명령을 넘길 뿐,
> ROS를 전제하지 않습니다. 다만 `CMD`는 make 변수를 거치므로 **작은따옴표로 감싸고 중첩 큰따옴표는 피하세요**;
> 복잡한 인용이 필요하면 스크립트 파일로 만들어 `make exec CMD='bash scripts/my_task.sh'` 형태로 호출하는 편이 안전합니다.
>
> `make verify` [env-bridge]이 이 구조(단일 훅 소싱 · 비대화형 무출력 · 스냅샷 미사용)를 강제합니다.

### 4. 의존성 관리 체계 (Dependency Management)

* **Python 패키지 (`uv`)**: `src/pyproject.toml`을 통해 관리됩니다. `uvs` 명령어로 초고속 파이썬 동기화를 수행합니다.
* **시스템 및 ROS 패키지**: `dependencies/` 디렉토리를 통해 관리되며, `sync_deps --rosdep` 명령어로 외부 레포지토리 수신 및 시스템 패키지를 설치합니다.
* `sync_deps` 및 `rosdep` 실패 시 즉시 프로세스가 중단됩니다. 의도적으로 일부 패키지만 설치하고 진행하려면 `DEVKIT_VCS_ALLOW_FAILURE=1` 또는 `DEVKIT_ROSDEP_ALLOW_FAILURE=1`을 지정하세요.

---

## 🧬 템플릿 버전과 상류 갱신 가져오기 (Template Lifecycle)

DevKit은 템플릿이므로, 이 위에 올린 프로젝트는 **어느 리비전에서 시작했는지**와 **그 뒤 무엇이
움직였는지**를 알아야 합니다.

| 파일 | 역할 |
| --- | --- |
| `VERSION` | 템플릿 리비전 한 줄. **커밋되어 파일과 함께 이동**하므로 GitHub 템플릿 버튼으로 만든(=DevKit 히스토리가 없는) 프로젝트도 자기 출발점을 압니다 |
| `v*` 주석 태그 | **무엇이 바뀌었는지**의 출처. 별도 변경 기록 파일은 두지 않습니다 — git 이 이미 가진 정보의 사본이 되고, 손으로 동기화할 두 번째 진실이 되기 때문입니다 |

### 버전 규약

버전의 "공개 API"는 **광고된 표면**입니다 — `make` 타겟, 컨테이너 내부 숏컷, `.env` 노브,
그리고 `scripts/verify_repo.sh`가 검증하는 계약.

| 상승 | 파생 프로젝트에 주는 의미 |
| --- | --- |
| **MAJOR** | 계속 쓰려면 **무언가 고쳐야 함** (타겟 이름 변경, 노브 제거, 필수 파일 추가) |
| **MINOR** | 새 기능. 의존하던 것은 그대로 |
| **PATCH** | 수정만 |

### 버전 올리기

전용 도구는 없습니다. 한 줄을 고치고 태그를 붙이는 일이라, 감싸는 스크립트는 규약을 한 번 더
적어두는 것 이상을 하지 못합니다. 태그 본문에 그 구간의 커밋 목록을 넣으면 `git show <태그>`와
GitHub 릴리스가 같은 내용을 싣고, MAJOR 상승이라면 **무엇을 고쳐야 하는지**를 첫 줄에 적으세요
— 파생 프로젝트가 가장 먼저 읽는 곳입니다.

```bash
printf '%s\n' "$NEW" > VERSION                     # semver 한 줄
make verify                                         # 형식과 일관성 확인
git commit -am "chore(release): v${NEW}"
git tag -a "v${NEW}"                                # 본문: git log --oneline <이전 태그>..HEAD

git log  --oneline <이전 태그>..<새 태그>            # 두 버전 사이 무엇이 바뀌었나
git diff <이전 태그>..<새 태그> -- Makefile config/ scripts/ docker/   # 커널 파일만
```

### 같은 버전의 내용인지 확인하는 법

`VERSION`은 템플릿 버전이 적히는 **유일한 곳**이고 나머지는 전부 파생됩니다 — `make status`는
파일을 읽고, 릴리스 매니페스트의 `devkit_version`은 빌드 시점에 박힙니다. 그래서 조각들이
어긋날 수가 없으며, check [template-version]이 그 구조를 검사합니다(`VERSION` 밖에 버전
문자열이 하드코딩되면 실패).

```bash
make status                                                  # DevKit Version: <VERSION> (커밋)
cat /etc/devkit/devkit-release.json | grep devkit_version    # 배포된 SIF/이미지가 스스로 답함
```

매니페스트의 `git_commit`은 프로젝트 커밋, `devkit_version`은 템플릿 리비전입니다 — fork
이후 두 값은 갈라지고, "환경이 왜 달라졌나"에 답하는 쪽은 후자입니다.

- `src/pyproject.toml`의 `version`은 **당신 프로젝트의 버전**입니다. 템플릿 버전과 묶지 않으니
  자유롭게 올리세요.
- `.env`가 현재 템플릿과 같은 세대인지는 `make check`가 답합니다 — `.env.example`에 있고
  `.env`에 없는 키를 나열하므로 오래된 `.env`는 바로 드러납니다.

### 상류 갱신 가져오기

```bash
# 1) 최초 1회: 상류를 원격으로 등록
git remote add upstream https://github.com/Lee-hwansoo/DevKit.git
git fetch upstream

# 2) 무엇이 바뀌었는지 먼저 읽기 (MAJOR 인지 확인)
git diff HEAD upstream/main -- VERSION
git log --oneline "v$(cat VERSION)"..upstream/main

# 3) 커널 파일만 선별 병합 — src/ 와 .env 는 당신 것이므로 건드리지 않습니다
git diff HEAD upstream/main -- Makefile config/ scripts/ docker/ docker-compose*.yml
git checkout upstream/main -- config/ scripts/        # 예: 셸/스크립트 계층만 갱신

# 4) 계약으로 검증 후 커밋
make verify && make build && make test
```

> [!TIP]
> `make verify`가 통과하면 병합이 키트의 런타임 계약을 깨지 않았다는 뜻입니다. 반대로 실패
> 메시지는 어느 계약이 깨졌는지 슬러그로 알려주므로(`check [env-bridge]` 등), 그 항목만
> 확인하면 됩니다. `.env`는 절대 상류에서 덮어쓰지 말고 `.env.example`과 **차이만** 보세요:
> `diff <(sort .env.example) <(sort .env) | head -40`

---

## 📄 라이선스 및 사용 지침 (License & Usage)

본 **DevKit** 보일러플레이트 코드 및 설정 파일은 **[MIT-0 (MIT No Attribution)](LICENSE)** 라이선스로 제공됩니다.

- **출처 표기 의무 없음**: 템플릿 사용 시 원작자나 출처를 명시할 필요가 없으며, 상용·개인·기업 내부망 등 어떤 목적이든 자유롭게 활용 가능합니다.
- **자유로운 라이선스 변경**: 새 프로젝트에 이 템플릿을 사용할 때 루트의 `LICENSE` 파일을 자유롭게 삭제하거나 본인 프로젝트의 라이선스로 덮어쓸 수 있습니다.

---

## 📦 프로덕션 & 이식성 (Apptainer SIF)

HPC 및 클러스터 환경 배포를 위해 워크스페이스를 단일 이진 파일인 **SIF (Singularity Image File)**로 추출합니다.

### 🧊 SIF 생성 및 실행 명령어 가이드

| 작업 구분 | CLI 명령어 | 결과 및 특징 |
| :--- | :--- | :--- |
| **Bake Dev Snapshot** | `make bake-dev ENV=ros\|dev` | 독립 가상환경을 포함한 개발용 SIF 스냅샷 생성 |
| **Bake Dev Shared** | `make bake-dev ENV=ros\|dev SHARE=1` | 시스템 site-packages를 공유하는 개발용 SIF 스냅샷 생성 |
| **Bake Production** | `make bake-prod ENV=ros\|dev [PROD_FULL_CUDA=1]` | `install/` 및 런타임 의존성만 포함하는 최적화 운영 SIF 생성 |
| **Run Dev** | `make run-sif SIF_MODE=dev` | 소스 바인드 상태로 개발용 SIF 실행 |
| **Run Production** | `make run-sif SIF_MODE=prod ENV=ros\|dev RUN_ARGS='cmd'` | 소스 바인드 없이 산출물 격리 실행 |
| **Run SLURM** | `make run-sif SIF_MODE=slurm ENV=ros\|dev RUN_ARGS='cmd'` | SLURM 배치 스케줄러 노드에 작업 제출 |
| **SLURM Control** | `make slurm-status` / `make slurm-cancel` | 활성/대기 중인 SLURM 배치 작업 조회 및 취소 |

**Bake 단계에서 인식하는 추가 변수** (모두 `docker build --build-arg`로 전달됩니다):

| 변수 | 기본값 | 설명 |
| :--- | :--- | :--- |
| **`SHARE=1`** | *(없음)* | `bake-dev` 전용. 스냅샷 내부 `mksync --share` 수행 (ROS 1 Noetic) |
| **`PROD_FULL_CUDA=1`** | `false` | 런타임 CUDA를 최소 셋이 아닌 전체 툴킷으로 포함 (`FULL_CUDA` 빌드 인자) |
| **`IMAGE_TAG=`** | `latest` | 릴리스 메타데이터(`/etc/devkit/devkit-release.json`)에 기록될 태그 |
| **`SOURCE_DATE_EPOCH=`** | *(없음)* | 재현 가능 빌드용 고정 타임스탬프 |

---

## 🛡️ 배포 시 소스 비유출 (Source Protection)

프로덕션 이미지는 `install/`만 복사하고 `src/`는 넣지 않습니다. **그러나 그것이 "소스가 안 나간다"는 뜻은 아닙니다** —
colcon은 `ament_python` 패키지의 `.py`를 `install/<pkg>/lib/pythonX.Y/site-packages/`로 **원본 그대로 복사**합니다.

`check_deps.sh`(프로덕션 빌더에서 자동 실행)가 이를 감사하고, 선택적으로 제거합니다:

| 환경변수 | 동작 |
| :--- | :--- |
| *(기본)* | 노출 현황만 보고 — `Source exposure: N python module(s), M launch script(s)` |
| **`DEVKIT_STRIP_SOURCE=1`** | `.py` → `.pyc` 바이트컴파일 후 **원본 삭제** (`__pycache__`도 정리) |
| **`DEVKIT_FAIL_ON_SOURCE=1`** | 평문 소스가 남아 있으면 **빌드 실패** (CI 게이트용) |

```bash
DEVKIT_STRIP_SOURCE=1 DEVKIT_FAIL_ON_SOURCE=1 make bake-prod ENV=ros
```

**제외 대상 (의도적)**

- `install/.venv/**` — 서드파티 패키지이지 프로젝트 소스가 아닙니다.
- `**/launch/*.py` — ROS 2 launch 시스템이 **소스로 읽어** 실행하므로 바이트컴파일하면 `ros2 launch`가 깨집니다.
  런치 파일에 비밀이 들어가지 않도록 설계하고, 파라미터는 YAML이나 환경변수로 분리하세요.

> [!WARNING]
> **바이트컴파일은 난독화이지 암호화가 아닙니다.** 실제 이미지에서 `.pyc`를 열어 확인한 결과,
> 다음은 **그대로 남습니다**:
>
> ```
> DEVKIT_SECRET_MARKER_9F3A                              ← 문자열 상수 전체
> PROPRIETARY_CONSTANT                                    ← 식별자·함수명
> /workspace/install/.../leaktest/core.py                 ← 원본 파일 경로
> ```
>
> 즉 **하드코딩된 비밀값(API 키, 토큰, 알고리즘 상수)은 전혀 보호되지 않습니다** — 그런 값은
> 코드가 아니라 환경변수나 시크릿 저장소로 분리하세요. `.pyc`가 가리는 것은 구현 로직의 가독성뿐이며,
> `uncompyle6`류로 디컴파일도 가능합니다.
> 실제 보호가 필요하면 **네이티브 컴파일**(C++ 노드, 또는 Nuitka·Cython)로 가야 하며,
> 이 경우 `install()` 규칙으로 바이너리만 설치되게 하면 소스는 전혀 나가지 않습니다.

---

## 🔒 재현성 (Reproducibility) — 현재 보장 범위

빌드 재현성은 **입력을 몇 겹까지 고정했는지**로 결정됩니다. DevKit이 제공하는 메커니즘과, 사용자가 직접 고정해야 하는 부분을 구분합니다.

| 입력 계층 | 고정 수단 | 상태 |
| :--- | :--- | :--- |
| Ubuntu APT 패키지 | `APT_SNAPSHOT_DATE=YYYYMMDDTHHMMSSZ` → `snapshot.ubuntu.com` 시점 미러 고정 | ✅ 구현됨 |
| APT 서명키 | `ROS_GPG_FINGERPRINT` 상수 대조 (`STRICT_GPG_CHECK=true` 시 불일치 중단) | ✅ 구현됨 |
| 빌드 타임스탬프 | `SOURCE_DATE_EPOCH` → 릴리스 메타데이터 `build_date` | ✅ 구현됨 |
| 외부 소스 저장소 | `dependencies.repos`의 `version:`에 **태그·커밋 해시** 지정 | ⚠️ 사용자 책임 (**`sync_deps`가 브랜치 참조를 경고**) |
| 빌드 산출물 자체 포함성 | prod 빌더는 `--symlink-install` 미사용 (`DEVKIT_BUILD_TYPE=prod`) | ✅ 구현됨 |
| 설치 결과 감사 | `dpkg-query`/`pip freeze` 매니페스트 + SHA-256을 이미지에 동봉 | ✅ 구현됨 |
| Python 의존성 | `src/uv.lock` (최초 `mksync` 후 생성) | ⚠️ **파생 프로젝트 책임** (템플릿은 lock을 배포하지 않음) |
| 베이스 이미지 | `.env`에 `BASE_IMAGE=ubuntu@sha256:<digest>` 로 다이제스트 고정 | ⚠️ 사용자 책임 (기본은 가변 태그 `ubuntu:22.04`) |
| ROS APT 패키지 | packages.ros.org에는 스냅샷 서비스가 **없음** | ❌ 불가 (아래 참조) |
| `rosdep install` | 해석 결과가 시점에 따라 달라짐 | ❌ 불가 |

**완전 재현이 필요한 경우의 권장 절차**

```bash
# 1) Python 의존성 잠금 — 파생 프로젝트에서 최초 1회 후 커밋
#    DevKit 자체는 lock을 커밋하지 않습니다: 템플릿이 특정 시점의 해석 결과를
#    배포하면 모든 fork가 그 스냅샷을 물려받습니다. lock은 제품이 되는 저장소의
#    것이므로, 이 저장소를 복제한 뒤 여기서 커밋하세요.
mksync && git add src/uv.lock && git commit -m "chore: pin python dependencies"

# 2) 베이스 이미지 다이제스트 고정 (.env)
docker buildx imagetools inspect ubuntu:22.04 | grep Digest   # → sha256:...
echo 'BASE_IMAGE=ubuntu@sha256:<digest>' >> .env

# 3) APT 스냅샷 + 타임스탬프 고정 후 빌드
APT_SNAPSHOT_DATE=20260801T000000Z SOURCE_DATE_EPOCH=1785542400 make bake-prod ENV=ros
```

> [!IMPORTANT]
> **ROS APT 계층은 시점 고정이 불가능합니다.** packages.ros.org는 스냅샷 미러를 제공하지 않으므로
> `ros-humble-*` 패키지 버전은 빌드 시점에 따라 달라질 수 있습니다. 비트 단위 재현이 필요하다면
> ① `dependencies/apt_ros.txt`에 `패키지=버전`으로 명시하거나, ② 검증된 이미지를 **`make bake-prod`로 SIF에 봉인**해
> 그 아티팩트를 배포하세요. SIF는 그 자체로 완전한 동결 스냅샷입니다.

### 고정 불가 계층의 대안 — 빌드 매니페스트 (감사 및 사후 고정)

고정할 수 없는 계층은 **무엇이 설치되었는지 기록**해 감사 가능하게 만듭니다. 모든 프로덕션 이미지의
`/etc/devkit/`에 다음이 동봉됩니다:

| 파일 | 내용 |
| :--- | :--- |
| `devkit-release.json` | `base_image`, `apt_snapshot`, `source_date_epoch`, `build_type`, `git_commit`, 매니페스트 **SHA-256** |
| `devkit-apt-manifest.txt` | 설치된 전체 APT 패키지 `이름=버전` (정렬됨) |
| `devkit-pip-manifest.txt` | venv의 `pip freeze` 결과 (정렬됨) |

```bash
# 두 빌드 사이에 무엇이 움직였는지 확인
docker run --rm img-a cat /etc/devkit/devkit-apt-manifest.txt > a.txt
docker run --rm img-b cat /etc/devkit/devkit-apt-manifest.txt > b.txt
diff a.txt b.txt

# 검증된 빌드와 동일한 의존성 집합인지 한 값으로 확인
docker run --rm img cat /etc/devkit/devkit-release.json | grep sha256
```

매니페스트 한 줄을 그대로 `dependencies/apt_ros.txt`에 붙여넣으면(`ros-humble-rclcpp=16.0.10-1jammy.20260801`)
해당 패키지가 그 시점으로 **사후 고정**됩니다.
>
> 스냅샷 서버가 불통이면 빌드는 **중단**됩니다 — 롤링 미러로 조용히 넘어가면 재현성이 무의미해지기 때문입니다.
> 의도적으로 넘어가려면 `APT_SNAPSHOT_FALLBACK=1`을 명시하세요. (`make verify` [reproducibility]이 이 메커니즘의 존재를 강제합니다.)

---

## 🏥 진단 유틸리티 & 헬스 체크

### 🖥️ 1. 호스트 측 진단 명령어 (Host Utilities)
* **`make gpus`**: 호스트 PC의 GPU (NVIDIA/iGPU) 가속 및 VRAM 상태 조회.
* **`make check`**: Docker CLI/데몬 · Compose v2 · BuildKit 사전 점검, `.env` ↔ `.env.example` 키 누락 대조,
  WSL2 진단, NVIDIA Container Toolkit 미설정 감지(해결 명령 동반). `build`/`start`의 선행 의존성입니다.
* **`make status`**: 프로젝트 요약 + **`[Detected Host Wiring]`** (GPU 디바이스, WSL 라이브러리, 디스플레이,
  XDG/Xauthority, ssh-agent, git 신원, 컨테이너 UID/GID) — 자동 감지 결과를 한눈에 확인.
* **`make clean-cache`**: 호스트 감지 캐시(`.docker_cache/detected-env.mk`) 무효화 → 다음 `make` 실행 시 재감지.
* **`make verify`**: 24개 계약을 실행으로 검증 (아래 표, 약 0.5초).

| # | 검증 계약 | 회귀 시 증상 |
| :-- | :--- | :--- |
| 1–3 | 필수 파일·실행 권한, `bash -n` 문법, `.PHONY` ↔ 룰 일치 | 파일 누락, 문법 오류, 미정의 타겟 |
| 4 | `find ... -quit`에 `-print` 동반 | 탐색 결과가 항상 비어 감지가 조용히 무력화 |
| 5 | compose가 쓰는 `HOST_*`/`WSL_*`를 `check_env.sh`가 모두 방출 | GPU·X11·Wayland·ssh-agent 패스스루 소실 |
| 6 | APT 태그 필터 계약 (`all`/`builder`/`runtime`, ros1/ros2) | 비-ROS 스테이지 빌드 실패, 운영 이미지 비대화 |
| 7 | `setup_gpu.sh`의 `GPU_ENV_FILE` 영속화 | `make shell` 세션에서 GPU 환경변수 유실 |
| 8 | `cbuild`/`mbuild`/`mksync`가 함수 | `docker build` 중 `command not found` |
| 9 | 감지 캐시 원자적 쓰기 + 실패 시 즉시 중단 | 부분 캐시가 영구 재사용되어 모든 마운트 소실 |
| 10 | 도움말/MOTD가 광고하는 숏컷이 실제로 정의됨 | `command not found` (예: `check_deps`) |
| 11 | 런타임 환경이 로그인·대화형·비대화형 셸 모두에 도달 + rosdep 캐시 시딩 | 스크립트 셸에서 ROS/venv 유실, `mksync` 실패 |
| 12 | ROS GPG 지문 핀 + `make update-gpg` 대상 일치 | 서명키 검증 소실(공급망), 업데이터 파손 |
| 13 | 문서화된 노브에 동작하는 소비자 존재 | 공개 API를 죽은 코드로 오인해 삭제 (`DEBUG_MODE`) |
| 14 | `make clean`이 venv 보존 + 링크·빈 `install/` 제거 + `clean-all`이 이미지 제거 | 가상환경 파괴, 끊어진 링크·GB 단위 이미지 잔존 |
| 15 | 문서화된 환경 노브에 구현이 존재 | 광고만 되고 동작하지 않는 스위치 |
| 16 | 렌더링 프로브가 `timeout` 보호 + errexit 안전 | 도달 불가 `DISPLAY`에서 진단이 무한 정지 |
| 17 | 리다이렉트/`NO_COLOR` 시 ANSI 미출력 | CI 로그·파일 캡처가 제어문자로 오염 |
| 18 | 재현성 수단(APT 스냅샷·`SOURCE_DATE_EPOCH`·GPG 핀) 배선 | 재현 빌드 불가 |
| 19–22 | 프로덕션 엔트리포인트 계약, 탭 완성 ↔ `.PHONY`, VS Code JSON 확장, Dockerfile 패키지 정책 | 배포·자동완성·IntelliSense·이미지 비대화 |
| 23 | SIF 파이프라인: 빌드 인자 전달(`CUDA_VERSION` 등)·CUDA repo 배선·잘못된 플래그/ENV 거부·`SYNC_TARGET_DIR`·ROS 바인딩 검사 환경 | CUDA 없는 SIF 침묵 생성, 오타 입력 무시, 스테이징 격리 소실 |
| 24 | 보안 기본값·가드: fail-closed GPG 핀(ROS+NVIDIA)·비특권 컨테이너·TLS 스냅샷(전칭)·범위 제한 xhost·사용자명 새니타이즈·`rm -rf` 가드·빈 배열 관용구·캐시 주입 프로브 | 키 교체 침묵 수용, 컨테이너 탈출 표면, 롤백 공격, 프로젝트명 파손, 데이터 손실, SLURM 노드 즉사, make 코드 주입 |

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

* **`gpu <mode>`**: 렌더링 모드 전환 (`auto`/`nvidia`/`intel`/`amd`/`igpu`/`cpu`).
  결과가 `~/.gpu_env.sh`에 기록되어 이후 새 셸에도 동일하게 적용됩니다.
* **`gpu_check` / `vulkan_check`**: 한 줄짜리 빠른 렌더러 확인.
* **`check_deps`**: `install/` 내 누락된 `*.so` 라이브러리를 `ldd`로 탐지.

> 진단 프로브(`glxinfo`/`eglinfo`/`vulkaninfo`)는 모두 `timeout` 보호됩니다 — `DISPLAY`가 설정되었지만
> 서버에 닿지 못하는 상황에서 진단이 멈추지 않도록 하기 위함이며, `make verify` [render-probes]이 이를 강제합니다.
> `eglinfo`는 모든 플랫폼을 초기화하느라 ~1.8초가 걸려 `hwcheck`에서는 제외하고 `gpus`에서만 조회합니다.

---

## 🤖 CI (GitHub Actions)

개발 도구이므로 **흔한 push 가 컨테이너 빌드를 기다리지 않도록** 두 티어로 나눠 두었습니다.

| 워크플로 | 트리거 | 내용 | 실작업 |
| :--- | :--- | :--- | :--- |
| `verify.yml` | 모든 push · PR | `make verify`(계약 31개) + `docker build --check`(레이어 없이 멀티스테이지 린트) | **~2.2초** |
| `images.yml` | `docker/**`·`dependencies/**`·apt 헬퍼 변경 시 + 주간 cron + 수동 | ROS 1/ROS 2 apt 키 경로(컨테이너 안, tty 없음) · CUDA 저장소 핀 · `base`/`build-core` 실제 빌드 | 수 분 |
| `images.yml` → `runtime-smoke` | **cron · 수동 전용** | 전체 이미지 빌드 → `make start` → 비-bash 프로세스에서 `import rclpy` · `xdpyinfo` 존재 · `mksync` 후 venv 활성/명명 · `check_deps` | ~20분 |

> 두 워크플로 모두 `concurrency: cancel-in-progress` 로 이전 실행을 자동 취소합니다.
> `config/**` 변경은 런타임 잡을 트리거하지 않습니다 — 대신 그 부류의 회귀(`LD_LIBRARY_PATH` 오염,
> venv 미활성, tty 없는 MOTD)는 각각 호스트에서 도는 계약으로 고정돼 있어 fast 티어가 1.4초에 잡습니다.
> 병합 전에는 `runtime-smoke` 를 수동으로 한 번 돌리는 것을 권장합니다.

---

## 🔁 이전 이름 (Deprecated Names)

DevKit은 베이스 키트이므로 진입점 이름을 바꾸면 그 위에 올린 프로젝트의 CI가 깨집니다.
아래 이름은 **계속 동작**하며, 실행 시 새 이름을 한 줄로 안내한 뒤 위임합니다.
탭 완성과 `make help` / `h`에는 노출되지 않으므로 새 코드에서는 오른쪽 이름만 쓰세요.
(`make verify` [deprecated-entrypoints]가 위임 동작을 실행으로 검증합니다.)

| 이전 이름 | 현재 이름 | 비고 |
| :--- | :--- | :--- |
| `make check-host` | `make check` | 호스트 GPU/툴킷 점검이 `check`로 통합 |
| `make env-check` | `make check` | `.env` ↔ `.env.example` 키 비교가 `check`로 통합 |
| `make completion` / `completion-install` | `make setup` | `setup`이 탭 완성을 `~/.bashrc`에 등록 |
| `hw_check` (컨테이너) | `hwcheck` | 동일 스크립트, 이름만 변경 |

> **`software` GPU 모드는 예외적으로 제거되었습니다.** `cpu`와 완전히 동일한 동작이었고
> `GPU_MODE`·`gpu` 명령·README 어디에도 문서화된 적이 없는 내부 동의어였기 때문입니다.
> 한 동작에 두 이름을 남기지 않는다는 원칙에 따라 `cpu` 하나만 유지합니다.

---

## 📝 모범 사례 (Best Practices)

1. **환경 소싱 (`s`)**: 빌드 후 또는 새 터미널을 열었을 때 `s` 알리애스 (`source install/setup.bash`) 실행.
2. **파이썬 가상환경 진입**: `activate` 알리애스를 통해 isolated venv 진입.
3. **스마트 빌드**: ROS 패키지는 `cbuild`, Pure C++ 프로젝트는 `mbuild` 사용.
