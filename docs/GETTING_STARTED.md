# 🧭 템플릿에서 프로젝트 시작하기 (Getting Started)

DevKit 을 복제해 **내 프로젝트**로 만드는 순서입니다. 키트가 소유하는 것과 파생 프로젝트가
소유하는 것을 먼저 가르고, 손볼 파일을 그 순서대로 짚습니다. 일상 명령은
[DEVELOPMENT.md](DEVELOPMENT.md), 의존성은 [DEPENDENCIES.md](DEPENDENCIES.md) 에 있습니다.

---

## 누가 무엇을 소유하나

| 파생 프로젝트가 소유 (마음껏 고침) | 키트가 소유 (상류에서 갱신, 계약이 지킴) |
| :--- | :--- |
| `src/` — 코드, `pyproject.toml`, `uv.lock` | `Makefile`, `docker/`, `docker-compose*.yml` |
| `dependencies/` — `apt*.txt`, `dependencies.repos`, `overlay/` | `config/`, `scripts/` |
| `.env`(로컬) · `.env.example`(팀 공유 기본값) | `scripts/verify_repo.sh` 의 계약 |
| `.github/workflows/project.yml` | `.github/workflows/verify.yml`, `images.yml` |
| `README.md`, `LICENSE` | `docs/` (지우거나 두거나 — 키트 사용법) |
| | `VERSION` — 이 프로젝트가 출발한 템플릿 리비전 |

상류 갱신은 오른쪽 열만 골라 가져옵니다 — 절차는
[DEVELOPMENT.md 의 템플릿 수명주기](DEVELOPMENT.md#-템플릿-버전과-상류-갱신-가져오기-template-lifecycle).

---

## 체크리스트

### 1. 정체성 — `make adopt`

```bash
make adopt NAME=my-robot DESC='One line about it'
```

`src/pyproject.toml` 의 `[project] name`/`description` 과 `.env`·`.env.example` 의
`COMPOSE_PROJECT_NAME` 을 한 번에 고칩니다. 이름은 compose 와 PEP 508 이 함께 받는
`[a-z0-9][a-z0-9_-]*` 여야 하고, 작업 트리가 깨끗할 때만 실행됩니다 — 결과는 `git diff` 로 검토하세요.
`README.md` 와 `LICENSE` 는 adopt 가 건드리지 않습니다. 이 README 는 DevKit 을 설명하므로 프로젝트의
것으로 바꾸고, `LICENSE`(MIT-0) 는 지우거나 프로젝트 라이선스로 덮어써도 됩니다.

### 2. 팀 공유 기본값 — `.env.example`

`.env.example` 은 커밋되는 **팀의 답**이고 `.env` 는 로컬 오버라이드입니다(`make setup` 이 복사).
프로젝트가 결정해야 하는 항목:

| 항목 | 결정 |
| :--- | :--- |
| `ROS_DISTRO` | 배포판 하나 — ROS 2 는 `humble`·`iron`·`jazzy`·`kilted`·`rolling`, ROS 1 은 `noetic`(레거시 티어: 지원·검증되나 새 기능 없음). Ubuntu 릴리스와 Python 이 따라옵니다. ROS 를 쓰지 않으면 그대로 두고 `ENV=dev` 만 사용 |
| `UV_EXTRA` | `pyproject.toml` 에 extras 를 선언한 뒤 팀이 기본으로 쓸 것(예: `gpu`). 선언 전에는 비워 둡니다 |
| `ROS_DOMAIN_ID` | 같은 네트워크의 다른 팀과 겹치지 않는 값 |
| `DEVKIT_SLURM_*`, `SLURM_DATA_ROOT` … | 클러스터를 쓴다면 사이트 값 ([SLURM.md](SLURM.md)) |
| `APT_SNAPSHOT_DATE`, `ROS_SNAPSHOT_DATE`, `BASE_IMAGE` 다이제스트 | 릴리스 브랜치에서 고정 ([DEPLOY.md 재현성](DEPLOY.md#-재현성-reproducibility--현재-보장-범위)) |

### 3. 의존성 세 레이어

| 레이어 | 파일 | 할 일 |
| :--- | :--- | :--- |
| Python | `src/pyproject.toml` | `dependencies` 에 패키지 추가. PyTorch cpu/gpu 분기가 필요하면 파일 안의 **주석 예시**를 풀어 씁니다 |
| 시스템·ROS apt | `dependencies/apt.txt`, `apt_ros.txt` | 한 줄에 패키지 하나. 배포물에 필요하면 `# runtime`, GUI 도구는 `# gui`. `make term` 을 쓰려면 `terminator # gui` 주석 해제 |
| 외부 소스 | `dependencies/dependencies.repos` | vcstool 형식. 릴리스는 **40자 커밋 해시**로 고정 |

태그 규칙과 필터 결과는 [DEPENDENCIES.md](DEPENDENCIES.md) 에 있습니다.

### 4. 첫 빌드와 lock 커밋

```bash
make setup && make build && make start && make shell   # 호스트
mksync                                                  # 컨테이너 — venv + 의존성 + 빌드
```

`mksync` 가 `src/uv.lock` 을 갱신합니다. **lock 은 커밋합니다** — 프로덕션 빌드가 `uv sync --locked`
로 돌기 때문에, lock 이 없거나 `pyproject.toml` 보다 낡으면 `make bake-prod` 가 멈춥니다.

```bash
git add src/uv.lock && git commit -m "chore: pin python dependencies"
```

### 5. CI — `.github/workflows/project.yml`

이 파일만 프로젝트의 것입니다. 기본은 `ENV: dev` 로 몇 분 안에 끝나도록 되어 있으니, ROS
프로젝트라면 `ENV: ros` 로 바꾸고 `timeout-minutes` 를 올리세요. `verify.yml` 과 `images.yml`
은 키트를 검증하므로 보통 그대로 둡니다 ([DEVELOPMENT.md 의 CI 절](DEVELOPMENT.md#-ci-github-actions)).

### 6. 스타터 예제 정리

`src/example/` 은 **빌드 시스템에 등록되지 않은 독립 파일**입니다 — 실제 패키지가 프로젝트 타입
판별(`package.xml` → ROS, `CMakeLists.txt` → C++)을 결정하도록 비워 둔 것입니다. 환경이 도는지
한 번 보고 지우거나 교체하세요.

```bash
# 컨테이너 안
python3 src/example/starter_node.py                                   # ROS 2 / 순수 Python 자동 판별
mkdir -p build && g++ -std=c++17 src/example/starter_node.cpp -o build/starter_node && ./build/starter_node
mtest                                                                 # 예제의 pytest 가 돕니다
```

예제를 빌드에 넣고 싶다면 `src/` 에 `package.xml`(ROS) 또는 `CMakeLists.txt`(C++) 를 두고
`mksync`(전체) 또는 `cbuild`/`mbuild`(빌드만) 를 실행합니다.

### 7. 확인

```bash
make verify        # 키트 계약 — 포크에서도 통과해야 합니다
make test          # 프로젝트 테스트 (mtest 를 make exec 으로 경유)
make status        # 프로젝트 이름 · 템플릿 버전 · 감지된 호스트 배선
```

---

## 그 다음

- 매일 쓰는 명령과 셸 환경: [DEVELOPMENT.md](DEVELOPMENT.md)
- 배포물 만들기와 재현성: [DEPLOY.md](DEPLOY.md), 클러스터 운영: [SLURM.md](SLURM.md)
- 무언가 이상할 때: [DIAGNOSTICS.md](DIAGNOSTICS.md), 디버거: [DEBUGGING.md](DEBUGGING.md)
- 키트 자체를 고치고 싶을 때: [.github/CONTRIBUTING.md](../.github/CONTRIBUTING.md)
