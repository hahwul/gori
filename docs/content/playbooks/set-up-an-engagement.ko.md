+++
title = "엔게이지먼트 준비"
description = "프로젝트를 만들고, 스코프를 그리고, 테스트를 샌드박스 안에 가둡니다 — 모든 액티브 도구가 발동 전에 확인하는 가드레일입니다."
weight = 10

[extra]
group = "기초"
+++

요청 하나를 캡처하기 전에 테스트의 경계부터 정합니다. 어느 프로젝트가 트래픽을 담을지, 어떤 호스트가 스코프에 들어가는지, 그리고 gori가 그 밖의 무언가를 건드려도 되는지까지요. 이 플레이북은 그 셋을 모두 다룹니다. 약 5분이 걸리며, 이후의 모든 단계를 안전하게 만드는 지점입니다. Repeater, Fuzzer, 스캐너 모두 스코프를 잡지 않은 대상에는 발동을 거부합니다.

> **시작하기 전에.** 먼저 [Quick Start](/ko/getting-started/quick-start/)를 끝내 gori가 실행 중이고 탭 사이를 이동할 수 있게 하세요. 테스트 권한이 있는 호스트를 하나 떠올려 두세요. 예시는 `api.example.com`을 대역으로 씁니다.

## 1. 프로젝트 만들기 {#1-create-a-project}

프로젝트는 하나의 SQLite 데이터베이스입니다. 자체 history, scope, issues, notes를 가지며 다른 모든 엔게이지먼트와 격리됩니다. 대상마다 별도 프로젝트에 담는 것이야말로 스코프와 샌드박스에 의미를 부여합니다.

TUI에서는 커맨드 팔레트(`Ctrl-P`, 이어서 *project* 입력)로 프로젝트 피커를 열어 새로 시작합니다. 또는 프록시가 뜨기 전에 셸에서 만들어, 스크립트가 스코프와 env를 먼저 깔아 둘 수도 있습니다:

```bash
gori run project create "Acme API" --description="staging engagement"
```

이미 있는 이름으로 만들면 그 프로젝트를 다시 열 뿐이므로, 다시 실행해도 안전합니다.

**체크포인트.** **Project** 탭 헤더에 프로젝트 이름이 보이고, **History**(탭 `3`)는 비어 있습니다.

## 2. 스코프 그리기 {#2-draw-your-scope}

**Project** 탭을 열고 **SCOPE** 카드로 이동한 뒤 `↓` 또는 `Enter`로 안으로 들어갑니다. 스코프는 **include**와 **exclude** 규칙의 목록이며, 각 규칙은 **host**, **string**, 또는 **regex**로 매칭합니다. 대상에 대한 include를 하나 추가하고, 관심 없는 노이즈를 exclude로 걸러 냅니다:

```bash
gori run project scope add --kind=include --type=host  --pattern=api.example.com
gori run project scope add --kind=exclude --type=regex --pattern='\.(css|js|png|woff2?)$'
```

스코프는 **허용 목록(allowlist)** 으로 평가됩니다. include 규칙 중 하나 이상이 매칭하고 exclude 규칙이 하나도 매칭하지 않을 때 플로우가 스코프 안에 듭니다. 이 정의가 다음 두 단계를 좌우합니다.

**체크포인트.** `gori run project scope`(또는 SCOPE 카드)에 두 규칙이 모두 나열됩니다. 아직 걸러지거나 차단되는 것은 없습니다 — 경계를 서술했을 뿐입니다.

## 3. 스코프 렌즈로 시야 좁히기 {#3-focus-your-view-with-the-scope-lens}

어디서든 `s`를 눌러 **스코프 렌즈**를 토글합니다. History, Sitemap, 그 밖의 뷰를 스코프 안 트래픽으로 좁혀, 분주한 캡처가 대상만 남도록 접힙니다. 이것은 *렌즈*이지 게이트가 아닙니다. 스코프 밖 플로우도 여전히 캡처되며, 다시 끄는 순간 되돌아옵니다.

**체크포인트.** 렌즈를 켜면 History에 `api.example.com` 행만 보입니다. `s`를 다시 누르면 나머지 트래픽이 돌아옵니다.

## 4. 샌드박스로 테스트 가두기 {#4-contain-the-test-with-the-sandbox}

스코프 렌즈는 트래픽을 숨기고, **샌드박스**는 트래픽을 멈춥니다. **Project → NETWORK** 패널에서 켜거나, 어디서든 `Ctrl-P` → **Toggle sandbox**로 켭니다:

```bash
gori run project sandbox on
```

켜져 있는 동안 프록시는 스코프가 허용하는 요청만 흘려보내고, 나머지는 origin에 닿기 전에 차단합니다. 차단된 요청은 `X-Gori-Sandbox: blocked` 헤더를 단 `403`으로 돌아오며(HTTP/2에서는 스트림이 취소됩니다), 그 시도는 여전히 중단된 플로우로 기록되어 무엇이 빠져나가려 했는지 볼 수 있습니다.

스코프가 허용 목록이므로 **include 규칙이 없는 샌드박스는 모든 것을 차단합니다** — 스코프를 먼저 그린 이유가 바로 이것입니다. 켜져 있는 내내 상단 바에 빨간 `sandbox` 칩이 켜져 있습니다.

**체크포인트.** `sandbox` 칩이 켜져 있습니다. 스코프 밖 사이트로의 요청은 실패하고, `api.example.com`으로의 요청은 통과합니다. 다시 자유롭게 다니려면 샌드박스를 끄세요.

## 5. DNS를 건드리지 않고 호스트 리다이렉트 (선택) {#5-redirect-a-host-without-touching-dns-optional}

대상의 이름이 공개 DNS가 아닌 다른 곳으로 — 스테이징 서버, 로컬 인스턴스로 — 해석되어야 한다면, **Project → HOST OVERRIDES** 카드에 **host override**를 추가하세요. TCP 다이얼 대상만 바꿀 뿐, SNI·인증서 이름·`Host` 헤더는 원래 이름 그대로라 서버는 평범한 요청으로 봅니다:

```bash
gori run project host-override add --host=api.example.com --ip=10.0.0.1
```

**체크포인트.** `gori run project host-override`에 항목이 나열되고, `api.example.com`으로의 요청이 이제 `10.0.0.1`로 연결됩니다.

## 스코프가 먼저인 이유 {#why-scope-comes-first}

스코프는 필터만이 아닙니다. 액티브 도구들은 스코프를 스스로 강제합니다. **Repeater**, **Fuzzer**, **Miner**, 그리고 MCP `send_request` 도구는 샌드박스가 켜져 있든 아니든, 스코프 밖 대상을 `SCOPE_BLOCKED` 오류로 거부합니다. 이것이 빗나간 재전송이나 퍼징 실행이 의도치 않은 호스트에 닿는 것을 막는 가드레일입니다. 스코프를 여기서 한 번 잡아 두면, 이후의 모든 플레이북이 그것을 물려받습니다.

## 다음 단계 {#next-steps}

- [공격면 매핑](/ko/playbooks/map-the-attack-surface/): 스코프가 걸린 캡처를 사이트맵으로
- [Proxy & History](/ko/guide/proxy/#scope): 스코프, 샌드박스, 호스트 오버라이드 전체 레퍼런스
- [Query Language](/ko/reference/query-language/): 호스트 말고도 더 많은 조건으로 History 필터링
