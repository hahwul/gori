+++
title = "JWT 공격"
description = "JSON Web Token을 디코드하고, 클레임을 변조하고, 서버가 실제로 서명을 검증하는지 시험합니다."
weight = 70

[extra]
group = "워크벤치"
+++

JWT는 서버가 서명을 검사하는 만큼만 믿을 수 있습니다. 이 플레이북은 캡처한 요청에서 토큰을 떼어 내 클레임을 읽고, 하나를 바꾸고, 다시 서명하고, 고전적인 검증 우회 페이로드 — alg:none, 약한 비밀키 추측, 헤더 인젝션 — 를 쏘아 서버가 어느 것을 받아들이는지 알아냅니다. 약 10분을 잡으세요.

> **시작하기 전에.** 테스트 권한이 있는 호스트에 대해 프로젝트와 스코프를 준비하고([엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)), JWT를 담은 플로우를 캡처하세요 — `Authorization: Bearer eyJ…` 헤더가 흔한 출처입니다. 예시는 `api.example.com`을 대상으로 합니다.

## 1. JWT 탭으로 토큰 보내기 {#1-send-a-token-to-the-jwt-tab}

**JWT** 탭은 기본적으로 숨겨져 있습니다. 탭 바 `⋯` 메뉴, 커맨드 팔레트(`Ctrl-P` → **Go to JWT**), 또는 Preferences에서 드러내세요. 그다음 토큰을 찾습니다. 캡처한 플로우를 **History**에서 열고, 요청 상세에서 `Bearer ` 뒤의 토큰 텍스트를 선택한 뒤 `Space` → **Send to JWT**. 그러면 새 JWT 서브탭이 시드되고, Decode 렌즈에서 토큰이 **header**, **payload**, **signature**로 라이브 디코드됩니다.

디코드는 토큰이 *주장하는* 바를 보여 줄 뿐, 서명을 검사하지는 않습니다. 그래서 깔끔하게 디코드되는 토큰이라고 서버가 반드시 믿는 토큰은 아닙니다. 그것이 이 플레이북의 나머지가 답하는 질문입니다.

<figure class="tui-shot">
  <img src="/images/tui/jwt.svg" alt="디코드된 HS256 토큰이 있는 gori JWT 탭: ^T:→ENCODE 렌즈 칩 아래의 INPUT 토큰, 디코드된 header JSON, 그리고 alg=none 대소문자 변형과 서명 제거를 포함한 생성된 페이로드의 ATTACKS 목록">
  <figcaption><strong>JWT</strong> 탭은 토큰을 라이브로 디코드하고(header, payload, signature) 바로 보낼 수 있는 공격 페이로드를 나열합니다: alg:none, weak-secret, header injection.</figcaption>
</figure>

**체크포인트.** JWT 탭에 토큰의 header와 payload가 JSON으로, 그 아래에 signature가 보입니다.

## 2. 클레임 변조 {#2-tamper-a-claim}

`Ctrl-T`로 Encode 렌즈로 전환하거나, `l`을 눌러 디코드된 토큰을 곧장 Encode 편집기로 불러오세요. **PAYLOAD** JSON을 편집합니다 — `role`을 올리고, `sub`를 바꾸고, `exp`를 늘리세요. `Ctrl-A`로 알고리즘을 고르고(`HS256` / `HS384` / `HS512` / `none`을 순환), HMAC 알고리즘으로 서명한다면 **SECRET**을 설정하면, 다시 서명된 토큰이 OUTPUT에 라이브로 나타납니다. `y`로 복사하세요.

같은 재서명이 헤드리스로도 실행되며, 토큰은 인수나 stdin에서 받습니다:

```bash
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
```

**체크포인트.** OUTPUT에 당신이 편집한 클레임을 담고, 당신이 고른 알고리즘과 비밀키로 다시 서명된 토큰이 있습니다.

## 3. 공격 프리셋 실행 {#3-run-the-attack-presets}

비밀키를 아는 경우는 드무니, 대신 gori가 우회 시도를 생성하게 하세요. Decode 렌즈에서 디코드된 부분 아래에, 토큰으로부터 만들어진 선택 가능한 **공격 페이로드** 목록이 있습니다:

| 공격 | 무엇을 시험하는가 |
|--------|---------------|
| **alg:none** | 서명을 제거하고 `alg`를 `none`으로 설정합니다(`None` / `NONE` 대소문자 변형 포함) — 서명 없는 토큰을 받아들이는 서버. |
| **Weak secret** | 흔한 약한 HMAC 비밀키 목록으로 다시 서명합니다 — 추측 가능한 서명 키. |
| **Header injection** | `kid`, `jku`, `x5u`, `jwk` 헤더 파라미터를 조작합니다 — 공격자가 제공한 키 자료를 신뢰하는 서버. |

같은 세트를 헤드리스로 생성합니다:

```bash
gori run jwt eyJhbGci... --attacks
```

MCP에서는 `jwt_attacks` 도구가 동일한 목록을 반환합니다(`jwt_decode` / `jwt_encode`가 1·2단계를 담당). 셋 다 네트워크를 건드리지 않으므로 `--read-only`에서도 쓸 수 있는 읽기 도구입니다.

**체크포인트.** ATTACKS 목록이 바로 보낼 수 있는 토큰 변형들로 채워집니다.

## 4. 재생하고 확인하기 {#4-replay-and-confirm}

위조 토큰은 서버가 볼 때까지 아무것도 증명하지 못합니다. 페이로드를 하나 고르세요 — 2단계에서 변조한 토큰이든, 3단계의 프리셋이든 — 그리고 **Repeater**로 보내, 캡처한 요청의 `Authorization` 헤더에 끼워 넣고 `Ctrl-R`로 다시 보냅니다. 잘못된 토큰에 대해 엔드포인트가 반환해야 할 것과 상태를 대조해 읽으세요:

- `401` 또는 `403`은 서버가 위조를 거부했다는 뜻입니다 — 서명을 검증한 것입니다.
- 거부를 기대한 자리에 `200`이 나오면 검증하지 *않은* 것입니다 — 토큰이 당신의 조건대로 받아들여졌습니다.

**체크포인트.** 받아들여진 위조(성공 상태)와 거부된 위조(`401` / `403`)를 구분할 수 있고, 서버가 어떤 프리셋을(있다면) 통과시켰는지 압니다.

## 다음 단계 {#next-steps}

- [세션 쿠키 크랙과 위조](/ko/playbooks/crack-and-forge-cookies/): 서명된 세션 쿠키에 대한 같은 읽기-변조-재생 루프
- [JWT](/ko/guide/jwt/): 두 렌즈, 재서명, 그리고 모든 공격을 깊이 있게
- [CLI Reference](/ko/reference/cli/#run-jwt): `gori run jwt`의 모든 옵션
