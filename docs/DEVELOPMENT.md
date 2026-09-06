# 📘 DevKit 개발자 워크플로우 & 툴체인 가이드

매일 쓰는 것들입니다 — 규칙이 한 곳에서만 정의되는 구조, `mksync` 와 품질 루프, 셸 환경, 정리,
템플릿 버전과 상류 갱신, CI. 처음 프로젝트를 만드는 순서는 [GETTING_STARTED.md](GETTING_STARTED.md),
의존성 파일은 [DEPENDENCIES.md](DEPENDENCIES.md), 배포물은 [DEPLOY.md](DEPLOY.md) 가 소유합니다.
문서 전체 지도는 [README](../README.md#-문서-안내) 에 있습니다.

---

## 🏛️ 아키텍처: 단일 진실 공급원 (SSOT)

컨테이너 안의 모든 경로는 `${WORKSPACE_PATH}`(기본 `/workspace`) 아래에서 `config/util_paths.sh` 가
한 번 조합합니다. 호스트에서 실행되는 스크립트도 같은 파일을 소스하는데, make 가 컨테이너 경로를
호스트 레시피에도 export 하므로 `WORKSPACE_PATH` 는 **그 자리에 DevKit 트리가 있을 때만** 믿고,
아니면 자기 파일 위치로 루트를 잡습니다. 그래서 `make bake-prod` 가 `/workspace/scripts` 를 찾다 죽는 일이 없습니다.

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
| `scripts/util_sif_common.sh` | SIF 런타임 바이너리, 아키텍처 태그, 아티팩트 이름, 엔트리포인트 경유, 런타임 환경 전달·GPU 플래그·데이터 바인드·실행 기록 |
| `scripts/util_gpu_detect.sh` | GPU 벤더·디바이스 노드 감지 |
| `scripts/util_apt_helper.sh` | 빌드 타임 APT 저장소 신뢰 앵커, 태그 필터 설치, 부트스트랩 도구 정리 |
| `scripts/util_cuda_apt.sh` | CUDA/cuDNN apt 프로파일 설치 |
| `scripts/util_setup_links.sh` | 워크스페이스 심볼릭 링크(`colcon.meta`, `.venv`, `compile_commands.json`) |
| `scripts/util_release_metadata.sh` | 릴리스 메타데이터 및 APT/pip 매니페스트 생성 |

---

## 🏁 통합 개발 워크플로우

### 1. 원클릭 가상환경 & 빌드 동기화 (`mksync`)

```bash
mksync
```

> [!TIP]
> **`mksync` 동작 시퀀스**:
> `mkenv` (venv 생성) ➔ `uvs` (`pyproject.toml` 파이썬 동기화) ➔ `sync_deps --rosdep` (vcs import + overlay + rosdep) ➔ **프로젝트 타입 판별 후 빌드**.
> - venv 는 `install/.venv` 에 만들어지고 **프로젝트 이름으로 명명**됩니다(`--prompt "$COMPOSE_PROJECT_NAME"`) —
>   프롬프트에 `(myproject-lee)` 로 보이므로 여러 워크스페이스를 오갈 때 어느 셸인지 한눈에 구분됩니다.
> - `uv sync` 는 venv 가 이미 가진 인터프리터에 고정됩니다(`--python`). 이게 없으면 uv 가 `UV_PYTHON` 과
>   불일치를 이유로 환경을 **재생성**해, ROS 이미지의 shared venv 가 pure 로 바뀌며 `rclpy`/`rospy` 가 사라집니다.
> - **프로젝트 타입 판별**: `ROS_DISTRO`가 있으면 `src/thirdparty`를 제외한 `src/`에서 `package.xml`을 찾아 **ROS**(`cbuild`)로 판별합니다. 없으면 저장소 루트 또는 `src/`의 `CMakeLists.txt`로 **CPP**(`mbuild`; 같은 `__cmake_entry`가 빌드 진입점을 정합니다), 둘 다 없으면 **PYTHON**(빌드 생략)입니다.
> - **shared venv**: `/opt/ros/<distro>`가 있으면 `--share` 없이도 `--system-site-packages` venv 가 됩니다 — ROS 파이썬 바인딩은 시스템 dist-packages에 있어 격리된 venv 에서는 import 되지 않기 때문입니다. `--share` 를 명시하는 것은 비-ROS 이미지에서 시스템 패키지를 공유하고 싶을 때만 의미가 있습니다.
> - 이미 격리된 venv 가 있는데 shared 가 필요하면 `mksync`가 조용히 진행하지 않고 `mkenv --share`를 한 번 실행하라고 멈춥니다.
> - **추가 인자 전달**: `--share`를 제외한 나머지 인자는 그대로 `uv sync`로 전달됩니다 (예: `mksync --extra gpu` — `pyproject.toml` 이 그 extra 를 선언한 뒤에).
> - `cbuild` / `mbuild` / `mksync` / `mkenv`는 모두 **함수**로 정의되어 있어 `docker build`의 비대화형 셸에서도 호출됩니다
>   (별칭은 비대화형 셸에서 전개되지 않으므로 빌드 진입점은 별칭으로 만들지 마세요 — `make verify` [build-entrypoints]이 이를 강제합니다).

의존성 파일(`pyproject.toml`, `dependencies/*`)의 규칙과 동기화 실패 정책은 [DEPENDENCIES.md](DEPENDENCIES.md) 에 있습니다.

### 2. 품질 루프 — 테스트와 린트 (`mtest` / `mlint`)

빌드(`cbuild`/`mbuild`)의 형제입니다. 둘 다 `mksync`와 **같은 프로젝트 형태 감지**를 사용하므로
플래그를 외울 필요가 없습니다.

```bash
# 컨테이너 내부
mtest                # ROS → colcon test + test-result / CMake → ctest / 순수 Python → pytest
mlint                # ruff check + ruff format --check (+ clang-format이 있으면 C/C++까지)
mlint --fix          # 자동 수정 가능한 것만 적용

# 호스트에서 (동일 경로를 make exec으로 경유)
make test ENV=ros
make lint ENV=ros FIX=1
```

**러너는 어디서 오는가**: `src/pyproject.toml`의 `[dependency-groups] dev`에 `ruff`와 `pytest`가
있고, `uv sync`는 이 그룹을 **기본으로 설치**합니다 — 즉 `mksync` 한 번이면 준비됩니다. 버전은
DevKit이 추측하지 않고 파생 프로젝트의 `uv.lock`이 고정합니다. 프로덕션 빌드는
`--no-default-groups`로 이 그룹을 제외하므로 배포 이미지에는 들어가지 않습니다
(`scripts/verify_repo.sh` check [reproducibility]가 실행으로 검증).

**규칙의 출처는 `.editorconfig` 하나**입니다. ruff와 clang-format은 `.editorconfig`를 읽지
않으므로 같은 값을 `src/pyproject.toml`의 `[tool.ruff]`와 `.clang-format`에 복제해 두었고,
셋이 어긋나면 check [style-config]가 실패합니다. 저장 시 포맷(`editor.formatOnSave`)이 적용하는
규칙과 `mlint`가 검사하는 규칙이 동일하므로, 에디터에서 깨끗한 파일은 CI에서도 깨끗합니다.

> [!NOTE]
> `clang-format`은 **선택 설치**입니다(libllvm 의존성). 에디터는 C/C++ 확장에 내장된 복사본을
> 쓰므로 CLI 검사가 필요할 때만 켭니다 ([opt-in 되살리기](DEPENDENCIES.md#-opt-in-기능-되살리기)). 테스트가 아직 없는 프로젝트에서 `mtest`는 실패가 아니라 안내를 출력합니다.

CI 에서 같은 루프를 도는 `project.yml` 은 아래 [CI 절](#-ci-github-actions) 에 있습니다.

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
- 엔트리포인트는 부팅 때 확정한 값(XDG 런타임 디렉터리, GPU 환경, DDS 설정)을 `/etc/profile.d/devkit-*.sh` 에 남기고,
  root 로 만든 볼륨과 첫 실행 동기화 결과의 소유권을 컨테이너 사용자에게 넘긴 뒤 권한을 낮춰 명령을 실행합니다.

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

`make exec`가 이 경로를 사용하며(구버전 이미지에서는 bash로 폴백), `make verify` [env-bridge]이 엔트리포인트를
실제로 부팅해 검증합니다.

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
> ROS를 전제하지 않습니다. `CMD` 안의 `$`는 make가 먼저 먹으므로 **두 번** 써야 컨테이너 셸에 도달합니다
> (`make exec CMD='echo $$ROS_DISTRO'`). 작은따옴표로 감싸고 중첩 큰따옴표는 피하세요 — 복잡한 인용이 필요하면
> 스크립트 파일로 만들어 `make exec CMD='bash scripts/my_task.sh'` 형태로 호출하는 편이 안전합니다.

### 4. 환경 소싱과 이동

- **`s`**: 빌드 후 또는 새 터미널에서 워크스페이스 오버레이를 소싱합니다 — ROS 2 는 `install/setup.bash`, ROS 1 은 `devel/setup.bash` 를 고릅니다. 실패한 `setup.bash` 는 성공으로 보고되지 않습니다.
- **`activate`**: `install/.venv` 진입. 새 셸은 `init_bash.sh` 가 이미 활성화해 두므로 보통 필요 없습니다.
- **`cw` / `cs` / `cc`**: 워크스페이스 루트 / `src/` / `config/`.
- **`gpu <mode>`**: 가속 모드 전환(현재 셸에 적용되고 `~/.gpu_env.sh` 에 남음). 진단은 [DIAGNOSTICS.md](DIAGNOSTICS.md).

---

## 🧹 정리와 초기화 (Cleanup)

| 명령 | 범위 | 비고 |
| :--- | :--- | :--- |
| `mclean` (컨테이너) | `build/`, `devel/`, `log/`, `install/` 의 산출물을 **비움** (마운트 지점이라 지우지는 않음) | venv 는 `mclean --all` 에서만. 남은 항목이 있으면 실패로 보고 |
| `make clean` | 호스트의 `build/`, `devel/`, `log/`, `install/` 산출물과 편의 심볼릭 링크(`compile_commands.json`, `.venv`, `colcon.meta`) | `install/.venv` 보존 — 재생성에 `mksync` 전체가 필요. 지우려면 `KEEP_VENV=0`(확인 프롬프트). Docker 가 root 로 만든 디렉터리는 해결 명령을 안내 |
| `make clean-cache` | `.docker_cache/`(호스트 감지 캐시·플레이스홀더) | 컨테이너가 떠 있으면 거부 — Docker 가 마운트 소스를 root 로 다시 만들기 때문 |
| `make clean-all` | 컨테이너 · 프로젝트 named 볼륨 · **compose 가 빌드한 이 프로젝트 이미지**(`--rmi local`) · 호스트 산출물 · 캐시 | 확인 프롬프트. `KEEP_VENV=1` 은 venv 가 든 `install` 볼륨만 남겨 재빌드 후 `mksync` 없이 접속 |
| `make stop` / `make down` | 선택한 `ENV` 의 서비스만 | `ENV=ros` 는 `basic-*` 컨테이너를 건드리지 않음 |
| `make docker-clean` | **호스트 전체**의 고아 이미지 · BuildKit 캐시 · 미사용 볼륨 | 다른 프로젝트도 영향. 삭제 대상을 보여주고 확인 |

기본 구성에서 `build/install/log` 는 **named 볼륨**이므로 컨테이너 쪽 산출물은 `make clean-all` 이 제거합니다.
파괴적 타겟의 확인 생략은 `FORCE=1` 또는 `CI=true` 같은 **정확한 true 값**만 인정합니다(`FORCE=0` 은 거부).

---

## 🧬 템플릿 버전과 상류 갱신 가져오기 (Template Lifecycle)

DevKit은 템플릿이므로, 이 위에 올린 프로젝트는 **어느 리비전에서 시작했는지**와 **그 뒤 무엇이
움직였는지**를 알아야 합니다. 어떤 파일이 누구의 것인지는 [GETTING_STARTED.md](GETTING_STARTED.md#누가-무엇을-소유하나) 의 표에 있습니다.

| 파일 | 역할 |
| --- | --- |
| `VERSION` | 템플릿 리비전 한 줄. **커밋되어 파일과 함께 이동**하므로 GitHub 템플릿 버튼으로 만든(=DevKit 히스토리가 없는) 프로젝트도 자기 출발점을 압니다 |
| `v*` 주석 태그 | **무엇이 바뀌었는지**의 출처. 별도 변경 기록 파일은 두지 않습니다 — git 이 이미 가진 정보의 사본이 되고, 손으로 동기화할 두 번째 진실이 되기 때문입니다 |

### 버전 규약

버전의 "공개 API"는 **광고된 표면**입니다 — `make` 타겟, 컨테이너 내부 숏컷, `.env` 노브,
그리고 `scripts/verify_repo.sh`가 검증하는 계약.

| 상승 | 파생 프로젝트에 주는 의미 |
| --- | --- |
| **MAJOR** | 계속 쓰려면 **무언가 고쳐야 함** (타겟 이름 변경, 노브 제거, 필수 파일 추가, 기본 설치에서 opt-in 으로 전환) |
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

본 **DevKit** 보일러플레이트 코드 및 설정 파일은 **[MIT-0 (MIT No Attribution)](../LICENSE)** 라이선스로 제공됩니다.

- **출처 표기 의무 없음**: 템플릿 사용 시 원작자나 출처를 명시할 필요가 없으며, 상용·개인·기업 내부망 등 어떤 목적이든 자유롭게 활용 가능합니다.
- **자유로운 라이선스 변경**: 새 프로젝트에 이 템플릿을 사용할 때 루트의 `LICENSE` 파일을 자유롭게 삭제하거나 본인 프로젝트의 라이선스로 덮어쓸 수 있습니다.

---

## 🤖 CI (GitHub Actions)

세 워크플로가 세 티어를 이룹니다. 흔한 push 가 컨테이너 빌드를 기다리지 않도록 빠른 티어를 분리했고,
무거운 잡은 cron·수동 전용입니다. 셋 모두 `concurrency: cancel-in-progress` 로 같은 ref 의 이전 실행을 취소합니다.

> **호스트 OS 범위**: CI 는 **Ubuntu(네이티브 Linux)** 와 **macOS** 러너에서 돕니다. GitHub 에 WSL2 러너는 없으므로
> WSL2 경로(`/proc/version` 판정·`/dev/dxg`·`/usr/lib/wsl`·WSLg 소켓)는 CI 가 아니라 README 지원 매트릭스의
> **참조 호스트** 실측으로만 검증됩니다.

### `verify.yml` — 빠른 티어 (모든 push · PR, 이미지 빌드 없음)

| 잡 | 러너 | 무엇을 증명하나 |
| :--- | :--- | :--- |
| `contracts` | ubuntu | `make verify`(계약 전체) · tty·BASH_ENV 없는 `ubuntu:22.04` 컨테이너에서 `util_aliases.sh` 부트스트랩 · 네이티브 Linux 호스트 감지(`IS_WSL=false`, GPU 플래그, DXG 마운트 중립) · `docker build --check` 멀티스테이지 린트 |
| `macos-host` | macos | 같은 `make verify` 를 bash 3.2 · BSD sed/awk/stat 위에서 · macOS 호스트 감지가 cpu 프로필로 해석 · 모든 스크립트가 `--help` 에 0 으로 응답 |

### `images.yml` — 느린 티어 (키트의 이미지 파이프라인)

트리거: `docker/**` · `scripts/util_apt_helper.sh` · `scripts/util_cuda_apt.sh` · `dependencies/apt.txt` · `dependencies/apt_ros.txt` ·
워크플로 자신 · 매주 월요일 03:00 UTC · 수동. 파생 프로젝트의 의존성(`src/pyproject.toml`, `.repos`)은 여기서 보지 않습니다 —
그것은 `project.yml` 의 몫입니다.

| 잡 | 언제 | 무엇을 증명하나 |
| :--- | :--- | :--- |
| `apt-key-paths` | push마다 | 컨테이너 안(tty 없음)에서 `setup-ros-repo` 실행 — noetic/20.04, humble/22.04, humble 스냅샷 키 — 와 CUDA 저장소 핀 |
| `apt-lists-resolve` | push마다 | Dockerfile 의 apt 목록을 뽑아 20.04 · 22.04 · 24.04 에서 후보 유무만 확인 (빌드 없이 ~30 s) |
| `image-stages` | push마다 | `base`·`build-core` 실제 빌드 — BASH_ENV 배선, 관리 인터프리터의 non-root 실행, uid/gid 충돌 해소(macOS 501:20, 이름 충돌 시 원인 명시) |
| `runtime-smoke` | cron · 수동 | 전체 ROS 이미지 → `make start` → 비-bash 프로세스에서 `import rclpy` → `mksync` 후 venv 활성·명명 → ROS venv 가 시스템 인터프리터인지 |
| `arm64-image` | cron · 수동 | QEMU 로 arm64 `base` 빌드, 아키텍처 태그와 `sif_arch` 일치 |
| `sif-artifact` | cron · 수동 | 실제 Apptainer 로 prod SIF 굽기 — sha256·provenance 사이드카, 호출 uid 의 venv 접근, `src/` 미포함, 실행 기록의 종료 코드 전파(0 과 7) |
| `prod-artifact` | cron · 수동 (dev · ros 매트릭스) | `prod-runtime` 체인 — 임의 uid 에서 venv 유지, ROS 는 시스템 인터프리터·빈 `/opt/uv`, dev 는 부트스트랩 도구 부재, 매니페스트의 템플릿 버전 |

### `project.yml` — 파생 프로젝트의 루프

트리거: `src/**` · `dependencies/**` · 워크플로 자신 · 수동. `make verify → setup → build → start → mksync → lint → test`.
키트가 아니라 **당신의 코드**를 검증하며, 포크가 자기 것으로 손볼 파일은 이것 하나입니다
([GETTING_STARTED.md](GETTING_STARTED.md#5-ci--githubworkflowsprojectyml)).

> `config/**` 변경은 런타임 잡을 트리거하지 않습니다 — 그 부류의 회귀(`LD_LIBRARY_PATH` 오염, venv 미활성,
> tty 없는 MOTD)는 호스트에서 도는 계약으로 고정돼 있어 빠른 티어가 바로 잡습니다.
> 병합 전에는 `runtime-smoke` 를 수동으로 한 번 돌리는 것을 권장합니다.

---

## 🧓 레거시 티어 (ROS 1)

ROS 1 noetic 은 2025 년 5 월에 EOL 이 되었습니다. DevKit 은 그 경로를 **유지하고 계약으로 검증**하지만
(`catkin_make`·`devel/` 오버레이·ROS 1 apt 키 경로·shared venv) 새 기능은 ROS 2 에만 추가합니다.
20.04 이전 배포판 이름(melodic·kinetic)은 베이스 이미지 매핑이 없어 어차피 빌드되지 않았으므로 제거했습니다 —
`ROS_DISTRO=noetic` 만 ROS 1 입니다.

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
