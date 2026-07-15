+++
title = "빠른 시작"
description = "프록시를 시작하고, CA를 신뢰하고, 첫 플로우를 캡처하고, Day-1 단축키를 익힙니다."
+++

갓 빌드한 상태에서 완전한 캡처 → 검사 → Repeater 루프까지 몇 분 만에 도달하세요. 이 페이지는 gori 기초를 가장 빠르게 훑는 길입니다. 트래픽이 흐르기 시작하면 [가이드](/ko/guide/)가 더 깊이 들어갑니다.

## 1. gori 시작하기
TUI를 실행합니다. 하위 명령 없이 실행하면 gori는 프록시를 시작하고 인터페이스를 엽니다:

```bash
gori
```

기본적으로 프록시는 `127.0.0.1:8070`에서 수신합니다. 첫 실행 시 짧은 [설정 마법사](#first-run-wizard)가 실행되어 **전역 기본** 바인드와 테마를 고르게 하고, 이어서 대화식 [UI 투어](#guided-ui-tour)를 제안합니다. 개별 프로젝트는 나중에 Project 탭에서 다른 바인드를 고정할 수 있습니다.

한 번의 실행에 대해서만 전역 바인드를 플래그로 재정의할 수 있습니다(디스크에 기록되지 않으며, 프로젝트 자체 바인드가 설정되어 있으면 여전히 그쪽이 우선합니다):

```bash
gori --listen 0.0.0.0 --port 8080
```

## 2. CA를 신뢰하고 트래픽 받기
HTTPS를 인터셉트하려면 클라이언트가 gori의 루트 인증서(첫 실행 시 `~/.gori/ca` 아래에 생성됨)를 신뢰해야 합니다. 흔한 두 가지 경로가 있습니다:

### Option A — 사전 신뢰된 브라우저 열기 (권장) {#option-a-open-a-pre-trusted-browser-recommended}

TUI 안에서:

1. `Ctrl-P`를 눌러 **커맨드 팔레트**를 엽니다.
2. **Open browser**를 실행합니다.
3. 설치된 브라우저(Chrome, Chromium, Brave, Edge, Firefox, …)를 고릅니다.

gori는 이미 CA를 신뢰하고 HTTP/HTTPS를 프록시로 경유하는 격리된 프로파일로 브라우저를 실행합니다. 사이트를 둘러보면 별도의 시스템 신뢰 단계 없이 플로우가 **History**에 도착합니다.

History가 비어 있을 때도 이 경로를 안내합니다(`^P → Open browser`).

### Option B — 클라이언트를 직접 지정하기 {#option-b-point-any-client-yourself}

CA 경로를 출력하고 그 파일을 시스템 또는 브라우저 신뢰 저장소에 **신뢰된 루트 CA**로 가져오세요:

```bash
gori ca
```

그런 다음 클라이언트가 `127.0.0.1:8070`을 HTTP **및** HTTPS 프록시로 사용하도록 설정하세요. 간단한 동작 확인:

```bash
curl -x http://127.0.0.1:8070 https://example.com
```

gori는 요청 시 루트로부터 호스트별 리프 인증서를 발급하므로, 루트만 한 번 신뢰하면 됩니다.

> gori의 개인 키는 머신 비밀입니다. `0600` 권한으로 기록되며 머신을 절대 벗어나지 않습니다. 이전의 모든 신뢰를 무효화할 의도가 있을 때만 팔레트(**Regenerate CA certificate**)에서 교체하세요.

## 3. 두 가지 탐색 표면 익히기
거의 모든 것이 두 곳에서 접근 가능합니다. 탭별 단축키를 외우기 전에 이 둘을 먼저 익히세요.

| 표면 | 키 | 용도 |
|---------|-----|----------------|
| **커맨드 팔레트** | `Ctrl-P` | 앱 전역 제어: 설정, Open browser, Export CA, 이동 동작 등 전역적인 모든 것 |
| **space 메뉴** | `Space` | 지금 **포커스를 가진 대상**에 대한 동작(History 행, 상세 패널, Repeater, …) |

팔레트는 도구 전체의 지도입니다. space 메뉴는 *이* 패널의 지도입니다. 둘 다 키 힌트를 보여주니, 코드를 잊었으면 둘 중 하나를 여세요.

<figure class="tui-shot">
  <img src="/images/tui/command-palette.svg" alt="History 탭 위에 열린 gori 커맨드 팔레트로, 필터 상자와 함께 설정, 이동, 내보내기 동작을 나열한다">
  <figcaption>커맨드 팔레트(<kbd>Ctrl-P</kbd>): 설정부터 <em>Open browser</em>, 탭 이동까지 앱 전역의 모든 동작을 퍼지 필터로 찾습니다.</figcaption>
</figure>

캡처와 인터셉트에는 여전히 전역 토글이 있습니다:

| 키 | 동작 |
|-----|--------|
| `c` | **캡처** 토글(끄면 트래픽이 저장되지 않고 그대로 통과) |
| `i` | **인터셉트** 토글(일치하는 요청을 잡아 forward / drop / edit) |
| `s` | **스코프 렌즈** 토글(뷰를 스코프 내 트래픽으로 필터) |
| `Ctrl-P` → Match & Replace | 진행 중인 요청/응답 재작성 규칙(팔레트; 재지정 가능) |

## 4. TUI 이동하기
gori는 **탭**의 한 줄입니다. 기본 순서는 Project → Sitemap → **History** → Intercept → Repeater → Fuzzer → … 로 시작합니다.

| 키 | 동작 |
|-----|--------|
| `[` / `]` | 이전 / 다음 탭 |
| `1`–`9` | N번째 **표시된** 탭으로 이동(기본값에서 History는 `3`) |
| `Enter` / `↓` | 탭 바에서 탭 본문으로 진입 |
| `Esc` | 포커스를 탭 바 쪽으로 되돌림 |
| `Tab` / `Shift-Tab` | 탭 바와 패널 사이로 포커스 이동 |

마우스는 활성화하면(설정) 동작합니다: 탭 클릭, 행 클릭으로 선택, 다시 클릭으로 열기.

**Help** 탭은 앱 안의 완전한 키 치트시트입니다. 이 페이지가 열려 있지 않을 때 사용하세요.

## 5. History에서 플로우 지켜보기
**History**로 전환하세요(`3`, 또는 History가 활성화될 때까지 `[` / `]`). 모든 요청/응답은 *플로우*입니다: 시작 줄, 헤더, 본문(최대 2 MiB 저장), 그리고 HTTP/2 프레임, WebSocket 메시지, 존재하면 디코드된 JWT / SAML / GraphQL까지.

<figure class="tui-shot">
  <img src="/images/tui/history.svg" alt="시간, 메서드, 프로토콜, 호스트, 경로, 상태, 유형, 크기, 소요 시간 열로 캡처된 HTTP 플로우를 나열하는 gori History 탭">
  <figcaption><strong>History</strong> 탭: 메서드, 상태, 크기, 타이밍이 담긴 모든 캡처 플로우를 쿼리 언어로 필터할 수 있습니다.</figcaption>
</figure>

| 키 | 동작 |
|-----|--------|
| `↑` / `↓` (또는 `j` / `k`) | 선택 이동 |
| `Enter` | 요청/응답 상세 열기 |
| `/` | [쿼리 언어](/ko/reference/query-language/)로 필터 |
| `f` | 최신 따라가기(tail) 토글 |
| `y` | 선택한 플로우 복사 |

`/`를 연 뒤의 필터 예시:

```text
status:5xx
host:api.example.com
method:POST body:password
```

상세 화면에서: `↑` / `↓`로 스크롤, `y`로 복사, 그리고 hex / whitespace / pretty 본문에는 `x` / `b` / `p`를 사용합니다. `Space`는 여전히 포커스된 패널의 동작 메뉴를 엽니다.

## 6. 플로우로 무언가 해보기
History(목록 또는 상세)에서 플로우를 선택한 뒤:

| 키 | 동작 |
|-----|--------|
| `Ctrl-R` | 플로우를 **Repeater**로 보내기(편집 후 재전송) |
| `Shift-I` | 플로우를 **Fuzzer**로 보내기 |
| `Shift-F` | 플로우로부터 **Issue** 생성 |
| `Space` | 기타 동작(Comparer, 복사, 스코프 호스트, …) |

### 최소 Repeater 루프 {#minimal-repeater-loop}

1. History에서 플로우를 선택 → `Ctrl-R`(Repeater로 들어감).
2. 요청에서 `Enter` 또는 `i`로 편집(INS 모드); `Esc`로 READ로 복귀.
3. 다시 `Ctrl-R`로 **전송**; 응답을 살펴봅니다(타이밍과 이전 응답 대비 diff).
4. `Tab`으로 target → request → response를 순회합니다.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="편집 가능한 요청 패널이 응답 패널 옆에 있고, replayed 200 in 1152ms라는 상태 줄이 보이는 gori Repeater 탭">
  <figcaption><strong>Repeater</strong>는 요청의 어느 부분이든 편집해 재전송합니다. 응답, 타이밍, 그리고 마지막 응답 대비 diff가 나란히 놓입니다.</figcaption>
</figure>

### 최소 Fuzzer 루프 {#minimal-fuzzer-loop}

1. History에서 플로우를 선택 → `Shift-I`.
2. 위치를 표시합니다(`Ctrl-A`로 흔한 파라미터를 자동 표시하거나, `§…§`로 직접 표시).
3. config 패널에서 워드리스트나 목록을 붙입니다(`Ctrl-O`로 포커스).
4. `Ctrl-R`로 실행; `Ctrl-X`로 중지.

둘러보는 동안 **Probe**가 추가 트래픽 없이 패시브 이슈를 표시합니다. 추적할 가치가 있는 것은 **Issues**로 승격하세요. 자세한 내용은 [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/)와 [Scanning & Issues](/ko/guide/scanning/)에 있습니다.

## Day-1 키 맵 {#day-1-key-map}

코드가 손에 익을 때까지 이 표를 가까이 두세요:

| 키 | 위치 | 동작 |
|-----|--------|--------|
| `Ctrl-P` | 어디서나 | 커맨드 팔레트(설정, Match & Replace, 알림, …) |
| `Space` | 포커스된 패널 | 영역 동작 메뉴 |
| `c` / `i` / `s` | 어디서나 | 캡처 / 인터셉트 / 스코프 렌즈 |
| `[` `]` · `1`–`9` | 어디서나 | 탭 전환 |
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

바인드 단계는 `settings.json`의 공유 기본값을 설정합니다. **Settings: Network**와 같은 계층입니다. 프로젝트별 잠금이 아니며, 필요하면 Project 탭에서 평가마다 다른 주소를 고정하세요.

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

- [설정](/ko/getting-started/configuration/) — 저장소 구조, 네트워크 설정, 그리고 CA
- [Proxy & History](/ko/guide/proxy/) — 캡처, 인터셉트, 스코프, 가져오기, match & replace
- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/) — 테스트 워크벤치와 env 토큰
- [Decoder](/ko/guide/decoder/) — 인코드 / 디코드 / 해시 파이프라인
- [Query Language](/ko/reference/query-language/) — 전체 필터 문법
- [Hotkeys](/ko/guide/hotkeys/) — 위의 코드를 원하는 대로 재지정
