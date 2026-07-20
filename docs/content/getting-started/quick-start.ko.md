+++
title = "Quick Start"
description = "직접 따라 하는 튜토리얼: CA를 신뢰하고, 실제 요청을 캡처해 살펴본 뒤 Repeater에서 재전송합니다."
weight = 20
+++

이 페이지는 처음부터 끝까지 따라 하는 튜토리얼입니다. 위에서 아래로 진행하면 갓 설치한 상태에서 시작해, 캡처한 HTTPS 요청을 살펴보고 **Repeater**로 보내 편집한 뒤 재전송하는 것까지 터미널을 벗어나지 않고 끝낼 수 있습니다. 10분 정도 잡아 두세요.

각 단계는 **확인** 항목으로 끝납니다. 다음으로 넘어가기 전에 보여야 하는 상태입니다. 화면이 다르게 보인다면 그 지점에서 멈추고 바로잡으세요.

> **시작하기 전에.** [gori를 설치](/ko/getting-started/installation/)하고 브라우저를 준비하세요. 자신의 브라우징을 캡처하게 되므로, 테스트 권한이 있는 사이트(자신의 앱, 스테이징 서버, 또는 의도적으로 취약하게 만든 연습용 타깃)를 고르세요. 정확한 결과가 필요한 부분에서는 안정적인 일회용 타깃인 `example.com`을 사용합니다.

## 1. gori 시작하기 {#1-start-gori}

하위 명령 없이 실행하면 gori는 프록시를 시작하고 인터페이스를 엽니다:

```bash
gori
```

첫 실행 시 짧은 [설정 마법사](#first-run-wizard)(전역 바인드와 테마)가 실행되고, 이어서 [가이드 UI 투어](#guided-ui-tour)를 제안합니다. 투어는 지금 해도 되고 건너뛰었다가 나중에 돌아와도 됩니다. 이 페이지는 같은 내용을 실제 트래픽으로 다룹니다.

기본적으로 프록시는 `127.0.0.1:8070`에서 수신합니다. 한 번의 실행에 대해서만 재정의할 수 있습니다(프로젝트 자체 바인드가 설정되어 있으면 여전히 그쪽이 우선합니다):

```bash
gori --listen 0.0.0.0 --port 8080
```

**확인.** gori TUI가 보입니다. 한쪽에 늘어선 탭들(Project, Target, History, …)과 프록시 주소 `127.0.0.1:8070`을 보여주는 상단 바입니다.

## 2. CA 신뢰 후 첫 플로우 캡처 {#2-trust-the-ca-and-capture-your-first-flow}

HTTPS를 읽으려면 클라이언트가 gori의 루트 인증서(첫 실행 시 `~/.gori/ca` 아래에 생성됨)를 신뢰해야 합니다. 가장 빠른 길은 사전 신뢰된 브라우저입니다.

### Option A: 사전 신뢰된 브라우저 열기 (권장) {#option-a-open-a-pre-trusted-browser-recommended}

TUI 안에서:

1. `Ctrl-P`를 눌러 **커맨드 팔레트**를 엽니다.
2. `browser`를 입력하고 **Open browser**를 실행합니다.
3. 설치된 브라우저(Chrome, Chromium, Brave, Edge, Firefox, …)를 고릅니다.

gori는 이미 CA를 신뢰하고 HTTP/HTTPS를 프록시로 경유하는 일회용 프로파일로 브라우저를 실행합니다. 그 브라우저에서 사이트를 방문하세요(`https://example.com`을 먼저, 그다음 테스트 중인 사이트를).

### Option B: 클라이언트를 직접 지정하기 {#option-b-point-any-client-yourself}

CA 경로를 출력하고 그 파일을 시스템 또는 브라우저 신뢰 저장소에 **신뢰된 루트 CA**로 가져오세요:

```bash
gori ca
```

그런 다음 클라이언트가 `127.0.0.1:8070`을 HTTP **및** HTTPS 프록시로 사용하도록 설정하세요. 다른 터미널에서 간단한 동작 확인:

```bash
curl -x http://127.0.0.1:8070 https://example.com
```

gori는 요청 시 루트로부터 호스트별 리프 인증서를 발급하므로, 루트만 한 번 신뢰하면 됩니다.

> gori의 개인 키는 머신 비밀입니다. `0600` 권한으로 기록되며 머신을 절대 벗어나지 않습니다. 이전의 모든 신뢰를 무효화할 의도가 있을 때만 팔레트(**Regenerate CA certificate**)에서 교체하세요.

**확인.** **History**로 전환하세요(`3`). 최소 한 개의 행이 보여야 합니다. `200` 상태의 `GET https://example.com/` 요청입니다. History가 비어 있다면 캡처가 gori에 도달하지 않는 것입니다. 프록시 설정(Option B)을 다시 확인하거나 **Open browser**(Option A)를 사용하세요.

## 3. 두 가지 탐색 표면 익히기 {#3-learn-the-two-discovery-surfaces}

탭별 단축키를 외우기 전에, 거의 모든 것이 있는 두 곳을 먼저 익히세요.

| 표면 | 키 | 용도 |
|---------|-----|----------------|
| **커맨드 팔레트** | `Ctrl-P` | 앱 전역 제어: 설정, Open browser, Export CA, 이동 동작 등 전역적인 모든 것 |
| **space 메뉴** | `Space` | 지금 포커스를 가진 대상에 대한 동작(History 행, 상세 패널, Repeater, …) |

팔레트는 도구 전체의 지도입니다. space 메뉴는 *이* 패널의 지도입니다. 둘 다 키 힌트를 보여주니, 코드를 잊었으면 둘 중 하나를 여세요.

<figure class="tui-shot">
  <img src="/images/tui/command-palette.svg" alt="History 탭 위에 열린 gori 커맨드 팔레트로, 필터 상자와 함께 설정, 이동, 내보내기 동작을 나열한다">
  <figcaption>커맨드 팔레트(<kbd>Ctrl-P</kbd>): 설정부터 <em>Open browser</em>, 탭 이동까지 앱 전역의 모든 동작을 퍼지 필터로 찾습니다.</figcaption>
</figure>

처음부터 알아 두면 좋은 전역 토글 세 가지입니다:

| 키 | 동작 |
|-----|--------|
| `c` | **캡처** 토글(끄면 트래픽이 저장되지 않고 그대로 통과) |
| `i` | **인터셉트** 토글(일치하는 요청을 잡아 forward / drop / edit) |
| `s` | **스코프 렌즈** 토글(뷰를 스코프 내 트래픽으로 필터) |

## 4. TUI 이동하기 {#4-move-around-the-tui}

gori는 탭의 한 줄입니다. 기본 순서는 Project → Target → **History** → Intercept → Repeater → Fuzzer → … 로 시작합니다.

| 키 | 동작 |
|-----|--------|
| `[` / `]` | 이전 / 다음 탭 |
| `1`-`9` | N번째 표시된 탭으로 이동(기본값에서 History는 `3`) |
| `Enter` / `↓` | 탭 바에서 탭 본문으로 진입 |
| `Esc` | 포커스를 탭 바 쪽으로 되돌림 |
| `Tab` / `Shift-Tab` | 탭 바와 패널 사이로 포커스 이동 |

마우스는 활성화하면(Preferences → **Editor & Keys** → **Editor**) 동작합니다. 탭 클릭, 행 클릭으로 선택, 다시 클릭으로 열기. **Help** 탭은 이 페이지가 열려 있지 않을 때 쓸 수 있는 앱 안의 완전한 키 치트시트입니다.

## 5. History에서 플로우 읽기 {#5-read-a-flow-in-history}

History가 활성화되어 있는지 확인하세요(`3`). 모든 요청/응답은 *플로우*입니다. 시작 줄, 헤더, 본문(최대 2 MiB 저장), 그리고 HTTP/2 프레임, WebSocket 메시지, 존재하면 디코드된 JWT / SAML / GraphQL까지.

<figure class="tui-shot">
  <img src="/images/tui/history.svg" alt="시간, 메서드, 프로토콜, 호스트, 경로, 상태, 유형, 크기, 소요 시간 열로 캡처된 HTTP 플로우를 나열하는 gori History 탭">
  <figcaption><strong>History</strong> 탭: 메서드, 상태, 크기, 타이밍이 담긴 모든 캡처 플로우를 쿼리 언어로 필터할 수 있습니다.</figcaption>
</figure>

다음을 하나씩 해보세요:

| 키 | 동작 |
|-----|--------|
| `↑` / `↓` (또는 `j` / `k`) | 선택 이동 |
| `Enter` | 요청/응답 상세 열기 |
| `/` | [쿼리 언어](/ko/reference/query-language/)로 필터 |
| `f` | 최신 따라가기(tail) 토글 |
| `y` | 선택한 플로우 복사 |

`/`를 누르고 필터를 입력한 뒤 `Enter`를 누르세요:

```text
host:example.com
```

History가 그 호스트로 좁혀집니다. 필터를 지우면(`/`, 지우기, `Enter`) 다시 전체가 보입니다. 나중에 시도해 볼 몇 가지:

```text
status:5xx
method:POST body:password
```

이제 `example.com` 플로우를 선택하고 `Enter`를 누르세요. 상세 화면에서는 `↑` / `↓`로 스크롤하고 `y`로 복사하며, hex / whitespace / pretty 본문은 `x` / `b` / `p`로 토글합니다. `Esc`로 목록에 돌아옵니다.

**확인.** History를 호스트 하나로 필터하고, 플로우를 열어 전체 요청과 응답을 읽을 수 있습니다.

## 6. Repeater로 보내 재전송하기 (핵심 루프) {#6-send-it-to-repeater-and-re-send-the-core-loop}

대부분의 시간을 보내게 될 루프입니다. 캡처한 요청을 가져와 무언가를 바꾸고, 다시 보내고, 비교합니다.

1. **History**에서 `example.com` 플로우를 선택합니다.
2. `Ctrl-R`을 누릅니다. gori가 플로우를 **Repeater** 탭으로 복사하고 그쪽으로 전환합니다.
3. 요청 패널에서 `Enter` 또는 `i`를 눌러 편집합니다(INS 모드). 작은 것 하나를 바꿔 보세요. 예를 들어 헤더 한 줄을 추가합니다:
   ```http
   X-Gori-Test: 1
   ```
4. `Esc`로 편집 모드를 벗어난 뒤 `Ctrl-R`로 **전송**합니다.
5. 응답과 타이밍, 이전 응답 대비 diff가 오른쪽에 나타납니다. `Tab`으로 target → request → response를 순회합니다.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="편집 가능한 요청 패널이 응답 패널 옆에 있고, replayed 200 in 1152ms라는 상태 줄이 보이는 gori Repeater 탭">
  <figcaption><strong>Repeater</strong>는 요청의 어느 부분이든 편집해 재전송합니다. 응답, 타이밍, 그리고 마지막 응답 대비 diff가 나란히 놓입니다.</figcaption>
</figure>

**확인.** Repeater 상태 줄에 `replayed 200 in … ms` 같은 문구가 보이고, `Ctrl-R`로 원하는 만큼 재전송할 수 있습니다. 이것이 완전한 캡처 → 검사 → 리플레이 루프입니다.

## 7. 다음으로 갈 곳 {#7-where-to-go-next}

이제 핵심 루프를 갖췄습니다. 여기서 나아갈 몇 가지 방향이며, 각각 [가이드](/ko/guide/)에서 깊이 다룹니다:

- **파라미터 퍼징.** 플로우를 선택하고 `Shift-I`로 **Fuzzer**에 보낸 뒤, 위치를 표시하고(`Ctrl-A`가 흔한 파라미터를 자동 표시), 워드리스트를 붙이고 `Ctrl-R`로 실행합니다. [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/)를 보세요.
- **진행 중 인터셉트와 편집.** `i`를 눌러 일치하는 요청을 잡아 두고, 계속 진행되기 전에 forward, drop, 또는 수정합니다. [Proxy & History](/ko/guide/proxy/#intercept)를 보세요.
- **찾은 것 추적하기.** 보고할 가치가 있는 것은 `Shift-F`로 **Issue**로 만들고, 둘러보는 동안 **Probe** 탭에서 패시브 결과를 읽으세요. [Scanning & Issues](/ko/guide/scanning/)를 보세요.

## Day-1 키 맵 {#day-1-key-map}

코드가 손에 익을 때까지 이 표를 가까이 두세요:

| 키 | 위치 | 동작 |
|-----|--------|--------|
| `Ctrl-P` | 어디서나 | 커맨드 팔레트(설정, Match & Replace, 알림, …) |
| `Ctrl-,` | 어디서나 | Preferences(모든 설정을 담은 하나의 모달) |
| `Space` | 포커스된 패널 | 영역 동작 메뉴 |
| `c` / `i` / `s` | 어디서나 | 캡처 / 인터셉트 / 스코프 렌즈 |
| `[` `]` · `1`-`9` | 어디서나 | 탭 전환 |
| `/` | History | 쿼리 언어 필터 |
| `Enter` | History | 플로우 상세 열기 |
| `Ctrl-R` | History | → Repeater |
| `Shift-I` | History | → Fuzzer |
| `Ctrl-R` | Repeater / Fuzzer | 요청 전송 / 퍼즈 실행 |
| `Esc` | 대부분의 곳 | 한 단계 뒤로 |

## 첫 실행 마법사 {#first-run-wizard}

가이드 설정(전역 프록시 바인드 기본값, 그다음 테마)을 언제든 다시 실행할 수 있습니다:

```bash
gori wizard
```

바인드 단계는 `settings.json`의 공유 기본값을 설정합니다. Preferences → **Network & Tabs** → **Network**와 같은 계층입니다. 프로젝트별 잠금이 아니며, 필요하면 Project 탭에서 평가마다 다른 주소를 고정하세요.

## 가이드 UI 투어 {#guided-ui-tour}

탭/패널 이동, 팔레트, space 메뉴, READ/INS 편집 모드를 목업 UI로 따라가는 안내입니다. 실제 프록시 세션 없이 안전하게 실행할 수 있습니다. 각 레슨은 짧은 데모를 보여주고 실제 키를 눌러 보도록 요청하며, 마지막 단계는 네 가지 동작 모두를 직접 해보는 실습 샌드박스와 첫 세션 체크리스트입니다.

```bash
gori tutorial
```

<figure class="tui-shot">
  <img src="/images/tui/tutorial.svg" alt="탭과 패널, 커맨드 팔레트, 동작 메뉴, 편집 모드라는 네 가지 핵심 동작을 설명하는 gori 가이드 투어 환영 카드">
  <figcaption>가이드 투어는 탭과 패널, 팔레트, space 메뉴, 그리고 READ / INS 편집 모드를 안내합니다. 각 키를 눌러 본 뒤, 안전한 샌드박스에서 네 가지를 모두 연습하세요.</figcaption>
</figure>

이 투어는 첫 실행 마법사의 마지막에도 제안됩니다.

## 다음 단계 {#next-steps}

- [설정](/ko/getting-started/configuration/): 저장소 구조, 네트워크 설정, 그리고 CA
- [Proxy & History](/ko/guide/proxy/): 캡처, 인터셉트, 스코프, 가져오기, match & replace
- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): 테스트 워크벤치와 env 토큰
- [Query Language](/ko/reference/query-language/): 전체 필터 문법
- [Hotkeys](/ko/guide/hotkeys/): 위의 코드를 원하는 대로 재지정
