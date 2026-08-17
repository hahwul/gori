+++
title = "OAST"
description = "out-of-band 콜백(interactsh 등)을 잡아 blind SSRF, XXE, injection을 확인하세요."
weight = 70

[extra]
group = "워크벤치"
+++

어떤 버그는 응답에 절대 드러나지 않습니다. blind SSRF, blind XXE, out-of-band SQL injection, 또는 백오피스 브라우저에서만 발동하는 stored payload는 요청한 쪽에 답하는 대신 *다른 어딘가의 서버*로 손을 뻗습니다. **OAST**(Out-of-band Application Security Testing)는 바로 그 서버를 제공합니다. gori가 interaction 리스너에 payload URL을 등록하고, 그 payload를 요청에 심어 두면, 대상이 그 서버로 보내는 DNS, HTTP, SMTP 콜백이 hit로 나타납니다.

**OAST** 탭은 기본적으로 표시됩니다(Fuzzer 옆). 두 개의 서브탭이 있습니다. **Callbacks**(hit 목록, 기본)와 **Providers**(설정한 리스너)입니다.

<figure class="tui-shot">
  <img src="/images/tui/oast.svg" alt="interactsh payload로 들어온 복호화된 콜백 4건(DNS A 조회 2건, HTTP GET 2건)이 각각 source IP와 목적지 payload와 함께 나열된 gori OAST 탭의 Callbacks 테이블">
  <figcaption><strong>OAST</strong> 탭은 payload를 등록하고, 대상이 그 payload로 보내는 모든 DNS, HTTP, SMTP 콜백을 복호화해 타임스탬프와 함께 나열합니다.</figcaption>
</figure>

## 동작 흐름 {#the-loop}

1. **OAST** 탭에서 `Ctrl-R`를 눌러 리스닝을 시작합니다. gori가 provider에 등록하고 **payload**(고유한 호스트명/URL)를 발급합니다.
2. `g`(get payload)나 `y`로 payload를 복사하거나, **Repeater** / **Fuzzer**에서 요청에 바로 삽입합니다(`Space` → **Insert OAST payload**가 커서 위치에 넣습니다). **History**에서는 `Space` → **Copy OAST payload**입니다.
3. 대상이 URL을 역참조하거나 호스트명을 resolve할 만한 곳이라면 어디든 심습니다. URL 파라미터, `Host`/`X-Forwarded-For` 헤더, XML 엔티티, webhook 필드 등입니다.
4. 대상의 인프라가 이름을 resolve하거나 다시 연결해 오면, 콜백이 프로토콜(`dns` / `http` / `smtp`), 소스 IP, 타임스탬프, 그리고 어떤 payload가 발동했는지 알 수 있는 전체 sub-identifier와 함께 **Callbacks**에 도착합니다.

콜백은 대상이 접근해서는 안 될 서버에 접근했다는 증거입니다. 콜백이 없다고 해서 안전하다는 증거는 아니며(egress가 필터링됐을 수 있습니다), 다만 이 경로가 조용했다는 뜻일 뿐입니다.

## Providers {#providers}

각 리스너가 하나의 **provider**입니다. **Providers** 서브탭에서 추가하세요(`a` 추가, `e` 편집, `t` 타입 설정, `d` 삭제). public preset은 타입을 고를 때 서버 호스트를 자동으로 채워줍니다.

콜백 테이블 위의 바가 `g`와 `Ctrl-R`가 사용할 provider를 고릅니다. `←` / `→`로 순환하며(바에는 `‹ 이름 ›`으로 표시됩니다), **All**은 모든 provider의 콜백을 한 번에 보여줍니다. payload를 받거나 리스닝을 시작하려면 provider가 하나로 정해져야 하므로, **All** 상태에서 활성화된 provider가 둘 이상이면 `g`와 `Ctrl-R`가 선택 카드를 엽니다. `↵`로 고르면 바도 따라갑니다. 활성화된 provider가 하나뿐이면 물어볼 것이 없으니 바로 실행됩니다.

| Provider | 설명 |
|----------|-----------|
| `interactsh` | 자체 호스팅 또는 public [interactsh](https://github.com/projectdiscovery/interactsh) 서버. 암호화된 **DNS, HTTP, SMTP** 콜백을 잡습니다. Public preset: `oast.pro`, `oast.live`, `oast.site`, `oast.fun`, `oast.me`. 기본값입니다. |
| `custom-http` | 직접 운영하며 hit를 폴링하는 평범한 HTTP 엔드포인트. |
| `webhook.site` | public [webhook.site](https://webhook.site) 서비스(HTTP 전용). |
| `BOAST` | [BOAST](https://github.com/firebasextended/boast) 서버(public preset `odiss.eu`). |
| `postbin` | PostBin 인스턴스(`postb.in`). |

interactsh를 쓰면 gori가 로컬에서 RSA 키 쌍을 생성해 공개 키를 등록하고 각 콜백을 복호화합니다(비밀 키는 프로젝트 데이터베이스에 `0600`으로 저장되며 로그에 남지 않습니다). payload id는 correlation id로부터 로컬에서 파생되므로, 한 번의 등록으로 별도의 왕복 없이 여러 payload를 발급할 수 있습니다.

## 리스너 재개 {#resuming-a-listener}

정작 중요한 콜백은 늦게 옵니다. 누군가 백오피스 페이지를 열어야 발동하는 stored payload, 야간 배치가 재시도하는 webhook, 큐 뒤에 있는 injection처럼요. 그래서 리스너는 그것을 시작한 세션보다 오래 살아남습니다.

`Ctrl-X`는 폴링을 멈추지만 **등록은 유지합니다.** gori를 종료하거나 프로젝트를 떠날 때도 마찬가지입니다. 이미 심어둔 payload는 계속 resolve됩니다. `r`를 눌러 **RESUME LISTENER**를 열고 저장된 세션을 고르면 gori가 다시 폴링을 시작합니다. 자리를 비운 사이 provider가 버퍼링해 둔 콜백은 다음 폴링에서 들어오고, 그 세션에 이미 쌓인 콜백도 그대로 아래에 남아 있습니다.

| 키 | 피커에서 |
|-----|---------------|
| `↵` | 이 세션의 폴링 재개 |
| `x` | 릴리스 — 끝난 engagement의 서버 측 상태를 해제합니다. 콜백은 남습니다. |

콜백은 프로젝트별로 지속되는 이력입니다. 재개는 의도적인 동작이며 gori가 시작할 때 알아서 하지 않습니다. 프로젝트를 다시 연다고 해서 묻지도 않고 서드파티 provider에 다시 붙지는 않습니다.

세 표면 모두 같은 세션을 재개합니다. `gori run oast list` / `resume` / `release`와 MCP `list_oast_sessions` / `oast_resume` / `oast_release`는 이 피커가 보여주는 것과 동일한 행을 다루고, 헤드리스로 재개한 리스너도 콜백을 프로젝트에 기록합니다. 즉 탭과 스크립트와 에이전트가 하나의 테이블을 봅니다. 임시로 남는 것은 `gori run oast listen`과 MCP `oast_start`입니다. 이 둘은 프로젝트 없이 등록하므로 그 등록은 프로세스와 함께 끝납니다.

어느 표면도 알아서 재개하지 않습니다. 프로젝트를 열거나 MCP 서버를 바인딩하거나 `gori run`을 시작해도 리스너가 되살아나지 않습니다. 누군가 요청해야 합니다.

## 키 {#keys}

| 키 | 동작 |
|-----|--------|
| `Ctrl-R` | 리스닝 시작(payload 등록 후 폴링 시작) |
| `Ctrl-X` | 폴링 중지(세션은 유지 — `r`로 재개) |
| `r` | 저장된 리스너 재개 |
| `g` | 현재 payload 가져오기 / 복사(**All**이면 provider를 고르는 카드) |
| `←` / `→` | 바가 사용할 provider 순환 |
| `y` | 선택한 콜백 복사 |
| `Shift-F` | 선택한 콜백을 Issue로 등록 |
| `/` | 콜백 목록 필터링 |
| `a` / `e` / `t` / `d` | Providers 서브탭: 추가 / 편집 / 타입 설정 / 삭제 |

## 콜백을 Issue로 {#filing-a-callback}

콜백은 이 도구가 만들어내는 가장 강력한 증거입니다. 대상의 인프라가 접근할 이유가 전혀 없는 서버에 스스로 닿았다는 뜻이니까요. `Shift-F`(또는 `Space` → **Add issue**)는 선택한 콜백을 **Issue**로 등록합니다. 프로토콜과 소스가 미리 채워지고, raw interaction이 notes로 함께 들어갑니다. **HIGH**로 열리며, 확정 전에 Tab으로 등급을 바꿀 수 있습니다.

## 헤드리스 {#headless}

`gori run oast listen`은 임시적이고 저장소를 쓰지 않는 리스너입니다. payload를 등록하고 stdout에 출력한 다음, 멈출 때까지 콜백을 스트리밍합니다.

```bash
gori run oast presets                          # list the built-in public providers
gori run oast listen                           # interactsh, poll until Ctrl-C
gori run oast listen --provider webhook.site   # a different provider
gori run oast listen --once --json             # poll once, emit JSON lines
```

위 피커가 재개하는 프로젝트의 저장된 세션도 헤드리스로 다룰 수 있습니다.

```bash
gori run oast list                             # id, provider, payload host, hits, last poll
gori run oast resume 7                         # re-arm session #7 and stream its callbacks
gori run oast resume 7 --once --json           # one poll, JSON lines, then exit
gori run oast release 7                        # deregister it; its callbacks stay
```

`resume`은 종료해도 등록을 유지하고(Ctrl-C는 폴링만 멈춥니다) 받은 콜백을 프로젝트에 저장하므로 OAST 탭에서 같은 hit를 봅니다. 정리는 `release`로 명시적으로 합니다.

모든 플래그는 [CLI Reference](/ko/reference/cli/#run-oast)를 참고하세요. MCP에서는 에이전트가 `oast_presets` / `oast_payload` / `oast_poll` / `list_oast_sessions`(읽기)와 `oast_start` / `oast_stop` / `oast_resume` / `oast_release`(동작)로 같은 엔진을 구동합니다. `oast_resume`은 `oast_poll`과 `oast_payload`가 받는 `session_id`를 돌려주고 그 폴링 결과는 CLI와 마찬가지로 저장됩니다. 재개한 세션에 `oast_stop`을 호출하면 `Ctrl-X`처럼 폴링만 멈추고 세션은 다시 재개할 수 있게 남습니다.

> 콜백은 대상이 서드파티 interaction 서버에 접속했다는 뜻이며, public interactsh/webhook 서버는 그 콜백의 메타데이터를 보게 됩니다. 테스트 권한이 있는 시스템에만 OAST를 실행하고, 민감한 engagement에서는 자체 호스팅 서버를 우선하세요.

## 다음 단계 {#next-steps}

- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): payload를 심고 여러 위치에서 fuzz합니다
- [Scanning & Issues](/ko/guide/scanning/): 확인된 콜백을 Issue로 승격합니다
- [MCP Server](/ko/guide/mcp/): 에이전트가 payload를 등록하고 hit를 폴링하게 합니다
