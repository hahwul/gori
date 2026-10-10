+++
title = "space 메뉴와 팔레트"
description = "키를 외우지 않고도 모든 동작을 찾는 법: 자주 쓰는 것은 space 메뉴, 나머지는 커맨드 팔레트."
weight = 5

[extra]
group = "핵심"
shot = "space-menu"
+++

gori에는 수백 가지 동작이 있지만, 그 키를 미리 외울 필요는 없습니다. 두 개의 키로 모든 동작에 닿습니다.

| 누르는 키 | 열리는 것 | 이럴 때 |
|-----------|-----------|---------|
| `Space` | **space 메뉴**: 지금 있는 패널에서 가장 자주 하는 동작, 동작마다 글자 하나 | *여기서* 무엇을 할지 대략 알 때 |
| `Ctrl-P` | **커맨드 팔레트**: 모든 동작을 이름을 입력해 찾기 | 어디에 있는지 모르거나, 드물게 쓰는 동작일 때 |

둘 다 동작 옆에 그 동작의 단축키를 보여줍니다. 열어 볼 때마다 단축키를 익히게 되므로, 쓸수록 덜 필요해집니다. `?`는 전체 키 목록인 **Help** 탭을 엽니다.

> **직접 해 보며 익히기.** `gori tutorial`(세션 안에서는 `Ctrl-P` → **Guided tour**)에 둘 다 다루는 레슨이 있습니다. 무엇을 눌러도 실제로는 아무 일도 일어나지 않는 모형 화면에서 연습합니다.

## space 메뉴 {#space-menu}

아무 목록이나 패널에서 `Space`를 누르세요. **지금 서 있는 자리**의 동작이 담긴 카드가 열립니다. History 행, 플로우 상세, Repeater 편집기, 규칙 목록마다 카드가 다릅니다.

<figure class="tui-shot">
  <img src="/images/tui/space-menu.svg" alt="History 탭 위에 열린 gori space 메뉴. VIEW, SEND, TRIAGE, COPY, SCOPE, COMMON, DANGER, WIPE 아래 행이 묶여 있고, 각 행 왼쪽에는 글자가, 일부 행 오른쪽에는 단축키가 붙은 모습" width="1206" height="520">
  <figcaption>History 행에서 누른 <kbd>Space</kbd>. 왼쪽 글자는 그 행을 실행하고, 오른쪽 키는 메뉴 없이 같은 일을 하는 단축키이며, <code>›</code>는 두 번째 카드를 엽니다.</figcaption>
</figure>

카드 읽는 법:

- **왼쪽 글자가 그 행을 실행합니다.** `y`를 누르면 플로우가 복사되고 메뉴가 닫힙니다.
- **오른쪽 키는 그 행의 단축키입니다.** `r Repeater flow ^R`은 목록에서 메뉴 없이 `Ctrl-R`만 눌러도 Repeater로 보낸다는 뜻입니다. 단축키가 없는 행은 메뉴(또는 팔레트)로 닿습니다.
- **`›`가 붙은 행은 실행하지 않고 두 번째 카드를 엽니다.** [두 번째 카드](#cards)를 보세요.
- **행은 용도별로 묶입니다.** VIEW, SEND, TRIAGE, COPY 등입니다. 삭제는 DANGER, 탭 전체 지우기는 WIPE 아래 늘 맨 끝에 있고, 지우기는 실행 전에 확인을 받습니다.

### 메뉴 안에서 움직이기 {#menu-keys}

| 키 | 동작 |
|-----|------|
| 행의 글자 | 그 행 실행 |
| `↑` / `↓` 또는 `j` / `k` | 선택 이동 |
| `←` / `→` 또는 `h` / `l` | 열 바꾸기 |
| `↵` | 선택한 행 실행 |
| `Esc` | 메뉴 닫기, 두 번째 카드에서는 한 단계 뒤로 |

`h`, `j`, `k`, `l`은 어떤 행의 글자로도 쓰이지 않으므로 언제나 이동만 하고, 습관처럼 누른 `j`가 무언가를 실행하는 일은 없습니다. 카드에 없는 키를 누르면 카드가 닫힙니다.

## 두 번째 카드 {#cards}

어떤 선택은 한 가지 의도의 변형입니다. *이 플로우를 어떤 도구로 보내기*, *이 패널을 그리는 방식 바꾸기* 같은 것들입니다. 이런 것은 메뉴에서 `›` 행 하나로 묶이고, 그 행이 자기 카드를 엽니다. 그래서 첫 카드가 짧게 유지됩니다.

<figure class="tui-shot">
  <img src="/images/tui/space-menu-send.svg" alt="SPACE › SEND FLOW TO 제목의 gori Send flow to 카드. Repeater, Fuzzer, Comparer, Miner, Sequencer, Authorize, Discover, 브라우저가 각각 글자 하나에 놓인 모습" width="1206" height="520" loading="lazy" decoding="async">
  <figcaption>History 행에서 누른 <kbd>Space</kbd> <kbd>&gt;</kbd>. 제목이 지금 위치를 알려 주고, <kbd>Esc</kbd>는 첫 카드로 돌아갑니다.</figcaption>
</figure>

| 행 | 담긴 것 | 있는 곳 |
|-----|---------|---------|
| `>` **Send flow to…** | 선택한 플로우를 다른 도구로 넘기기: `r` Repeater, `f` Fuzzer, `c` Comparer, `m` Miner, `s` Sequencer, `a` Authorize, `D` Discover, `b` 응답을 브라우저로 열기 | 플로우를 고를 수 있는 탭: History, 플로우 상세, Sitemap, Repeater, Fuzzer 결과, … |
| `Z` **Display…** | 패널을 그리는 방식의 토글: hex, pretty, diff, follow, 열, 접기, … | 목록과 요청/응답 패널 |
| `P` **Protocol…** | 요청이 보내는 방식: HTTP/2, SNI, 자동 Content-Length, gRPC, TLS 지문 | Repeater, Fuzzer |
| `T` **Sub-tabs…** | 서브탭 새로 만들기, 닫기, 복제, 이름 바꾸기, 표시, 찾기 | 서브탭 스트립이 있는 아홉 탭(Repeater, Fuzzer, Notes, …)의 패널 |

빠르게 쓰는 요령 세 가지:

- **어느 탭에서나 같은 글자.** 카드 안에서 도구나 토글은 카드가 나타나는 곳 어디서든 같은 글자를 씁니다. `Space` `>` `c`는 History, Sitemap, Repeater 탭 어디서든 Comparer로 보냅니다.
- **`>`, `⇧Z`, `⇧P`는 `Space` 없이 바로 카드를 엽니다.** `>` `f`는 선택한 플로우를 Fuzzer로 보냅니다.
- **Display…와 Protocol…는 열린 채로 남습니다.** 토글을 바꾸면 카드가 같은 행에서 다시 나타나므로 한 번에 두세 개를 바꿀 수 있고, 각 행은 상태를 보여줍니다. `●`는 켜짐, `○`는 꺼짐, 또는 TLS 프리셋 이름 같은 값입니다. `Esc`로 닫습니다.

서브탭 스트립이 있는 탭에서 스트립 자체(또는 탭 바)에 포커스를 두고 `Space`를 누르면 서브탭 동작이 `T` 없이 바로 나옵니다. `Ctrl-N`과 `Ctrl-W`(서브탭 새로 만들기, 닫기)는 어느 패널에서나 동작합니다.

## 짐작할 수 있는 글자 {#letters}

여러 탭에 나오는 동작은 **모든 탭에서 같은 글자**를 씁니다. 한 탭에서 익힌 글자가 다음 탭에서도 통합니다. 먼저 알아 두면 좋은 것들:

| 글자 | 동작 |
|------|------|
| `/` | 이 목록 필터 |
| `y` · `Y` | 복사 · 다른 형식으로 복사 |
| `t` · `T` | 표시 · 모두 표시 |
| `a` · `e` | 추가(대부분의 탭에서 이슈 등록) · 편집 |
| `d` | 선택한 행 삭제 |
| `r` | Repeater로 보내기, 또는 실행(`Ctrl-R`의 메뉴 짝) |
| `E` | 내보내기 |
| `L` | 이슈나 노트에 연결 |
| `X` | 탭 지우기(먼저 확인) |

전체 표와 그 이유는 [Hotkeys → 의도 하나에 글자 하나](/ko/guide/hotkeys/#one-intent-one-letter)에 있습니다.

`Space`를 빠뜨려도 놀랄 일은 거의 없습니다. gori는 시작할 때 메뉴 글자가 같은 패널에서 맨 키로 다른 동작을 뜻하지 않는지 검사하고(문서로 남긴 몇 가지 예외만 있습니다), 그 글자를 직접 쓰지 않는 탭에서는 `c`(캡처)와 `i`(인터셉트)를 메뉴 글자로 쓰지 않습니다.

## 커맨드 팔레트 {#palette}

어느 탭에서든 `Ctrl-P`를 누르고 원하는 동작의 이름을 입력하기 시작하세요.

<figure class="tui-shot">
  <img src="/images/tui/command-palette.svg" alt="History 탭 위에서 send를 입력한 gori 커맨드 팔레트. THIS TAB 아래 Send to Comparer, Send to Fuzzer, Send to Sequencer, Send to Authorize가 오른쪽에 키나 메뉴 경로와 함께 나오고, 이어서 APP 아래 일치하는 앱 명령이 나오는 화면" width="1206" height="520" loading="lazy" decoding="async">
  <figcaption>History에서 <kbd>Ctrl-P</kbd> 후 <code>send</code> 입력. 그 탭의 동작이 먼저, 각각 닿는 키나 메뉴 경로와 함께 나오고, 앱 전역 명령이 뒤따릅니다.</figcaption>
</figure>

- **아무것도 입력하지 않으면** 앱 전역 명령이 나옵니다. 설정, **Open browser**, 탭으로 **Go to**, **Guided tour** 같은 것들입니다.
- **입력을 시작하면** 팔레트를 연 패널의 동작도 함께 찾습니다. 그 결과가 `THIS TAB` 아래 먼저 나오고, 앱 전역 결과는 `APP` 아래 이어집니다.
- **오른쪽 열은 다음번의 지름길을 알려 줍니다.** `shift-i`는 단축키이고, `␣ > c`는 메뉴 경로(`Space`, `>`, `c` 순서)입니다.
- `↑` / `↓`로 고르고, `↵`로 실행하고, `Esc`로 닫습니다. 플로우 상세 위에서 열면 상세의 동작을 찾고, `Esc`를 누르면 그 상세로 돌아갑니다.
- 표시해 둔 행이 있으면 제목이 `COMMANDS · 3 MARKED`로 바뀝니다. 고른 동작이 그 행 전부에 적용된다는 뜻입니다.

### 팔레트에만 있는 동작 {#palette-only}

space 메뉴를 짧게 유지하려고, 몇 가지 동작은 메뉴에 행이 없습니다. 이미 있는 키를 되풀이하는 것(Mark word, `Ctrl-K`)이나 가끔만 쓰는 것(**Minimize request**, **Go to line**)입니다. 그 동작이 속한 탭에서 `Ctrl-P`에 이름을 입력하면 `THIS TAB` 아래에 나옵니다. Help는 각 동작에 닿는 길을 알려 줍니다. 키가 있으면 그 키를, 없으면 `^P → <이름>`을 보여줍니다.

전체 목록은 [Hotkeys → 팔레트에만 있는 동작](/ko/guide/hotkeys/#palette-only)에 있습니다.

## 5분 연습 {#try-it}

플로우가 몇 개 캡처된 프로젝트가 필요합니다. [Quick Start](/ko/getting-started/quick-start/)를 따라 하면 준비됩니다.

1. `3`을 눌러 **History**로 가서 `↓`로 플로우를 고릅니다. `Space`를 누르고 카드를 읽어 보세요. `›` 행과 **Repeater flow** 옆의 `^R`을 찾습니다. `Esc`를 누릅니다.

   **확인.** 메뉴를 열지 않고도, 선택한 플로우를 Repeater로 보내는 키를 말할 수 있습니다.

2. `Space`, 이어서 `>`를 누릅니다. 카드 제목이 `SPACE › SEND FLOW TO`입니다. `Esc`를 한 번 누르면 첫 카드로 돌아가고, 한 번 더 누르면 메뉴가 닫힙니다.

3. `Space`, 이어서 `Z`를 누릅니다. **Display…** 카드가 각 토글 옆에 `●`나 `○`를 보여줍니다. `f`를 눌러 **follow**를 바꾸면 카드는 열린 채로 점만 바뀝니다. `f`를 한 번 더 눌러 되돌리고 `Esc`를 누릅니다.

   **확인.** 두 번째 카드를 쓰고, 한 단계 빠져나오고, 카드를 닫지 않고 토글을 바꿔 봤습니다.

4. `Ctrl-P`를 누르고 `send`를 입력합니다. `THIS TAB` 아래에서 오른쪽 열이 단축키인 행과 메뉴 경로인 행을 하나씩 찾아보세요. `Esc`를 누릅니다.

5. `Ctrl-P`를 누르고 `tour`를 입력한 뒤 `↵`로 가이드 투어를 실행합니다. 이미 해 봤다면 `Esc`를 누릅니다.

   **확인.** 동작을 이름으로 찾고, 그 동작에 더 빨리 닿는 길을 읽을 수 있습니다.

## 키가 아무 일도 하지 않을 때 {#troubleshooting}

- **`Space`가 공백으로 입력됐습니다.** 텍스트를 편집하는 중입니다(패널 배지가 `INS`). `Esc`로 `READ`로 돌아간 뒤 `Space`를 누르세요.
- **가이드에 나온 글자가 아무 일도 하지 않습니다.** 메뉴 글자는 지금 있는 패널의 것입니다. 메뉴를 열어 이 패널에 무엇이 있는지 보거나, `Ctrl-P`로 동작 이름을 검색하세요. [팔레트에만 있는 동작](#palette-only)일 수 있습니다.
- **단축키를 다시 지정했습니다.** 재지정은 행 오른쪽의 키를 바꿀 뿐, 행의 글자는 바꾸지 않습니다. 메뉴와 팔레트 모두 새 키를 보여줍니다.
- **vim 키셋을 골랐습니다.** 키셋은 편집기 안에서 움직이고 선택하는 키를 바꾸고, 메뉴 글자는 그대로 둡니다. [에디터 키셋](/ko/guide/hotkeys/#editor-keysets)을 보세요.

## 다음 단계 {#next-steps}

- [Hotkeys](/ko/guide/hotkeys/): 단축키 재지정과 전체 글자 표
- [Quick Start](/ko/getting-started/quick-start/): 요청을 캡처하고 다시 보내기
- [Proxy & History](/ko/guide/proxy/): History 탭의 동작들
