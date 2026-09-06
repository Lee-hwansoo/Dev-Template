# 🎭 패키지 오버레이 (Package Overlay)

본 디렉토리는 `vcstool`로 내려받은 **외부 ROS 패키지**의 설정 및 파일을 원본 수정 없이 **덮어쓰기(overlay)** 하기 위한 공간입니다.

원본 소스 레포지토리를 직접 건드리지 않고도 **빌드 순서 문제를 해결**하거나 **특정 하위 패키지를 빌드에서 제외**할 때 특히 유용합니다.

---

## ⚙️ 동작 방식

컨테이너 터미널에서 `sync_deps` 명령을 실행하면 다음 순서로 오버레이가 적용됩니다:

1. **외부 레포지토리 수신**: `vcs import`가 `dependencies/dependencies.repos`에 정의된 외부 레포지토리를 `src/thirdparty/`로 내려받습니다.
2. **오버레이 병합**: 이 디렉토리(`dependencies/overlay/`)의 항목들이 `src/thirdparty/`로 **재귀적으로 복사되어 원본 파일을 덮어씁니다** (`cp -a` 기반, 속성 보존).

> [!NOTE]
> 복사 대상 경로는 `SYNC_TARGET_DIR` 환경 변수로 관리되며 기본값은 `src/thirdparty`입니다. 자세한 의존성 관리 체계는 [`docs/DEPENDENCIES.md`](../../docs/DEPENDENCIES.md)를 참고하세요.

---

## 🚀 사용법

`dependencies/overlay/` 디렉토리 내부에 **덮어쓸 파일을 원본 패키지의 디렉토리 구조와 동일하게** 배치합니다.

```
dependencies/overlay/<repository_name>/<원본과 동일한 상대 경로>
```

### 📍 예시 1: 빌드 순서 조정 (`package.xml` 덮어쓰기)

외부 패키지의 `package.xml`에 `<depend>` 태그를 추가해 빌드 순서를 조정하려면:

1. 수정한 파일을 `dependencies/overlay/<repository_name>/package.xml` 경로에 준비합니다.
2. `sync_deps`를 실행하면 원본 `package.xml`이 오버레이 파일로 교체됩니다.

### 📍 예시 2: 특정 디렉토리 제외 (`COLCON_IGNORE` / `CATKIN_IGNORE`)

불필요한 예제나 하위 패키지를 빌드에서 제외해 빌드 시간을 단축하거나 의존성 오류를 회피하려면:

1. 빈 `COLCON_IGNORE`(또는 `CATKIN_IGNORE`) 파일을 `dependencies/overlay/<repository_name>/<target_subpackage>/COLCON_IGNORE` 경로에 생성합니다.
2. 컴파일러가 해당 디렉토리를 무시하여 그 하위 패키지의 빌드를 건너뜁니다.

> [!IMPORTANT]
> 오버레이 **최상위(root)**에 위치한 `*.md`, `CATKIN_IGNORE`, `COLCON_IGNORE` 파일은 복사에서 제외됩니다. 따라서 이 `README.md`는 워크스페이스로 유출되지 않으며, `IGNORE` 파일은 반드시 **레포지토리 하위 경로에 중첩**해야 정상 동작합니다.
