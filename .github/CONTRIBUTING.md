# 기여 가이드

DevKit은 **골격**입니다. 여기 올라오는 변경은 이 키트를 쓰는 *모든* 프로젝트가 같게
원하는 것이어야 하고, 프로젝트마다 다른 선택은 파생 프로젝트가 소유합니다.

규약의 세부는 문서에 흩어져 있지 않고 각각 주인이 있습니다:

| 알고 싶은 것 | 문서 |
| --- | --- |
| 워크플로·품질 루프·셸 환경·버전 | [docs/DEVELOPMENT.md](../docs/DEVELOPMENT.md) |
| 의존성 세 레이어 (Python·C++/ROS·APT) | [docs/DEPENDENCIES.md](../docs/DEPENDENCIES.md) |
| 배포·재현성·보안 제약 | [docs/DEPLOY.md](../docs/DEPLOY.md) |
| 진단 명령 | [docs/DIAGNOSTICS.md](../docs/DIAGNOSTICS.md) |
| 어떤 파일이 어떤 규칙의 주인인가 | [docs/DEVELOPMENT.md 공유 라이브러리 표](../docs/DEVELOPMENT.md#-공유-라이브러리--규칙이-한-번만-정의되는-곳) |
| 파생 프로젝트 쪽에서 무엇을 소유하는가 | [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) |

## 시작하기

```bash
make setup                  # .env · X11 · 탭 자동완성
make verify                 # 계약 전체를 실행으로 검증 — docker 도 .env 도 필요 없음
make build && make start    # 실물이 필요할 때만
```

## 변경할 때

1. **규칙의 주인을 먼저 찾으세요.** 같은 규칙의 두 번째 사본을 만드는 것이 이 저장소에서
   가장 흔한 실수였습니다 — 색상 판정, `.env` 읽기, SIF 런타임 해석이 모두 그랬습니다.
2. **커밋은 Conventional Commits** (`type(scope): subject`, 제목 한 줄). 히스토리가 곧 변경 기록이므로
   (별도 파일 없음) 제목이 무엇이 왜 바뀌었는지 말해야 하고, 관심사 하나에 커밋 하나입니다.

   | type | 쓰임 |
   | --- | --- |
   | `feat` / `fix` | 기능 추가 / 버그 수정 |
   | `refactor` / `perf` | 동작 동일한 정리 / 성능 |
   | `docs` / `test` / `ci` / `chore` | 문서 / 계약·테스트 / 파이프라인 / 잡무 |

3. **브랜치는 `<type>/<주제>`** — type 은 위 커밋 표에서 고르고, 주제는 kebab-case 한두 단어입니다.

   | 규칙 | 이유 |
   | --- | --- |
   | `fix/detector-cache`, `ci/image-tiers`, `refactor/streamline-architecture` | 이름만 보고 무엇을 건드리는 브랜치인지 알 수 있습니다 |
   | 한 브랜치 = 한 주제 | 리뷰 단위가 곧 되돌릴 단위입니다 |
   | 여러 type 이 섞이면 **지배적인 type** | 수정 51 + 계약 15 + CI 1 = `fix/` |
   | 주제는 **한 일**이 아니라 **다룬 대상** | `fix/audit-findings`(감사에서 나온 것) 처럼 범위가 읽히는 이름 |
   | `main` 직접 커밋 금지 · 병합 후 브랜치 삭제 | 태그가 리비전을 기억하므로 병합된 브랜치는 남길 이유가 없습니다 |
   | 일부만 병합됐다면 남은 커밋을 새 `main` 위로 리베이스 | 두 히스토리를 병행하지 않습니다 |

   > 브랜치 이름을 바꾸면 GitHub 이 그 브랜치를 head 로 둔 PR 을 닫습니다. 리뷰가 시작된
   > 뒤에는 이름을 그대로 두거나, 새 PR 을 열고 닫힌 PR 을 링크하세요.

4. **주석은 핵심 1~2줄** — 코드가 이미 말하는 것을 되풀이하지 않고 "왜 이렇게 했는가"만 남깁니다.
   반대로 **사용법은 충분히**: 사용자가 직접 호출하는 함수·스크립트는 시그니처와 인자·옵션을 docstring 형식으로.

   ```bash
   # mlint [--fix]
   #   ruff (Python) and clang-format (C/C++ when installed) in check mode; --fix
   #   applies what can be applied. Same rules the editor uses on save.
   mlint() { ... }

   # 설명성 주석은 한 줄로
   # Prepend, never assign: this is written before ROS is sourced.
   ```

5. **커밋 전 `make verify`.** 실패 메시지는 어느 계약이 깨졌는지 슬러그로 알려줍니다. 템플릿 자체 문구(README·스타터·문서 지도)를 보는 검사는 `upstream_checks` 뒤에 둡니다 — 포크가 바꿔도 되는 파일에 계약을 걸지 않습니다
   (`check [env-bridge]` 등). 계약을 추가했다면 아래 절의 뮤테이션 테스트를 거칩니다.

## 출력 규약

프로그램 출력은 **영어**입니다(문서는 한국어). 화면은 한 가지 들여쓰기 규칙을 따릅니다:

| 칼럼 | 무엇 | 예 |
| --- | --- | --- |
| 0 | 헤딩 | `[ Quick Start & Build ] ====`, `[Detected Host Wiring]`, `[1/6 System]` |
| 2 | 내용 | `  [OK] ✓ …`, `  setup : …`, `  ✓ CPU: …` |
| 4 | 중첩 힌트 | `    → Run 'mksync' first.` |

- 상태 줄은 **`scripts/util_logging.sh`의 log 동사**로 냅니다(`LOG_PREFIX="[Tag]"`로 어느
  스크립트가 말하는지 밝히세요). 직접 `echo -e "\033[…"`를 쓰면 스트림별 색상 판정을
  우회하므로, 그럴 수밖에 없는 세 경우만 예외입니다 — 글리프 자체가 표시인 조밀한
  진단 스캐너(`check_hardware`·`setup_gpu`), 파일 하나만 바인드된 빌드 레이어에서 도는
  `util_apt_helper`, 그리고 검증 대상에 의존할 수 없는 `verify_repo`. 이 셋은
  `devkit_auto_color`로 출력 경계에서 색을 벗깁니다.
- **`log_detail`은 힌트**(`    → …`), `log_warn`/`log_error`/`log_debug`는 진단이라
  **stderr**로 나갑니다. `LOG_FILE`을 지정하면 이 모든 줄이 색 없이, **날짜·시각과 함께**
  파일에도 쌓입니다(`LOG_SHOW_TIME`은 콘솔 전용, `LOG_FILE=off`로 파일 기록 해제).
- **`LOG_PREFIX="[Component]"`** — 실행되는 스크립트는 자기 이름을 밝힙니다. 줄이
  `docker logs`나 make 실행 로그에서 다른 구성요소의 출력과 섞이기 때문입니다. 대괄호 안
  Title Case이고, 라이브러리는 설정하지 않습니다(호출자의 접두사를 물려받습니다).
  대화형 셸에 source되는 `config/util_aliases.sh`도 예외입니다 — 사용자가 직접 입력한
  명령이고, 최상위 대입은 그 세션의 이후 모든 줄을 오염시킵니다.
- **경고·오류는 stderr**, 데이터는 stdout. `check_env.sh --makefile`이나
  `gpu opencv_args`처럼 기계가 소비하는 출력에는 메시지를 섞지 않습니다.
- 종료 코드: **0** 정상, **1** 실패, **2** 사용법 오류(알 수 없는 플래그·명령, 인수 누락).
  `--help`와 `-h`는 항상 0으로 끝나야 합니다 — check [cli-convention]이 실행으로 검사합니다.
- 색상은 `NO_COLOR`와 비-TTY에서 자동으로 꺼집니다. 스크립트가 raw 이스케이프를 직접 찍는다면
  `devkit_auto_color`를 한 번 호출하세요.

## 계약을 추가할 때

`scripts/verify_repo.sh`의 검사는 **과거에 실제로 깨진 것**을 고정합니다. 문자열이 존재하는지가
아니라 **동작**을 확인하고, 슬러그(`[my-check]`)를 달아 문서가 인용할 수 있게 합니다.

새 계약은 **뮤테이션 테스트**를 통과해야 합니다 — 지키려는 코드를 일부러 깨뜨렸을 때 그 검사가
실패하는지 확인하세요. 이 저장소의 검사는 전부 그렇게 도입되었고, 자기 설명 주석에 만족해
버리는 검사를 두 번 잡아냈습니다.

그리고 **예산이 있습니다**: 스위트는 5200 줄 · 70 그룹을 넘지 못하며, 이것도 계약입니다.
포크가 읽을 수 있어야 하므로 새 그룹은 기존 그룹을 대체하거나 천장을 의도적으로 올려야 합니다.
줄이는 방향은 정해져 있습니다 — **문자열을 고정하는 검사를 실행하는 프로브로 바꾸면**
커버리지는 올라가고 검사 수는 줄어듭니다(오늘 `status:` 존재 여부 grep 을 "데몬이 죽은 상태에서
`make status` 가 배선을 출력한다" 로 바꾼 것이 그 예입니다).

## 표면을 늘릴 때

`make` 타겟, 컨테이너 숏컷, `.env` 노브는 **광고된 표면**이며 곧 공개 API입니다. 하나 늘리면
`make help`/`h`, 탭 자동완성, 문서, 그리고 그것을 검증하는 계약까지 같이 갱신하세요 — 광고만
있고 동작하지 않는 스위치는 없는 기능보다 나쁩니다. 표면이 바뀌면 MAJOR 입니다
([버전 규약](../docs/DEVELOPMENT.md#버전-규약)).
