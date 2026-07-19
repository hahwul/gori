+++
title = "Repeater & Fuzzer"
description = "요청 워크벤치와 Intruder 스타일 Fuzzer를, TUI와 헤드리스에서 다룹니다."
+++

흥미로운 플로우를 캡처했다면, **Repeater**와 **Fuzzer**가 그 플로우를 테스트하는 곳입니다.

## Repeater {#repeater}

Repeater는 요청 워크벤치입니다. 플로우를 보내고, 요청의 어느 부분이든 편집한 뒤, 다시 보냅니다. 응답, 소요 시간, 이전 응답과의 diff가 나란히 표시됩니다. 세션은 프로젝트와 함께 유지되므로 나중에 다시 돌아올 수 있습니다.

<figure class="tui-shot">
  <img src="/images/tui/repeater.svg" alt="편집 가능한 HTTP/2 요청 패널, 헤더와 JSON 본문을 보여주는 응답 패널, 그리고 1152ms 만에 재전송된 200 상태 줄을 갖춘 gori Repeater 탭">
  <figcaption><strong>Repeater</strong>: 왼쪽에 편집 가능한 요청, 오른쪽에 실시간 응답과 소요 시간, 이전 전송과의 diff.</figcaption>
</figure>

Repeater는 HTTP/1 이상을 다룹니다.

- **HTTP/2** 요청은 실제 h2 연결로 재전송됩니다.
- **WebSocket** 리피터는 핸드셰이크를 열고, 메시지를 보내며, 흘러나오는 응답을 지켜봅니다.
- **gRPC** 리피터는 프레이밍된 메시지를 위해 HTTP/2 엔진을 재사용합니다.
- **decode** 모드는 편집된 SAML / GraphQL 페이로드를 전송 시 다시 인코드합니다. (JWT를 디코드하거나 편집하려면 [Decoder](/ko/guide/decoder/) 탭의 `jwt-decode`를 사용하세요.)

명령줄에서 Repeater를 실행하고, 선택적으로 새 대상을 지정할 수 있습니다.

```bash
gori run repeater <flow-id> --target https://staging.example.com --diff
```

## 환경 변수 {#environment-variables}

아웃바운드 요청은 `$KEY` 스타일 치환을 지원합니다. 토큰은 에디터에서 리터럴 텍스트로 남아 있다가, Repeater, Fuzzer, Miner, Intercept 포워드, `gori run`, MCP `send_request`에서 전송 시점에만 확장됩니다.

변수는 두 곳에서 정의합니다(키 충돌 시 프로젝트가 우선).

| 레이어 | 위치 |
|-------|-------|
| **Global** | Preferences(`Ctrl-,`) → **Editor & Keys** → **Env**, `Ctrl-P` → **Settings: Env**, 또는 `settings.json`의 `env` 섹션 |
| **Project** | **Project** 탭 → **ENV** 패널 (`a` 추가, `e` 편집, `d` 삭제) |

기본 접두사는 `$`입니다(ENV space 메뉴의 **Change prefix**나 설정의 `env.prefix`로 변경 가능). 키는 `A-Z a-z _`로 시작해 `A-Z a-z 0-9 _`가 이어집니다. 알 수 없는 토큰은 그대로 둡니다.

```http
GET /api/me HTTP/1.1
Host: api.example.com
Authorization: Bearer $TOKEN
```

캡처된 트래픽에 나타나는 값은 복사하거나 표시할 때 다시 `$KEY`로 마스킹할 수 있어, 비밀 값이 원시 문자열이 아니라 토큰으로 유지됩니다.

## Fuzzer {#fuzzer}

Fuzzer는 Intruder 스타일 엔진입니다. 요청에서 위치를 표시하고, 페이로드 세트를 붙이고, 응답을 매칭하면서 요청 행렬을 전송합니다.

<figure class="tui-shot">
  <img src="/images/tui/fuzzer.svg" alt="강조된 마커 위치를 보여주는 요청 템플릿, 페이로드 세트 설정 패널, 전송된 요청 결과 테이블, 분포 사이드바를 갖춘 gori Fuzzer 탭">
  <figcaption><strong>Fuzzer</strong>: 템플릿의 <code>§…§</code> 마커, CONFIG의 페이로드 세트와 모드, 실시간 결과 테이블, 상태 / 크기 분포 사이드바.</figcaption>
</figure>

### 공격 모드 {#attack-modes}

| 모드 | 동작 |
|------|----------|
| `sniper` | 한 번에 한 위치씩, 단일 페이로드 세트를 순환 (기본값) |
| `batteringram` | 표시된 모든 위치에 같은 페이로드 |
| `pitchfork` | 병렬 세트: 각 세트의 *n* 번째 페이로드를 함께 |
| `clusterbomb` | 모든 세트에 걸친 모든 조합 |

### 위치와 페이로드 {#positions-and-payloads}

요청에서 `§…§` 마커로 위치를 표시하거나, gori가 자동으로 배치하게 하세요. 페이로드 세트는 워드리스트, 명시적 목록, 숫자 범위, N개의 빈(null) 페이로드, 또는 무차별 대입 문자 세트가 될 수 있습니다. 프로세서를 사용하면 나가는 각 페이로드를 변환할 수 있습니다: prefix/suffix, URL/base64/hex 인코딩, 대소문자 변환, 해싱, 정규식 치환.

### 매칭 {#matching}

ffuf 스타일 matcher와 filter로 status, size, words, lines, 본문 정규식에 대해 결과를 필터링합니다. 여기에 시끄러운 기준선을 걸러내는 자동 보정까지 더해집니다. 매칭된 응답은 강조되며 캡처 정규식으로 추출할 수 있습니다.

### 헤드리스 실행 {#running-headless}

```bash
gori run fuzz <flow-id> \
  --auto \
  --wordlist params.txt \
  --mode sniper \
  --mc 200,302 \
  --fs 0
```

소스는 캡처된 플로우(`--flow`), 원시 요청 파일(`--request`), 또는 stdin이 될 수 있습니다. 출력은 `text`, `json`, `jsonl`입니다.

## 다음 단계 {#next-steps}

- [Decoder](/ko/guide/decoder/): 로컬 인코드/디코드/해시 체인
- [Scanning & Issues](/ko/guide/scanning/): Probe와 Param Miner
- [CLI Reference](/ko/reference/cli/): 모든 `run` 플래그
- [MCP Server](/ko/guide/mcp/): 에이전트로 퍼징 구동
