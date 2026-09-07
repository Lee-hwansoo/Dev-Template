# 🚀 DevKit 배포 가이드 (SIF · 소스 보호 · 재현성 · 보안)

개발 컨테이너를 떠나 **배포되는 산출물**에 관한 문서입니다. 원격 클러스터 운영
절차는 [SLURM.md](SLURM.md), 일상 워크플로우는 [DEVELOPMENT.md](DEVELOPMENT.md)를 보세요.

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
| **`SHARE=1`** | *(없음)* | `bake-dev` 전용. 비-ROS 스냅샷에도 `--system-site-packages` venv 를 만듭니다 (ROS 이미지는 어차피 자동 share) |
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
| 외부 소스 저장소 | `dependencies.repos`의 `version:`에 **전체 커밋 해시** 지정 | ✅ prod bake 기본 정책 (`DEVKIT_REQUIRE_PINNED=0`으로 해제 가능) |
| 빌드 산출물 자체 포함성 | prod 빌더는 `--symlink-install` 미사용 (`DEVKIT_BUILD_TYPE=prod`) | ✅ 구현됨 |
| 설치 결과 감사 | `dpkg-query`/`pip freeze` 매니페스트 + SHA-256을 이미지에 동봉 | ✅ 구현됨 |
| Python 의존성 | `src/uv.lock` 커밋 + prod 는 `uv sync --locked --no-editable` | ✅ 구현됨 (lock 이 없거나 낡으면 prod 빌드 중단) |
| 베이스 이미지 | `.env`에 `BASE_IMAGE=ubuntu@sha256:<digest>` 로 다이제스트 고정 | ⚠️ 사용자 책임 (기본은 가변 태그 `ubuntu:22.04`) |
| ROS APT 패키지 | `ROS_SNAPSHOT_DATE=YYYY-MM-DD` 또는 `final` → `snapshots.ros.org` 시점 미러 고정 | ✅ 구현됨 |
| `rosdep install` | 해석 결과가 시점에 따라 달라짐 | ❌ 불가 |

**완전 재현이 필요한 경우의 권장 절차**

`DEVKIT_REQUIRE_PINNED=1` 검사는 PyYAML 이 있으면(ROS 이미지에는 vcstool 이 끌어옵니다) 블록형·플로우형 어느 YAML 이든 파싱하고, 없으면 awk 로 읽되 **읽지 못한 줄이 있으면 실패**합니다(unread ≠ pinned). 40자 전체 커밋 해시만 통과하며 태그·짧은 해시·누락된 버전은 거부합니다.

```bash
# 1) Python 의존성 잠금 — 의존성을 바꿀 때마다 갱신해 커밋
#    src/uv.lock 은 이 저장소에 커밋되어 있고 prod 빌드가 --locked 로 읽습니다.
mksync && git add src/uv.lock && git commit -m "chore: pin python dependencies"

# 2) 베이스 이미지 다이제스트 고정 (.env)
docker buildx imagetools inspect ubuntu:22.04 | grep Digest   # → sha256:...
echo 'BASE_IMAGE=ubuntu@sha256:<digest>' >> .env

# 3) APT 스냅샷 + 타임스탬프 고정 후 빌드
APT_SNAPSHOT_DATE=20260801T000000Z SOURCE_DATE_EPOCH=1785542400 make bake-prod ENV=ros
```

> [!IMPORTANT]
> **`ROS_SNAPSHOT_DATE`를 지정하지 않으면(기본 `latest`) ROS 계층은 여전히 가변입니다.**
> `ros-humble-*` 패키지 버전이 빌드 시점에 따라 달라지므로, 재현이 필요하면 `.env.example`에
> `ROS_SNAPSHOT_DATE`에 실제 게시된 날짜(또는 EOL 배포판이면 `final`)를 커밋하세요. 그래도 `rosdep install`의
> 해석 결과는 시점에 따라 달라지므로, 비트 단위 재현이 필요하면 검증된 이미지를
> **`make bake-prod`로 SIF에 봉인**해 그 아티팩트를 배포하는 편이 확실합니다.

### 고정 불가 계층의 대안 — 빌드 매니페스트 (감사 및 사후 고정)

고정할 수 없는 계층은 **무엇이 설치되었는지 기록**해 감사 가능하게 만듭니다. 모든 프로덕션 이미지의
`/etc/devkit/`에 다음이 동봉됩니다:

| 파일 | 내용 |
| :--- | :--- |
| `devkit-release.json` | `base_image`, `apt_snapshot`, `apt_snapshot_applied`, `source_date_epoch`, `build_type`, `git_commit`, 매니페스트 **SHA-256** |
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
> **스냅샷이 고정하는 범위**: `configure-snapshot` 이후에 설치되는 모든 패키지입니다. 베이스 이미지가
> 이미 담고 있는 패키지와 스냅샷을 내려받는 데 필요한 도구 자체(`curl`·`ca-certificates`·`gnupg`)는
> 롤링 미러에서 오며 — apt 는 베이스가 가진 더 새 버전을 내리지 않습니다 — **`BASE_IMAGE` 다이제스트 고정**이
> 이들을 고정하는 수단입니다. 그래서 릴리스는 두 가지를 함께 고정합니다. 실제로 설치된 버전은
> 매니페스트(`devkit-apt-manifest.txt`)에 전부 기록됩니다.

> 스냅샷 서버가 불통이면 빌드는 **중단**됩니다 — 롤링 미러로 조용히 넘어가면 재현성이 무의미해지기 때문입니다.
> 의도적으로 넘어가려면 `APT_SNAPSHOT_FALLBACK=1`을 명시하세요(`.env`·환경·`make` 인자 어디서든; 기본은 `false`).
> 넘어간 빌드는 매니페스트에 `apt_snapshot_applied: false` 로 남아 고정 빌드로 오인되지 않습니다.
> (`make verify` [reproducibility]이 기본값·전달·기록을 실행으로 검증합니다.)


---

## 🛡️ 보안 및 아키텍처 제약사항 (Security & Architecture)

0. **APT 신뢰 앵커 고정**: `packages.ros.org`의 서명키는 `scripts/util_apt_helper.sh` 최상단의
   `ROS_GPG_FINGERPRINT` 상수와 대조한 뒤에만 설치됩니다.
   - 기본값이 `true` 입니다 → 지문 불일치 시 **빌드 중단**
   - 명시적으로 `STRICT_GPG_CHECK=false` 로 둘 때만 경고 후 진행
   - 업스트림이 키를 교체하면 호스트에서 **`make update-gpg`** 를 실행하세요. 이 명령이 상수를 갱신합니다.
1. **동적 권한 매핑**: 호스트 UID/GID를 컨테이너의 non-root 개발자 계정에 매핑합니다.
2. **`privileged`는 기본 `false`**: USB 센서·카메라·SocketCAN이 필요할 때만 `.env`에서 켜세요
   (특권 컨테이너는 탈출이 사실상 자유롭습니다). check [security-defaults]가 기본값을 지킵니다.
3. **`network_mode: host` / `ipc: host`**: DDS 성능을 위한 의도적 선택입니다. 호스트 네트워크를
   공유하니 `.env`에 고유한 `ROS_DOMAIN_ID`를 두고, 필요하면 `NETWORK_MODE`/`IPC_MODE`로 좁히세요.
4. **프로덕션 런타임은 non-root uid**: 배포 이미지는 `USER`로 uid를 낮춰 실행하며
   `install/`·`/etc/devkit`을 읽기만 합니다(k8s `runAsNonRoot` 호환). Apptainer는 `USER`를
   무시하고 **호출한 사용자**로 돌므로, `ENV=dev` 의 순수 venv 가 쓰는 인터프리터는 임의 uid가 읽을 수
   있는 `/opt/uv/python`에 둡니다. `ENV=ros` 의 venv 는 시스템 인터프리터를 공유하므로 그 트리를 비워
   싣지 않습니다. check [sif-contract]가 두 조건을 모두 검사합니다.
5. **런타임에는 apt 부트스트랩 도구가 없습니다**: `base` 가 저장소 설정에 쓴 curl·gnupg·lsb-release 는
   `purge-bootstrap` 이 제거합니다 — 설치된 패키지가 여전히 의존하는 것(예: `ros-*-libcurl-vendor` → curl)만
   남깁니다. 배포물은 키를 받아올 일도, 저장소를 더할 일도 없습니다.
