+++
title = "JWT"
description = "JSON Web Token을 디코드, 편집, 재서명하고 alg:none, weak-secret, header-injection 페이로드를 생성합니다."
weight = 50

[extra]
group = "워크벤치"
+++

**JWT** 탭은 JSON Web Token을 위한 워크벤치입니다. 토큰을 디코드하고, claim을 편집해 재서명하며, 서버를 상대로 테스트할 고전적인 공격 페이로드를 생성합니다. 파트를 보여주기만 하는 [Decoder](/ko/guide/decoder/)의 읽기 전용 `jwt-decode` 컨버터보다 한 걸음 더 나아갑니다.

<figure class="tui-shot">
  <img src="/images/tui/jwt.svg" alt="디코드된 HS256 토큰을 보여주는 gori JWT 탭: INPUT 토큰, 디코드된 header JSON, 그리고 alg=none 대소문자 변형과 signature 제거를 포함한 23개 공격 페이로드의 ATTACKS 목록">
  <figcaption><strong>JWT</strong> 탭은 토큰을 실시간으로 디코드하고(header, payload, signature), 바로 보낼 수 있는 공격 페이로드(alg:none, weak-secret, header injection)를 나열합니다.</figcaption>
</figure>

이 탭은 기본적으로 숨겨져 있습니다. 탭 바의 `⋯` 메뉴나 커맨드 팔레트(`Ctrl-P` → **Go to JWT**)에서 드러내세요. 어디서든(예: **History** 상세 패널, **Notes** 등) 토큰을 선택하고 `Space` → **Send to JWT**를 누르면 그 토큰으로 새 워크벤치 서브탭을 채웁니다. 세션은 휘발성이라 디스크에는 아무것도 기록되지 않습니다.

## 두 개의 렌즈 {#two-lenses}

하나의 세션, 두 개의 뷰이며 `Ctrl-E`로 전환합니다:

- **Decode**: INPUT에 토큰을 붙여 넣으면 header, payload, signature가 실시간으로 디코드됩니다. 그 아래에는 생성된 **공격 페이로드**를 고를 수 있는 목록이 있습니다.
- **Encode**: HEADER와 PAYLOAD를 JSON으로 편집하고, 알고리즘을 선택하며(`Ctrl-A`로 `HS256` / `HS384` / `HS512` / `none` 순환), SECRET을 설정하면 재서명된 토큰이 OUTPUT에 실시간으로 나타납니다.

`l`을 누르면 현재 Decode 쪽에서 디코드된 토큰을 Encode 편집기로 불러옵니다. 그래서 claim 하나를 손보고 두 동작만으로 재서명할 수 있습니다. 결과는 `y`로 복사하세요.

> signature는 디코드되어 표시되지만 **결코 검증되지 않습니다**. 따라서 디코드는 토큰이 무엇을 주장하는지 알려줄 뿐, 신뢰할 수 있는지는 알려주지 않습니다. Encode는 여러분이 준 secret과 알고리즘으로 실제로 서명합니다(gori에서 처음이자 유일한 HMAC).

## 공격 페이로드 {#attack-payloads}

디코드된 토큰에서 gori는 흔한 JWT 검증 결함을 찔러보는, 바로 전송 가능한 변형을 생성합니다:

| 공격 | 무엇을 테스트하는가 |
|--------|---------------|
| **alg:none** | signature를 제거하고 `alg`를 `none`으로 설정합니다(그리고 `None` / `NONE` 대소문자 변형 포함). 서명 없는 토큰을 받아들이는 서버를 겨냥합니다. |
| **Weak secret** | 흔한 약한 HMAC secret 목록으로 토큰을 재서명해, 추측 가능한 서명 키를 잡아냅니다. |
| **Header injection** | `kid`, `jku`, `x5u`, `jwk` header 파라미터를 조작합니다. 공격자가 제공한 키 자료를 신뢰하는 서버를 겨냥합니다. |

후보를 **Repeater**로 보내 대상을 상대로 시도하거나, 이미 편집 중인 요청에 곧바로 넣으세요.

## 헤드리스 {#headless}

```bash
gori run jwt eyJhbGci...                       # decode (default)
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
gori run jwt eyJhbGci... --attacks             # print the attack payloads
cat token.txt | gori run jwt --attacks         # token from stdin
```

토큰은 인자나 stdin에서 옵니다. 프로젝트나 캡처는 관여하지 않습니다(순수한 로컬 연산입니다). `--format`은 `text` 또는 `json`입니다. [CLI Reference](/ko/reference/cli/#run-jwt)를 참고하세요.

MCP에서는 `jwt_decode` / `jwt_encode` / `jwt_attacks`가 네트워크나 상태를 건드리지 않으므로 `--read-only`에서도 사용할 수 있는 read 도구입니다.

## 다음 단계 {#next-steps}

- [Decoder](/ko/guide/decoder/): 더 긴 변환 체인 안에서 JWT를 디코드합니다
- [Sequencer](/ko/guide/sequencer/): JWT가 아닌 토큰의 무작위성을 평가합니다
- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): 공격 페이로드를 대상에 발사합니다
