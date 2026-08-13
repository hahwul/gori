+++
title = "세션 쿠키 크랙과 위조"
description = "서명된 Flask, Rack, Django 쿠키를 읽고, 그것을 서명하는 비밀키를 복구하고, 직접 만들어 냅니다."
weight = 80

[extra]
group = "워크벤치"
+++

서명된 세션 쿠키는 서버가 클라이언트가 바꿀 수 있는 값을 신뢰하지 않게 막습니다 — 서명 비밀키가 비밀로 남아 있는 한요. 이 플레이북은 캡처한 Flask, Rack, Django 쿠키를 읽고, 후보 비밀키를 대조하고, 그것을 서명하는 비밀키를 무차별 대입으로 찾고, 당신이 고른 클레임을 담아 쿠키를 다시 서명한 뒤, 서버가 그 위조를 받아들이는지 재생해 확인합니다. 약 10분에, 워드리스트 실행 시간을 더하세요.

gori의 TUI에는 쿠키 탭이 없습니다. 전체 워크플로우는 `gori run cookie` 서브커맨드 — 스토어 없는 로컬 연산으로, 쿠키는 인수나 stdin에서 받습니다 — 와 네 개의 MCP 도구입니다. 아래 내용은 모두 셸에서 실행됩니다.

> **시작하기 전에.** gori를 프록시로 실행해 두고, 서명된 세션 쿠키를 설정하는 응답을 캡처하세요 — 로그인 응답의 `Set-Cookie` 헤더가 흔한 출처입니다. 크랙 단계에는 후보 비밀키 워드리스트(한 줄에 하나)도 필요합니다. 공격 권한이 있는 호스트의 쿠키만 테스트하세요. 예시는 `api.example.com`을 대상으로 합니다.

## 1. 쿠키 디코드 {#1-decode-the-cookie}

캡처한 응답의 `Set-Cookie` 헤더에서 쿠키 값을 복사해 디코드합니다. 디코드는 키 없이도 쿠키를 **payload**, **timestamp**, **signature**로 파싱하므로, 캡처한 어떤 쿠키에도 동작합니다. gori가 프레임워크를 자동 감지하거나 — **Flask**, **Rack**, **Django** — `--type`으로 고정할 수 있습니다:

```bash
gori run cookie 'eyJ1c2VyIjoi...'                 # decode is the default; framework auto-detected
gori run cookie 'eyJ1c2VyIjoi...' --type flask    # force the format
```

MCP에서는 `cookie_decode` 도구입니다. 디코드는 쿠키가 *주장하는* 바를 드러낼 뿐 서명을 검사하지는 않습니다 — 세션의 내용을 알려 줄 뿐, 서버가 그것을 신뢰할지는 알려 주지 않습니다.

**체크포인트.** 디코드된 payload, 그 timestamp, signature가 출력됩니다.

## 2. 후보 비밀키로 검증 {#2-verify-against-a-candidate-secret}

비밀키에 대한 짐작이 있다면 — 프레임워크 기본값, 재사용된 키, 소스에서 뽑은 값 — 워드리스트를 쓰기 전에 확인하세요. 검증은 하나의 비밀키를 쿠키의 서명에 대조합니다:

```bash
gori run cookie 'eyJ1c2VyIjoi...' --verify --secret hunter2
```

MCP에서는 `cookie_verify`입니다. 하나의 질문에 답합니다. 이 비밀키가 이 서명을 만들어 내는가?

**체크포인트.** 검증이 후보 비밀키가 그 쿠키를 서명하는지 여부를 보고합니다.

## 3. 비밀키 크랙 {#3-crack-the-secret}

비밀키를 모를 때는 무차별 대입합니다. 크랙은 각 후보로 쿠키를 다시 서명해 서명이 일치하는 것에서 멈추며, 후보는 줄바꿈으로 구분된 파일(`--wordlist`)이나 쉼표로 구분된 목록(`--secrets`)에서 가져옵니다:

```bash
gori run cookie 'eyJ1c2VyIjoi...' --crack --wordlist secrets.txt
gori run cookie 'eyJ1c2VyIjoi...' --crack --secrets 'dev,changeme,secret'
```

MCP에서는 `cookie_crack`입니다. 검증과 같은 원리를 목록 전체에 걸쳐 돌리는 것이라 — 워드리스트의 질이 승부의 전부입니다.

**체크포인트.** 복구된 비밀키가 출력되거나, 그 비밀키가 목록에 없었다고 보고됩니다.

## 4. 직접 위조하기 {#4-forge-your-own}

비밀키를 손에 쥐면, 당신이 고른 클레임과 서버가 받아들일 유효한 서명을 담은 쿠키를 만듭니다. 위조는 payload를 비밀키로 다시 서명하며, 형태는 프레임워크에 달려 있습니다:

```bash
gori run cookie --forge --type flask  --secret s3cret --payload '{"user":"admin"}'
gori run cookie --forge --type django --secret s3cret --payload '{"user":"admin"}' --salt <salt> --algorithm sha256
gori run cookie --forge --type rack   --secret s3cret --value <base64-marshal>
```

Flask와 Django에서는 `--payload`가 서명할 세션 JSON입니다. Django는 `--salt`와 `--algorithm`(`sha256` 기본, 또는 `sha1`)도 받습니다. Rack은 `--payload` 대신 `--value`로 넘기는 불투명한 Base64 Marshal 블롭을 서명합니다. 지금이 아닌 특정 초를 찍으려면 `--timestamp=UNIX`를 더하세요. MCP에서는 `cookie_forge`입니다.

위조한 쿠키를 **Repeater**로 가져가세요. 인증이 필요한 엔드포인트에서 요청의 `Cookie` 헤더로 설정하고 `Ctrl-R`로 다시 보냅니다. 서버가 당신이 위조한 세션을 — 관리자 화면, 다른 사용자의 데이터를 — 돌려주면, 당신의 서명을 신뢰한 것입니다.

**체크포인트.** 서버가 위조한 쿠키를 받아들여, 당신이 고른 클레임에 대한 인증된 응답을 돌려줍니다.

## 다음 단계 {#next-steps}

- [토큰 무작위성 평가](/ko/playbooks/grade-token-randomness/): 토큰이 서명되지 않았다면, 대신 예측 가능한지 시험하기
- [CLI Reference](/ko/reference/cli/#run-cookie): `--salt`, `--algorithm`, `--timestamp`을 포함한 `gori run cookie`의 모든 플래그
- [JWT 공격](/ko/playbooks/attack-a-jwt/): 서명된 JSON Web Token을 위한 자매 워크플로우
