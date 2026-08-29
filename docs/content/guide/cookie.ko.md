+++
title = "Cookie"
description = "Flask, Rack, Django의 서명된 세션 쿠키를 디코드, 검증, 크랙, 재서명합니다."
weight = 55

[extra]
group = "워크벤치"
+++

**Cookie** 탭은 프레임워크가 서명한 세션 쿠키를 위한 워크벤치입니다 — **Flask**(itsdangerous), **Rack**, **Django**. 쿠키를 파트로 디코드하고, 후보 서명 secret을 검증하거나 워드리스트로 브루트포스한 뒤, 세션을 편집해 재서명합니다. 파트를 보여주기만 하는 [Decoder](/ko/guide/decoder/)의 읽기 전용 `cookie-decode` / `flask-decode` / `rack-decode` / `django-decode` 컨버터보다 한 걸음 더 나아갑니다.

어디서든(예: **History** 상세 패널, **Notes** 등) 쿠키를 선택하고 `Space` → **Send to Cookie**를 누르면 그 쿠키로 새 워크벤치 서브탭을 채웁니다. 세션은 휘발성이라 디스크에는 아무것도 기록되지 않습니다. 탭을 숨겼다면 탭 바의 `⋯` 메뉴, 커맨드 팔레트(`Ctrl-P` → **Go to Cookie**), 또는 Preferences에서 다시 드러내세요.

## 두 개의 렌즈 {#two-lenses}

하나의 세션, 두 개의 뷰이며 `Ctrl-T`로 전환합니다. 각 렌즈의 최상위 카드 테두리에 전환 칩이 있습니다 — INPUT에는 ` ^T:→FORGE `, PAYLOAD에는 ` ^T:→DECODE ` — 클릭해도 키와 똑같이 동작합니다:

- **Decode**: INPUT에 쿠키를 붙여 넣으면 파트가 DECODED에 실시간으로 디코드됩니다. **OPTIONS**는 읽는 방식을 고정합니다 — 포맷(`Ctrl-A`로 `auto` / `flask` / `rack` / `django` 순환, `auto`는 문장 부호로 감지), Django HMAC 알고리즘, 서명 salt. **SECRET**은 후보 키를 담으며, 입력하는 동안 검증 결과(`✓ verified` / `✗ bad key`)가 실시간으로 표시됩니다. `c`를 누르면 크랙합니다(아래 참고).
- **Forge**: PAYLOAD에서 세션을 편집하고(Flask/Django는 JSON 객체, Rack은 불투명한 base64 값), SECRET을 설정하면 재서명된 쿠키가 OUTPUT에 실시간으로 나타납니다.

`l`을 누르면 현재 Decode 쪽에서 디코드된 payload를 Forge 편집기로 불러옵니다. 그래서 값 하나를 손보고 두 동작만으로 재서명할 수 있습니다. 결과는 `y`로(위조된 쿠키는 `t`로) 복사하세요.

> 디코드는 하지만 검증은 하지 않는 [JWT](/ko/guide/jwt/) 탭과 달리, Cookie에는 secret 경로가 있습니다. SECRET의 `✓`는 입력한 키가 실제로 이 쿠키를 서명한다는 뜻입니다. Forge는 지정한 secret, salt, 알고리즘으로 실제로 재서명합니다.

## 세 가지 포맷 {#the-three-formats}

| 포맷 | 형태 | 서명 |
|--------|-------|-----------|
| **Flask** | `value.timestamp.signature` | itsdangerous HMAC(값 앞의 `.`는 zlib 압축 표시). |
| **Rack** | `base64--40자리 hex` | Base64-Marshal 값 + HMAC-SHA1. 값이 불투명한 바이트라 Forge는 JSON이 아니라 base64로 받습니다. |
| **Django** | `value:timestamp:signature` | `django.core.signing`, salt가 섞인 HMAC. **세션** 쿠키는 기본이 아닌 salt로 서명합니다 — 아래 참고. |

## secret 크랙 {#cracking-the-secret}

**SECRET** 필드는 `c`(크랙)의 소스를 겸하므로, 별도 프롬프트가 없습니다:

- **파일 경로**는 워드리스트로 읽습니다(한 줄에 후보 하나);
- **콤마로 구분된 목록**(`admin,secret,changeme`)은 인라인으로 시도합니다;
- **단일 secret**은 원소가 하나인 목록입니다 — 실시간 검증과 같은 검사를 크랙으로 표현한 것입니다.

성공하면 필드가 찾아낸 secret으로 바뀌고 결과가 `✓`로 뒤집혀, 그대로 Forge 렌즈로 이어갈 수 있습니다.

> Django **세션** 쿠키(`django.contrib.sessions`)는 기본이 아닌 salt로 서명되므로, 기본 salt로 크랙하면 실패합니다. **OPTIONS**에서 salt를 먼저 설정하세요 — 세션 쿠키라면 `django.contrib.sessions.backends.signed_cookies`입니다. CLI의 `--salt`도 마찬가지입니다.

## 헤드리스 {#headless}

```bash
gori run cookie eyJ1c2Vy...                                  # 디코드 (자동 감지, 기본)
gori run cookie eyJ1c2Vy... --verify --secret s3cret         # 이 secret이 서명하는가?
gori run cookie eyJ1c2Vy... --crack --wordlist words.txt     # secret 브루트포스
gori run cookie eyJ1c2Vy... --crack --secrets a,b,s3cret     # …또는 인라인 목록
gori run cookie --forge --type flask --payload '{"admin":true}' --secret s3cret
cat cookie.txt | gori run cookie                             # stdin에서 쿠키
```

쿠키는 인자나 stdin에서 옵니다. 프로젝트나 캡처는 관여하지 않습니다(순수 로컬 연산). `--type`은 포맷을 고정하고(기본: 자동 감지), `--salt`와 `--algorithm`은 Django/Flask 노브를 전달하며, `--format`은 `text` 또는 `json`입니다. Flask/Django `--forge`는 `--payload` JSON을, Rack은 불투명한 `--value`를 받습니다. [CLI 레퍼런스](/ko/reference/cli/#run-cookie)를 참고하세요.

MCP에서는 `cookie_decode` / `cookie_verify` / `cookie_crack` / `cookie_forge`가 네트워크나 상태를 건드리지 않는 읽기 도구라, `--read-only`에서도 사용할 수 있습니다.

## 다음 단계 {#next-steps}

- [JWT](/ko/guide/jwt/): JSON Web Token을 위한 형제 워크벤치
- [Decoder](/ko/guide/decoder/): 더 긴 변환 체인 안에서 쿠키 디코드
- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): 위조한 쿠키를 대상에 발사
