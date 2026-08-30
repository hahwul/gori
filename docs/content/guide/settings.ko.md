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
| `Ctrl-R` | 포커스한 섹션을 기본값으로 되돌리기 |
| `Esc` | 저장하지 않은 편집을 버리고 닫기 |

편집 내용은 작업 사본입니다. `↵`를 누르기 전에는 아무것도 기록되지 않고, `Esc`는 그대로 버립니다. 저장은 재시작 없이 즉시 적용됩니다.

필드 행에서의 `Ctrl-R`도 같은 규칙을 따릅니다. 해당 섹션의 기본값을 작업 사본에 되돌려 놓을 뿐이라 `↵`로 저장해야 합니다. **오프너** 행에는 되돌릴 작업 사본이 없으므로 확인을 물은 뒤 바로 기록합니다. 탭 바, 테마, 단축키를 그렇게 되돌릴 수 있습니다. **Env**와 **호스트네임 오버라이드**는 설정이 아니라 직접 입력한 항목이라, 그곳의 `Ctrl-R`은 조용히 비우는 대신 그렇다고 알려 줍니다. 그 둘을 지우는 것은 아래의 공장 초기화이며, 초기화는 먼저 경고합니다.

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
| **Reset** | 액션: 모든 설정을 공장 기본값으로 되돌리기 |

알림은 Miner, Fuzzer, Probe, Discover의 백그라운드 결과에서 발생합니다. [Statusline](/ko/reference/config/#statusline)은 셸 명령을 일정 간격으로 실행해 그 stdout를 맨 아래 줄에 표시합니다.

**Reset**은 한 섹션이 아니라 파일 전체입니다. `↵`(또는 `Ctrl-P` → **Settings: Reset**)로 확인을 거치면 `settings.json`이 갓 설치한 상태로 돌아가고, 테마·키맵·탭 바·목록과 미리보기 설정·프록시 바인드까지 즉시 반영됩니다. 같은 파일에 들어 있는 데이터도 함께 사라집니다. 전역 env 값, 호스트네임 오버라이드, OAST 프로바이더 토큰, 저장한 디코더 체인, 전역 Rewriter·Colormarker 규칙이 그렇습니다. 프로젝트와 캡처, 그리고 프로젝트가 고정한 바인드와 env는 그대로 남습니다.

의도적으로 하나만 남습니다. 전역 규칙 id 카운터입니다. 프로젝트는 전역 Rewriter·Colormarker 규칙을 id로 오버라이드할 수 있고, 그 오버라이드는 설정 초기화가 열지 않는 프로젝트 DB에 남습니다. 카운터를 1로 되돌리면 새로 만든 규칙이 옛 오버라이드가 가리키던 id를 받게 되므로, 카운터는 계속 올라가고 `settings.json`에는 규칙 없는 블록만 그 숫자를 기억하려고 남습니다.

### Appearance {#appearance}

| 섹션 | 필드 |
|------|------|
| **Theme** | 오프너: 테마 선택기(내장 테마와 직접 만든 테마) |
| **Display** | Default detail pane, History list time, Line numbers, Wrap long lines, Preview body limit (KiB), Resource meter, Terminal title |
| **Layout** | History Req/Res preview, Probe issue preview, Issues preview, History list order, Sitemap expand depth |
| **Companion** | Companion (Miss Ring), Placement, Motion, Notices |

Theme 행은 현재 테마를 인라인으로 미리 보여줍니다. 이름과 팔레트 스와치가 함께 표시됩니다. [테마 가이드](/ko/guide/themes/)를 참고하세요.

Companion은 기본값이 off입니다. 켜면 금빛 고리 마스코트 Miss Ring이 처음 나타나는 프레임에서 인사를 건네고, 이후 스스로 눈을 깜빡이고 윙크하며 백그라운드 작업 결과에 반응하다가, 90초간 아무 입력이 없으면 잠들어 애니메이션을 완전히 멈춥니다. 25초에 한 번쯤은 일곱 가지 idle 제스처 중 하나를 무작위로 꺼내기도 합니다 — 하품, 미소, 실눈, 뚱한 표정, 알겠다는 듯 바뀌는 궁금한 표정, 눈을 깜빡여 털어 내는 작은 콧방귀, 그리고 눈을 가늘게 뜬 "흠". 이 표정들은 눈만큼이나 눈썹이 만듭니다. 편안하게 열린 얼굴에서는 두 속눈썹이 함께 올라가고, 찌푸린 얼굴에서는 뒤집히며, 갸웃하는 얼굴에서는 한 번에 하나씩 움직입니다. 결과에 대한 반응도 표정 하나가 아니라 호를 그립니다. 결과가 도착하면 정점을 찍고 — 활짝 웃거나, 긴장하거나, 움찔하거나 — 1.5초 뒤에 그것의 조용한 버전으로 가라앉아 반응이 끝날 때까지 머뭅니다. Motion을 `calm`으로 두면 눈 깜빡임 주기가 절반이 되고 제스처는 꺼집니다. SSH나 배터리 환경용입니다. `still`은 깜빡임까지 꺼서 Miss Ring이 스스로 하는 움직임이 하나도 남지 않고, 다시 그리는 일도 없습니다 — 90초를 기다리지 않은 잠든 상태와 같은 비용이며, asciinema 녹화나 스크린 리더, 공유 tmux 팬을 위한 모드입니다. 반응은 세 모드 모두에서 그대로 남습니다. `still`은 그중 말 그대로 '움직임'인 부분, 즉 오류에 움찔하는 동작만 끄고 표정은 유지합니다. 백그라운드 작업이 도는 동안 — fuzz, discover, mine, 전송 중인 repeater — Miss Ring은 배지 칸에서 점이 위아래로 움직이는 표시를 답니다. 상태 줄의 활동 스피너와 같은 카운터로 움직이므로 둘의 박자가 어긋나지 않습니다. 이게 가장 유용한 곳은 `body` 배치입니다. 그 화면에서는 활동 칩이 보이지 않으므로, 작업이 아직 돌고 있다는 사실을 알려 주는 것은 본문 구석의 Miss Ring뿐입니다. 반응이 이 배지보다 우선하므로 작업 도중 실패는 여전히 `×`로 나타납니다. 작업이 도는 동안에는 잠들지 않으며, 에이전트가 MCP로 시작한 작업도 Miss Ring을 깨웁니다. 세션에서 Miss Ring이 먼저 꺼내는 말은 이 인사뿐이고, gori 실행당 한 번만 나옵니다. Notices를 끄면 아무 말도 하지 않습니다.

프로젝트 선택 화면에도 Miss Ring이 서 있습니다. 카드 옆 우하단 구석이며, 인사도 이제 이 화면에서 나옵니다. 인사는 gori 실행당 한 번, 처음 나타난 화면에서만 나옵니다. 릴리스당 한 번 뜨는 **update available** 알림도 Miss Ring 몫입니다. 먼저 인사를 건네고, 한 박자 뒤에 새 버전이 나왔다는 사실과 설치 방법을 알려줍니다. 말하는 방식은 세션과 같습니다. 머리 위 말풍선이 뜨고, 말하는 몇 초 동안 카드 오른쪽 가장자리 위로 떠 있습니다. 카드 옆에 앉힐 수 없을 만큼 좁은 터미널에서는 아예 나타나지 않으며, 알림도 Companion이 꺼져 있을 때와 똑같이 가운데 정렬된 한 줄로 돌아갑니다.

독립 실행 화면 두 곳에도 Miss Ring이 나옵니다. **설정 마법사**에는 COMPANION 단계가 있습니다. 켜기/끄기 선택과 모션 옆에 정지 이미지가 놓이므로, 처음 실행하는 사용자가 Miss Ring을 만나기 전에 원하는지 먼저 정할 수 있습니다. 마칠 때까지 아무것도 기록되지 않으므로 Esc로 빠져나가면 설정은 원래대로 남습니다. **가이드 투어**(`gori tutorial`)는 Miss Ring이 안내에 실제로 참여하는 유일한 곳입니다. 카드 오른쪽에 서서 탭 전환, 팔레트 열기, 액션 메뉴, INS 모드를 각각 한 번씩 해낼 때마다 확인해 주고, 마지막에 인사하고 물러납니다. 좁은 터미널에서 Miss Ring을 떨어뜨리는 대신 투어가 자기 카드를 좁혀 자리를 내주므로 80칸부터 함께합니다. Companion이 꺼져 있으면 카드는 원래 폭을 유지하고 투어도 예전과 똑같이 그려집니다. 수업 내용 자체는 카드에 있고 Miss Ring은 반응만 하므로, Notices를 꺼도 잃는 것은 그 격려뿐이고 투어 내용은 그대로입니다.

Placement는 *세션에서의* 비용을 결정합니다 (선택 화면에는 자리가 하나뿐입니다). `body`는 탭 본문 우하단에 8&times;3 스프라이트를 두며, 세 줄을 가리고 결과를 말풍선으로 알립니다. `bar`는 상태 줄 맨 오른쪽, 시계보다 더 바깥에 여덟 칸짜리 칩을 둡니다 — 고리의 위아래를 뺀 얼굴과 기분 배지가 들어갑니다. 아무것도 가리지 않고 말풍선도 사라집니다. 대사가 상태 줄의 텍스트 슬롯을 통해 나가기 때문입니다. 반응을 칩에서 읽을 수 있게 해 주는 것이 이 배지입니다. 배지가 없으면 칩은 "뭔가 잘못됐다"를 금색이 조금 붉어지는 것만으로 말하게 되는데, 색이 바랜 터미널에서 가장 먼저 사라지는 신호가 그것입니다. 이렇게 가장자리에 앉을 수 있는 건 어떤 표정에서도 폭이 같기 때문입니다. 눈을 깜빡여도 시계나 CPU/MEM 표시가 밀리지 않습니다. 그 슬롯은 메시지를 하나만 담으므로, 토스트와 Miss Ring의 알림은 더 최신인 쪽이 이깁니다. Notices는 어느 쪽이든 하단 상태바 토스트와 독립적으로 동작합니다.

### Editor & Keys {#editor-keys}

| 섹션 | 필드 |
|------|------|
| **Editor** | External editor, Markdown highlight, Mouse, Pretty-print bodies |
| **Keys** | Command modifier |
| **Env** | 오프너: 아웃바운드 요청에 쓰는 전역 `$KEY` 변수 |
| **Hotkeys** | 오프너: 단축키 재지정, OS 기본 프로파일 선택 |

**External editor**는 편집 가능한 필드에서 `^E`가 여는 프로그램입니다. 비워 두면 `$VISUAL` / `$EDITOR` / `vi` 순으로 넘어갑니다. **Mouse**를 끄면 터미널 고유의 텍스트 선택이 돌아옵니다.

**Keys**와 **Hotkeys**는 한 쌍입니다. Keys는 gori 내장 키 조합 패밀리(`^P` `^N` `^W` `^1-9`)를 *어떤 모디파이어로* 열지 고르고(`Option (⌥)`은 Ctrl을 포기하지 않고 `⌥` 별칭을 추가 — Ctrl 형태가 전달되지 않는 터미널에 유용), Hotkeys는 *개별 동작*을 재지정합니다. [커맨드 모디파이어](/ko/guide/hotkeys/#command-modifier), [단축키](/ko/guide/hotkeys/), [환경 변수](/ko/guide/repeater-and-fuzzer/#environment-variables)를 참고하세요.

### Network & Tabs {#network-tabs}

| 섹션 | 필드 |
|------|------|
| **Network** | Bind IP, Bind Port, Upstream proxy, Verify upstream TLS, Info page and CA download, Connect timeout (s), Idle timeout (s), Capture body limit (MiB), HTTP/2, Strip HTTP/3 Alt-Svc, TLS passthrough, Upstream rules(읽기 전용), Outbound TLS(읽기 전용), Hostname overrides(오프너) |
| **Tabs** | 오프너: 상단 탭 바 표시/숨김과 순서 변경 |

여기의 Network는 **전역 기본값**입니다. 프로젝트는 **Project** 탭에서 자체 바인드 주소, 포트, 업스트림을 고정할 수 있고 그 프로젝트에서는 그쪽이 우선합니다. 전체 우선순위는 [설정](/ko/getting-started/configuration/#network)을 참고하세요.

## 프로젝트 선택기에서 {#in-the-project-picker}

`Ctrl-,`는 프로젝트를 열기 전, 프로젝트 선택기에서도 같은 모달을 엽니다. 첫 실행에서 테마를 정할 수 있습니다. 다만 그곳에서 편집할 수 있는 것은 **Theme**뿐입니다. 실행 중인 프로젝트가 필요한 섹션(Tabs, Env, Hotkeys, 호스트네임 오버라이드)은 숨겨지거나 프로젝트를 먼저 열라고 안내합니다. **Reset**도 마찬가지입니다. 공장 초기화는 실행 중인 세션에 적용되어야 하기 때문입니다.

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
