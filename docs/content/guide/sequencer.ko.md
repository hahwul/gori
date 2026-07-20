+++
title = "Sequencer"
description = "세션 token, CSRF token, 리셋 코드의 무작위성을 예측 가능성 관점에서 등급 매기기."
weight = 60

[extra]
group = "워크벤치"
+++

session cookie, CSRF token, 비밀번호 리셋 코드, API key가 예측 가능하다면 공격자는 그것을 위조하거나 추측할 수 있습니다. **Sequencer**는 token 샘플을 수집해 실제로 얼마나 무작위한지 등급을 매깁니다. Burp Sequencer나 Caido Sequencer에 대응하는 gori의 도구입니다.

<figure class="tui-shot">
  <img src="/images/tui/sequencer.svg" alt="History 탭 위에 뜬 gori Send to Sequencer 설정 카드: 자동 감지된 session cookie 토큰, 샘플 수 500, concurrency 1">
  <figcaption>캡처한 플로우를 <strong>Sequencer</strong>로 보내면 session cookie를 자동으로 감지하고, 수집을 시작하기 전에 샘플 크기와 concurrency를 설정할 수 있습니다.</figcaption>
</figure>

**Sequencer** 탭은 기본적으로 숨겨져 있습니다. 탭 바의 `⋯` 메뉴나 커맨드 팔레트(`Ctrl-P` → **Go to Sequencer**)에서 드러내세요.

## 토큰을 넣는 두 가지 방법 {#two-ways-to-feed-it}

**라이브.** 새 token을 발급하는 요청을 지정하면, gori가 그 요청을 여러 번 재전송하면서 각 응답에서 token을 뽑아냅니다. **History**에서 token을 설정하는 플로우를 선택하고 `Space` → **Send to Sequencer**를 고르면, gori가 유력한 session cookie를 자동으로 감지합니다. `c`(재설정)로 token 위치와 샘플 크기를 조정한 뒤, `Ctrl-R`로 수집을 시작하고 `Ctrl-X`로 멈춥니다.

**수동.** 이미 token 목록이 있나요? 한 줄에 하나씩 붙여넣으면 네트워크 트래픽 없이 순수하게 통계 분석만 수행합니다.

다음 위치 중 어디에서든 token을 추출할 수 있습니다:

| Location | 추출 대상 |
|----------|----------|
| Cookie | 이름으로 지정한 `Set-Cookie` 값 |
| Header | 응답 헤더 값 |
| Regex | 본문 regex의 캡처 그룹 1 |
| Position | 본문의 고정 바이트 범위(`A:B`) |
| JSONPath | JSON 본문 경로의 값(`$.data.token`) |

라이브 수집의 기본 **concurrency는 1**입니다. session token은 종종 상태를 가지기 때문입니다(각 요청이 서버 측 카운터를 진행시킴). 엔드포인트가 stateless일 때만 값을 올리세요.

## 등급 읽기 {#reading-the-grade}

핵심 지표는 bit 단위의 **effective entropy**입니다. 각 token이 실제로 지닌 예측 불가능성의 양을 샘플 전체에 걸쳐 측정한 보수적인 추정치입니다. 등급은 여기서 도출됩니다:

| Rating | Effective entropy |
|--------|-------------------|
| **Secure** | >= 88 bits |
| **Moderate** | >= 60 bits |
| **Weak** | >= 30 bits |
| **Critical** | below 30 bits |

**중복**되거나 **순차적인** token이 하나라도 있으면 entropy가 아무리 높아 보여도 판정이 곧바로 Critical로 떨어집니다. 내부적으로 gori는 일련의 통계 테스트(monobit, poker, runs, longest-run, 그리고 token의 심볼 bitstream에 대한 per-bit 편향)와, 알파벳의 entropy 하한과 대조하는 압축 검사, per-position 문자 분포를 실행합니다. 샘플이 작으면(사용 가능한 token이 약 20개 미만) 확실히 판단할 데이터가 부족하므로, 강한 실패를 경고로 완화하고 등급의 상한을 제한합니다.

패널은 **CONFIG**(소스와 token 위치), **SAMPLES**(수집된 token), **ANALYSIS**(등급과 테스트별 분석)로 구성되며, 개별 샘플에 대한 상세 보기가 함께 제공됩니다.

## 헤드리스 {#headless}

```bash
# Live: replay flow 42, extract the SESSIONID cookie, collect 500 tokens
gori run sequence 42 --cookie SESSIONID --count 500

# Manual: analyze tokens you already have (no network)
gori run sequence --tokens tokens.txt
cat tokens.txt | gori run sequence --tokens -
```

token 위치는 정확히 하나만 고르고(`--cookie` / `--header` / `--regex` / `--position` / `--jsonpath`), 요청은 `--flow`, `--request FILE`, 또는 stdin에서 가져옵니다. 속도 및 전송 관련 플래그는 Fuzzer와 동일합니다(`--concurrency`, `--rate`, `--throttle`, `--timeout`, `--target`, `--http2`, …). 출력 형식은 `text`, `json`, `jsonl`입니다. 전체 플래그는 [CLI Reference](/ko/reference/cli/#run-sequence)에 있습니다.

MCP에서는 `sequence_analyze`가 token 목록을 인라인으로 등급 매기고, `sequence_start` / `sequence_status` / `sequence_results` / `sequence_stop`이 라이브 수집을 백그라운드 작업으로 구동합니다. 결과는 항상 **리포트**를 반환하며 raw token은 절대 반환하지 않습니다.

## 다음 단계 {#next-steps}

- [Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/): token을 발급하는 요청을 캡처합니다
- [JWT](/ko/guide/jwt/): token이 JWT라면 대신 디코드하고 공격합니다
- [MCP Server](/ko/guide/mcp/): 에이전트에서 token 등급을 매깁니다
