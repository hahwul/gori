+++
title = "JWT"
description = "JSON Web Token을 HMAC과 비대칭 알고리즘 전반에서 디코드·검증·편집·재서명하고, alg:none, weak-secret, header-injection, algorithm-confusion 페이로드를 생성합니다."
weight = 50

[extra]
group = "워크벤치"
+++

**JWT** 탭은 JSON Web Token을 위한 워크벤치입니다. 토큰을 디코드하고, claim을 편집해 재서명하며, 서버를 상대로 테스트할 고전적인 공격 페이로드를 생성합니다. 파트를 보여주기만 하는 [Decoder](/ko/guide/decoder/)의 읽기 전용 `jwt-decode` 컨버터보다 한 걸음 더 나아갑니다.

<figure class="tui-shot">
  <img src="/images/tui/jwt.svg" alt="디코드된 HS256 토큰을 보여주는 gori JWT 탭: ^T:→ENCODE 렌즈 칩이 달린 INPUT 토큰, 디코드된 header JSON, 그리고 alg=none 대소문자 변형과 signature 제거를 포함한 23개 공격 페이로드의 ATTACKS 목록">
  <figcaption><strong>JWT</strong> 탭은 토큰을 실시간으로 디코드하고(header, payload, signature), 바로 보낼 수 있는 공격 페이로드(alg:none, weak-secret, header injection)를 나열합니다.</figcaption>
</figure>

어디서든(예: **History** 상세 패널, **Notes** 등) 토큰을 선택하고 `Space` → **Send to JWT**를 누르면 그 토큰으로 새 워크벤치 서브탭을 채웁니다. 세션은 휘발성이라 디스크에는 아무것도 기록되지 않습니다. 탭을 숨겼다면 탭 바의 `⋯` 메뉴, 커맨드 팔레트(`Ctrl-P` → **Go to JWT**), 또는 Preferences에서 다시 드러내세요.

## 두 개의 렌즈 {#two-lenses}

하나의 세션, 두 개의 뷰이며 `Ctrl-T`로 전환합니다. 각 렌즈의 최상위 카드 테두리에 전환 칩이 있습니다(INPUT에는 ` ^T:→ENCODE `, HEADER에는 ` ^T:→DECODE `). 클릭해도 키와 똑같이 동작합니다:

- **Decode**: INPUT에 토큰을 붙여 넣으면 header, payload, signature가 실시간으로 디코드됩니다. 그 아래에는 생성된 **공격 페이로드**를 고를 수 있는 목록이 있습니다.
- **Encode**: HEADER와 PAYLOAD를 JSON으로 편집하고, 알고리즘을 선택하며(`Ctrl-A`로 HMAC 계열 → `RS`/`PS`/`ES`의 256/384/512 → `EdDSA` → `none` 순환), SECRET을 설정하면 재서명된 토큰이 OUTPUT에 실시간으로 나타납니다. 비대칭 알고리즘에서는 카드가 **KEY**로 바뀌며, 입력한 시크릿 대신 PEM 개인키 경로를 받습니다.

`Space` → **Load decoded claims**는 현재 Decode 쪽에서 디코드된 토큰을 Encode 편집기로 불러옵니다. 그래서 claim 하나를 손보고 두 동작만으로 재서명할 수 있습니다. 결과는 `y`로 복사하세요.

> signature는 디코드되어 표시되지만 **Decode 쪽에서는 검증되지 않습니다**. 따라서 디코드는 토큰이 무엇을 주장하는지 알려줄 뿐, 신뢰할 수 있는지는 알려주지 않습니다. Encode는 지정한 키와 알고리즘으로 실제로 서명하고, 키를 가지고 있다면 `gori run jwt --verify`(또는 MCP `jwt_verify`)가 신뢰 여부에 답합니다.

## 알고리즘 {#algorithms}

HMAC(`HS256` / `HS384` / `HS512`)은 직접 입력한 시크릿으로 서명합니다. 비대칭 계열은 사용자가 제공한 PEM 키로 서명합니다 — gori는 키를 만들지 않으므로, `RS256` 토큰을 위조하려면 여전히 `RS256` 개인키가 필요합니다:

| 계열 | 알고리즘 | 키 |
|--------|------------|-----|
| **HMAC** | `HS256` `HS384` `HS512` | 공유 시크릿을 그대로 입력 |
| **RSA PKCS#1** | `RS256` `RS384` `RS512` | 서명은 RSA 개인키, 검증은 공개키 / 인증서 |
| **RSA-PSS** | `PS256` `PS384` `PS512` | 같은 RSA 키. salt 길이는 다이제스트 길이(RFC 7518 §3.5) |
| **ECDSA** | `ES256` `ES384` `ES512` | P-256 / P-384 / P-521 키. 서명은 JOSE가 규정한 고정 폭 `r‖s` 형식이라 `ES512`는 128이 아니라 132바이트입니다 |
| **EdDSA** | `EdDSA` | Ed25519 키 |
| **미서명** | `none` | 키 없음 — 의도적으로 제공하는 인증 우회 형태 |

키는 PEM 본문을 그대로 넣거나 `.pem` 파일 경로로 지정합니다. 검증에는 X.509 **인증서**(IdP가 `x5c`로 공개하는 것)나 개인키 자체도 받습니다.

## 암호화된 토큰(JWE) {#jwe}

`header.encrypted_key.iv.ciphertext.tag` 형태의 5-세그먼트 토큰은 **JWE**, 즉 암호화된 JWT입니다. gori는 JWS를 인식하는 모든 곳(JWT 탭, Decoder, 본문 pretty-printer, `gori run jwt`, MCP `jwt_decode`)에서 JWE도 인식하고 **보호 헤더**를 보여줍니다: 콘텐츠 암호화 키를 감싼 `alg`, 클레임을 암호화한 `enc`, 그리고 `kid`.

gori는 복호화하지 **않습니다**. 키가 없으면 클레임은 암호화됨으로 표시되고 그 자리에 아무것도 추측해 넣지 않으며, 클레임 위에서만 의미가 있는 투영은 토큰을 아예 거부합니다: `--attacks`는 아무것도 생성하지 않고(조작할 클레임 세그먼트도, 제거할 서명도 없습니다), `--verify`는 지원하지 않는 알고리즘이라고 말하는 대신 그 사실을 그대로 알려줍니다.

## 공격 페이로드 {#attack-payloads}

디코드된 토큰에서 gori는 흔한 JWT 검증 결함을 찔러보는, 바로 전송 가능한 변형을 생성합니다:

| 공격 | 무엇을 테스트하는가 |
|--------|---------------|
| **alg:none** | signature를 제거하고 `alg`를 `none`으로 설정합니다(그리고 `None` / `NONE` / `nOnE` 대소문자 변형 포함). 서명 없는 토큰을 받아들이는 서버를 겨냥합니다. 원래 header를 유지하는 페이로드가 둘 더 있습니다: **signature stripped**(세 번째 세그먼트가 빈 토큰)와 **no signature segment**(세그먼트가 둘뿐인 토큰). |
| **Weak secret** | 흔한 약한 HMAC secret 목록으로 토큰을 재서명해, 추측 가능한 서명 키를 잡아냅니다. |
| **Header injection** | `kid`, `jku`, `x5u`, `jwk` header 파라미터를 조작합니다. 공격자가 제공한 키 자료를 신뢰하는 서버를 겨냥합니다. |
| **Algorithm confusion** | 서버의 공개키를 줬을 때만 생성됩니다(`--attacks --key`, MCP `public_key`). `RS`/`PS`/`ES` 토큰을 `HS256`으로 낮추고 공개키 바이트 자체를 HMAC 키로 써서 서명합니다. 토큰의 `alg`로 분기하면서 검증 키를 그대로 재사용하는 서버를 겨냥합니다. 서버가 가지고 있을 법한 표기마다 페이로드를 하나씩 만듭니다: OpenSSL이 쓰는 정규 SPKI PEM, 그리고 준 그대로의 바이트를 끝 개행 있는 형태와 없는 형태로. |

후보를 **Repeater**로 보내 대상을 상대로 시도하거나, 이미 편집 중인 요청에 곧바로 넣으세요.

## 헤드리스 {#headless}

```bash
gori run jwt eyJhbGci...                       # decode (default)
gori run jwt eyJhbGci... --encode --alg HS256 --secret s3cret
gori run jwt eyJhbGci... --encode --set role=admin --secret s3cret   # claim 하나를 패치해 재서명
gori run jwt eyJhbGci... --encode --payload '{"sub":"1","admin":true}' --secret s3cret   # claim 전체를 교체
gori run jwt eyJhbGci... --encode --alg ES256 --key ./private.pem     # 비대칭 키로 서명
gori run jwt eyJhbGci... --verify --key ./public.pem                  # 이 토큰은 유효한가?
gori run jwt eyJhbGci... --attacks             # print the attack payloads
gori run jwt eyJhbGci... --attacks --key ./public.pem                 # ...algorithm confusion까지
cat token.txt | gori run jwt --attacks         # token from stdin
```

토큰은 인자나 stdin에서 옵니다. 프로젝트나 캡처는 관여하지 않습니다(순수한 로컬 연산입니다). `--format`은 `text` 또는 `json`입니다. `--encode`에서 `--set KEY=VALUE`는 claim 하나를 패치하고(반복 가능. 값이 JSON으로 파싱되면 그 타입을 유지하므로 `admin=true`는 불리언, `role=admin`은 문자열입니다), `--payload JSON`은 claim 객체 전체를 교체합니다. 둘은 상호 배타적입니다. `--secret`과 `--key`는 같은 자리를 채우므로 하나만 넘기세요. `--verify`는 `verified: yes|no`를 출력하고 어느 쪽이든 0으로 종료합니다 — "no"도 답이므로 스크립트는 종료 코드가 아니라 이 필드를 읽어야 합니다. [CLI Reference](/ko/reference/cli/#run-jwt)를 참고하세요.

MCP에서는 `jwt_decode` / `jwt_verify` / `jwt_encode` / `jwt_attacks`가 `--read-only`에서도 사용할 수 있는 read 도구입니다. 네트워크를 건드리지 않고 아무것도 쓰지 않습니다. `jwt_encode`도 같은 `set` / `payload` claim 편집과 같은 `key`를 받고, `jwt_attacks`는 `public_key`를 받습니다. 다만 `key` / `public_key`는 **경로**도 받으므로 이 두 인자는 호출자가 지정한 파일을 읽습니다 — 클라이언트가 파일시스템에 닿지 않아야 한다면 PEM을 인라인으로 넘기세요.

## 다음 단계 {#next-steps}

- [Decoder](/ko/guide/decoder/): 더 긴 변환 체인 안에서 JWT를 디코드합니다
- [Sequencer](/ko/guide/sequencer/): JWT가 아닌 토큰의 무작위성을 평가합니다
- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): 공격 페이로드를 대상에 발사합니다
