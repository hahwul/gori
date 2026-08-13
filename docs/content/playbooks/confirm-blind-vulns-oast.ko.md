+++
title = "OAST로 블라인드 취약점 확인"
description = "어떤 버그는 응답에 절대 드러나지 않습니다 — 서버가 당신에게 연결하게 만들어 증명하고, 그 콜백을 잡으세요."
weight = 100

[extra]
group = "워크벤치"
+++

블라인드 SSRF, 블라인드 XXE, 대역 외(out-of-band) 인젝션 — 그 어느 것도 응답으로 답하지 않습니다. 대신 *다른* 서버로 연결을 뻗습니다. **OAST**는 그 서버를 당신에게 줍니다. gori가 리스너에 묶인 페이로드 URL을 발급하고, 당신이 그것을 요청에 심으면, 대상이 그리로 보내는 모든 DNS·HTTP 콜백이 가리킬 수 있는 히트로 도착합니다. 이 플레이북은 확인 하나를 처음부터 끝까지 약 10분에 실행합니다.

> **시작하기 전에.** 먼저 [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)를 마치고, 후보 인젝션 지점을 하나 준비하세요 — 서버가 URL을 가져오거나 호스트명을 해석하게 만들 수 있는 파라미터, 헤더, 필드입니다. 콜백은 그 메타데이터를 보는 공개 인터랙션 서버에 도달하므로, OAST는 테스트 권한이 있는 시스템에만 실행하고, 민감한 작업에는 self-hosted 프로바이더를 선호하세요.

## 1. 리스너를 시작하고 페이로드 받기 {#1-start-a-listener-and-grab-a-payload}

**OAST** 탭(기본 표시, Fuzzer 옆)을 열고 `Ctrl-R`을 눌러 리스닝을 시작합니다. gori가 프로바이더 — 기본은 공개 `interactsh` — 에 등록하고 **payload**를 발급합니다. 이 세션 동안 당신에게 속하는 고유한 호스트명/URL입니다. `g`(get payload)로 복사합니다.

리스너를 스크립트나 에이전트 루프에 두고 싶다면 헤드리스로:

```bash
gori run oast listen
```

한 가지 유의점: `gori run oast`는 저장소 없는 임시 리스너로, 그 등록은 프로세스와 함께 사라집니다. 리스너를 세션 너머로 유지하는 것은 TUI뿐이므로(나중에 `r`로 재개), 콜백이 늦게 도착할 수 있을 때는 탭을 쓰세요.

**체크포인트.** OAST 탭에 살아 있는 payload URL이 보이고, **Callbacks** 표는 비어 대기 중입니다.

## 2. 페이로드 심기 {#2-plant-the-payload}

그 payload URL을 가져다 대상이 역참조할 만한 곳에 넣습니다. 후보 요청을 **Repeater**(History에서 `Ctrl-R`)나 **Fuzzer**(`Shift-I`)로 보낸 뒤, `Space` → **Insert OAST payload**로 URL을 커서 위치에 떨굽니다. 서버 측 페치를 유발할 만한 곳이라면 어디든 심으세요: URL 파라미터, `Host`나 `X-Forwarded-For` 헤더, XXE용 XML 엔티티, 웹훅 필드. 요청을 전송합니다.

**체크포인트.** 페이로드를 실은 요청이 대상에 도달했습니다 — 여기서 응답은 평범해도 괜찮습니다. 핵심은 *서버*가 그다음 대역 밖에서 하는 일입니다.

## 3. 콜백 지켜보기 {#3-watch-for-a-callback}

다시 **OAST** 탭으로 오면, 대상 인프라가 이름을 해석하거나 다시 연결하면서 콜백이 **Callbacks** 표에 도착합니다 — 각각 프로토콜(`dns` / `http` / `smtp`), 소스 IP, 타임스탬프, 그리고 어느 페이로드가 발동했는지 알려 주는 하위 식별자를 담습니다. `Ctrl-X`는 폴링을 멈추지만 등록은 유지하므로, 이미 심어 둔 페이로드는 계속 해석됩니다. `r`을 눌러 나중에 재개하면, 자리를 비운 동안 프로바이더가 버퍼링한 것들을 받아 올 수 있습니다.

<figure class="tui-shot">
  <img src="/images/tui/oast.svg" alt="interactsh 페이로드에 대한 복호화된 히트 네 건의 Callbacks 표가 있는 gori OAST 탭으로, DNS A 조회 두 건과 HTTP GET 요청 두 건이 각각 소스 IP와 목적지로서의 페이로드와 함께 나열된다">
  <figcaption><strong>OAST</strong> 탭은 페이로드를 등록하고, 대상이 그리로 보내는 모든 DNS·HTTP·SMTP 콜백을 복호화하고 타임스탬프를 붙여 나열합니다.</figcaption>
</figure>

> 콜백은 대상이 닿을 이유가 없던 서버에 도달했다는 증거입니다. 콜백의 부재는 안전하다는 증거가 **아닙니다** — 이그레스(egress)가 필터링될 수 있습니다 — 이 경로가 조용했다는 것일 뿐입니다. 침묵만으로 후보를 닫지 마세요.

**체크포인트.** **Callbacks** 표에 2단계에서 심은 페이로드와 맞는 행이 최소 하나 놓입니다.

## 4. 히트를 Issue로 바꾸기 {#4-turn-a-hit-into-an-issue}

콜백은 이 도구가 만들어 내는 가장 강한 증거이므로 기록하세요. 히트를 선택하고 `Shift-F`(또는 `Space` → **Add issue**)를 눌러 **Issue**로 정리합니다. 프로토콜과 소스가 미리 채워지고, 원본 인터랙션이 notes로 딸려 들어갑니다. **HIGH**로 열리며 — `Tab`으로 확정 전에 등급을 다시 매깁니다.

**체크포인트.** 확인된 콜백이 **Issues** 탭에 증거가 붙은 Issue로 기록됩니다.

## 다음 단계 {#next-steps}

- [분류와 리포트](/ko/playbooks/triage-and-report/): 확인된 이슈를 산출물로
- [OAST](/ko/guide/oast/): 프로바이더, 리스너 재개, interactsh self-hosting
- [CLI Reference](/ko/reference/cli/#run-oast): 모든 `gori run oast` 플래그와 저장된 프로바이더 동사
