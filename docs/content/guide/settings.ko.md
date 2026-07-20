+++
title = "설정"
description = "Preferences 모달: gori의 모든 설정을 한곳에서, 어디서나."
weight = 90

[extra]
group = "커스터마이즈"
+++

gori에 저장되는 모든 환경설정은 하나의 화면, **Preferences** 모달에서 편집합니다. 앱 안에서든 프로젝트 선택기에서든 같은 모달이므로 익힐 곳은 한 군데뿐입니다.

## Preferences 열기 {#opening-preferences}

| 여는 방법 | 도착 지점 |
|-----------|-----------|
| 어디서나 `Ctrl-,` | 그룹 스트립. 그룹을 먼저 고릅니다 |
| 상단 바의 `⚙` 칩 | `Ctrl-,`와 동일 |
| `Ctrl-P` → **Settings: …** 항목 | 해당 섹션의 필드로 바로 |

팔레트 항목과 모달의 섹션은 같은 목록에서 나오므로, 한쪽에서 닿는 것은 다른 쪽에서도 닿습니다.

## 이동하기 {#moving-around}

모달 위쪽에는 그룹 스트립(네 개 그룹)이 있고, 그 아래에 포커스된 그룹의 섹션이 놓입니다. `Ctrl-,`로 열면 스트립에서 시작하고, 팔레트로 바로 들어가면 필드에서 시작합니다.

| 키 | 동작 |
|----|------|
| `←` / `→` | 그룹 전환(스트립에 포커스가 있을 때) |
| `↓` / `↵` | 스트립에서 필드로 내려가기 |
| `↑` / `↓` | 필드 이동. 첫 필드에서 `↑`는 스트립으로 돌아갑니다 |
| `↵` | 현재 섹션 저장, 또는 섹션의 편집기 열기 |
| `Ctrl-R` | 현재 섹션을 기본값으로 되돌리기(저장하려면 `↵` 필요) |
| `Esc` | 저장하지 않은 편집을 버리고 닫기 |

편집 내용은 작업 사본입니다. `↵`를 누르기 전에는 아무것도 기록되지 않고, `Esc`는 그대로 버립니다. 저장은 재시작 없이 즉시 적용됩니다.

## 필드 종류 {#field-types}

| 종류 | 편집 방법 |
|------|-----------|
| **텍스트** | 그대로 입력(바인드 주소, 에디터 명령, 스테이터스라인 명령) |
| **토글** | `Space`, `←`, `→`로 on/off 전환 |
| **선택지** | `←` / `→`로 순환 |
| **오프너** | `↵`로 해당 섹션의 전용 편집기 열기 |

오프너는 한 줄짜리 필드로는 부족한 섹션에 쓰입니다. 테마 목록, 탭 바, 환경 변수, 단축키, 호스트네임 오버라이드가 여기에 해당합니다.

## 섹션 {#the-sections}

### General {#general}

| 섹션 | 필드 |
|------|------|
| **General** | Clipboard (OSC 52), Confirm before quit |
| **Notifications** | Bell on result, Toast on result, Retention (count) |
| **Statusline** | Statusline on/off, Command, Interval (s) |

알림은 Miner, Fuzzer, Probe, Discover의 백그라운드 결과에서 발생합니다. [Statusline](/ko/reference/config/#statusline)은 셸 명령을 일정 간격으로 실행해 그 stdout를 맨 아래 줄에 표시합니다.

### Appearance {#appearance}

| 섹션 | 필드 |
|------|------|
| **Theme** | 오프너: 테마 선택기(내장 테마와 직접 만든 테마) |
| **Display** | Default detail pane, History list time, Line numbers, Preview body limit (KiB), Resource meter, Terminal title |
| **Layout** | History Req/Res preview, Probe issue preview, Issues preview, History list order, Sitemap expand depth |

Theme 행은 현재 테마를 인라인으로 미리 보여줍니다. 이름과 팔레트 스와치가 함께 표시됩니다. [테마 가이드](/ko/guide/themes/)를 참고하세요.

### Editor & Keys {#editor-keys}

| 섹션 | 필드 |
|------|------|
| **Editor** | External editor, Markdown highlight, Mouse, Pretty-print bodies |
| **Env** | 오프너: 아웃바운드 요청에 쓰는 전역 `$KEY` 변수 |
| **Hotkeys** | 오프너: 단축키 재지정, OS 기본 프로파일 선택 |

**External editor**는 편집 가능한 필드에서 `^E`가 여는 프로그램입니다. 비워 두면 `$VISUAL` / `$EDITOR` / `vi` 순으로 넘어갑니다. **Mouse**를 끄면 터미널 고유의 텍스트 선택이 돌아옵니다. [단축키](/ko/guide/hotkeys/)와 [환경 변수](/ko/guide/repeater-and-fuzzer/#environment-variables)를 참고하세요.

### Network & Tabs {#network-tabs}

| 섹션 | 필드 |
|------|------|
| **Network** | Bind IP, Bind Port, Upstream proxy, Verify upstream TLS, Info page on direct access, Connect timeout (s), Idle timeout (s), Capture body limit (MiB), Hostname overrides(오프너) |
| **Tabs** | 오프너: 상단 탭 바 표시/숨김과 순서 변경 |

여기의 Network는 **전역 기본값**입니다. 프로젝트는 **Project** 탭에서 자체 바인드 주소, 포트, 업스트림을 고정할 수 있고 그 프로젝트에서는 그쪽이 우선합니다. 전체 우선순위는 [설정](/ko/getting-started/configuration/#network)을 참고하세요.

## 프로젝트 선택기에서 {#in-the-project-picker}

`Ctrl-,`는 프로젝트를 열기 전, 프로젝트 선택기에서도 같은 모달을 엽니다. 첫 실행에서 테마를 정할 수 있습니다. 다만 그곳에서 편집할 수 있는 것은 **Theme**뿐입니다. 실행 중인 프로젝트가 필요한 섹션(Tabs, Env, Hotkeys, 호스트네임 오버라이드)은 숨겨지거나 프로젝트를 먼저 열라고 안내합니다.

## 설정이 저장되는 곳 {#where-settings-live}

여기서 저장한 내용은 모두 gori 홈 디렉터리의 `settings.json`에 기록됩니다. 경로를 출력하거나 바로 열려면:

```bash
gori settings          # print the settings.json path
gori settings --edit   # open it in your editor
```

프로젝트별 재정의는 이 파일에 없습니다. 프로젝트 데이터베이스에 저장되며 **Project** 탭에서 편집합니다.

## 다음 단계 {#next-steps}

- [설정](/ko/getting-started/configuration/): 저장소 레이아웃, 네트워크 우선순위, 루트 CA
- [설정 레퍼런스](/ko/reference/config/): `settings.json`의 모든 키
- [테마](/ko/guide/themes/): 컬러 테마 전환하거나 직접 만들기
- [단축키](/ko/guide/hotkeys/): 단축키 재지정과 키 예산 규칙
