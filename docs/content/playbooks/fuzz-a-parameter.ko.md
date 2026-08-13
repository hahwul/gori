+++
title = "파라미터 퍼징"
description = "캡처한 요청의 한 부분을 표시하고, 워드리스트를 던지고, 튀는 응답을 읽어 냅니다."
weight = 40

[extra]
group = "수동 루프"
+++

밀어붙여 볼 파라미터가 담긴 캡처한 요청이 하나 있습니다. 이 플레이북은 그 요청에서 값 하나를 표시하고, 그 한 지점에 페이로드 세트를 던진 뒤, 다르게 동작하는 응답 하나를 찾아 읽습니다. Intruder 스타일 루프 전체를 TUI에서, 그리고 헤드리스로 다룹니다. 약 10분 잡으세요.

> **시작하기 전에.** 먼저 [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)를 끝내 대상에 스코프를 잡아 두세요 — Fuzzer는 스코프 밖 호스트를 `SCOPE_BLOCKED`로 거부합니다. **History**에 파라미터를 담은 캡처 플로우가 하나 있어야 합니다: 쿼리 키, JSON 필드, 헤더 중 무엇이든요. 테스트 권한이 있는 대상만 퍼징하세요. 예시는 `api.example.com`을 대역으로 씁니다.

## 1. Fuzzer로 요청 보내기 {#1-send-a-request-to-the-fuzzer}

모든 것은 실제로 캡처된 요청에서 시작합니다. 그래야 손으로 어림잡은 근사치가 아니라 앱이 실제로 보낸 바이트 그대로를 퍼징합니다. **History**에서 파라미터를 담은 플로우를 선택하고 `Shift-I`를 누르세요. gori가 이를 **Fuzzer** 탭으로 복사하고 그리로 전환합니다 — `Ctrl-R`로 Repeater에 보내는 것과 같은 동작이며, 탭 하나 더 뒤입니다. 헤드리스에서는 플로우 id가 소스입니다:

```bash
gori run fuzz <flow-id>
```

소스는 원시 요청 파일(`--request`)이나 stdin일 수도 있지만, 캡처한 플로우는 실행을 프로젝트 스코프 안에 공짜로 묶어 둡니다.

**체크포인트.** **Fuzzer** 탭에 요청 복사본이 템플릿으로 담기며, 표시하기 전까지는 그대로입니다.

## 2. 위치 표시하기 {#2-mark-a-position}

Fuzzer는 표시한 위치를 제외하고 템플릿을 그대로 보냅니다. 변형할 값을 `§…§` 마커로 감싸세요. 값에 커서를 올리고 `Ctrl-A`를 눌러 흔한 파라미터(쿼리 키, 폼·JSON 필드)를 자동 표시하거나, 그 밖의 무언가 — 헤더 값, 경로 세그먼트 — 는 마커를 손으로 둘러 타이핑합니다.

마커와 페이로드를 어떻게 조합할지가 **모드**이며, CONFIG에서 설정합니다:

| 모드 | 동작 |
|------|----------|
| `sniper` | 한 번에 한 위치, 단일 페이로드 세트를 순환 (기본값) |
| `batteringram` | 표시된 모든 위치에 같은 페이로드 |
| `pitchfork` | 병렬 세트: 각 세트의 *n*번째 페이로드를 함께 |
| `clusterbomb` | 모든 세트에 걸친 전 조합 |

위치가 하나라면 `sniper`가 원하는 그것입니다. 나머지 셋은 두 곳 이상을 표시해야 값어치를 합니다. 헤드리스에서 위치는 요청 속 `§…§` 마커, 자동 배치용 `--auto`, 또는 `--mark=TOKEN`에서 오고, 모드는 플래그입니다:

```bash
gori run fuzz <flow-id> --auto --mode sniper
```

**체크포인트.** 정확히 값 하나가 `§…§`로 감싸지고(또는 `Ctrl-A` 이후 하이라이트되고), 모드가 `sniper`로 보입니다.

## 3. 페이로드 붙이기 {#3-attach-payloads}

페이로드 세트는 마커에 치환되는 것입니다. 파일 없이 빠르게 첫 패스를 돌리려면 내장 프리셋(`sqli`, `xss`, `traversal`, `format-string`, `bad-strings`, `command-injection`)으로 시작하거나, 워드리스트·명시적 목록·숫자 범위·브루트포스 문자 집합을 지정하세요.

실행 전에 알아 둘 것 하나: **gori는 기본적으로 페이로드를 URL 인코딩하지 않습니다.** 원시 바이트가 쓰인 그대로 와이어에 오르므로, 쿼리 문자열에 원시 공백을 담은 페이로드는 프로세서를 더하지 않으면 요청 라인을 망가뜨립니다. 프로세서는 나가는 길에 각 페이로드를 변환합니다 — 접두/접미, URL·base64·hex 인코딩, 대소문자 접기, 해싱, 또는 정규식 치환. 마커 안에 커서를 두고 `Ctrl-Y`를 누르면 그 프로세서 체인이 열리며, 요청 하나가 나가기 전에 값이 모든 단계를 거친 결과를 미리 보여 줍니다.

```bash
gori run fuzz <flow-id> --auto --mode sniper --wordlist params.txt --encode url
```

**체크포인트.** CONFIG에 페이로드 세트가 나열되고, `Ctrl-Y`는 각 페이로드가 실제로 나가는 모습을 보여 줍니다 — 인코더를 더했으면 인코딩된 채로, 안 더했으면 원시 그대로.

## 4. 매처 설정하고 실행하기 {#4-set-a-matcher-and-run}

매처는 어떤 응답이 주목할 값어치가 있는지 정하므로, 결과 표는 모든 응답이 아니라 신호를 드러냅니다. status, size, words, lines, 또는 본문 정규식으로 필터링하고(ffuf 스타일) — **자동 보정(auto-calibration)** 을 켜서 노이즈 기준선(소프트 404, 뭐든 받아 주는 200)이 진짜 히트를 묻어 버리지 않게 하세요. `Ctrl-R`로 실행합니다.

헤드리스에서 매처 플래그는 `--mc`/`--fc`(status), `--ms`/`--fs`(size), `--mw`/`--fw`(words), `--ml`/`--fl`(lines), `--mr`/`--fr`(본문 정규식), 그리고 자동 보정용 `--ac`입니다:

```bash
gori run fuzz <flow-id> \
  --auto \
  --wordlist params.txt \
  --mode sniper \
  --mc 200,302 \
  --fs 0 \
  --ac
```

<figure class="tui-shot">
  <img src="/images/tui/fuzzer.svg" alt="gori Fuzzer tab: a captured request template with one value wrapped in marker highlights, the payload set and attack mode in the CONFIG pane, a filling results table, and a status and size distribution sidebar">
  <figcaption><strong>Fuzzer</strong>: 템플릿에 표시된 위치 하나, CONFIG 패널의 페이로드 세트와 <code>sniper</code> 모드, 그리고 각 요청이 도착할 때마다 채워지는 결과 표.</figcaption>
</figure>

**체크포인트.** 요청이 도착할수록 결과 표가 채워집니다. status나 size로 정렬해 튀는 값을 위로 끌어올리세요.

## 5. 결과 읽고 다음 단계의 씨앗 심기 {#5-read-results-and-seed-the-next-step}

발견은 이웃과 어울리지 않는 행입니다 — 나머지가 `404`인데 혼자 뜬금없는 `200`이나 `500`, 또는 페이로드 하나가 다르게 안착하며 길이가 튀는 곳. 그 행은 결론이 아니라 실마리입니다. 결과에서 `Space` 메뉴로 **Repeater**에 넘기거나 **Comparer**로 기준선과 diff를 떠서, 튀어나온 그 페이로드 하나를 손으로 계속 파고드세요.

앱이 아예 이름조차 밝히지 않은 숨은 파라미터는 다른 일입니다. Fuzzer가 볼 수 있는 값을 변형하는 곳에서, **Miner**는 서버가 받아 주지만 광고하지 않는 후보 이름을 추측합니다 — [Param Miner](/ko/guide/scanning/#param-miner)를 보세요.

## 다음 단계 {#next-steps}

- [세션 이어 가기](/ko/playbooks/carry-a-session/): 이후의 모든 요청을 로그인한 사용자로 재전송
- [Fuzzer 레퍼런스](/ko/guide/repeater-and-fuzzer/#fuzzer): 어택 모드, 페이로드 세트, 매처 전체
- [Param Miner](/ko/guide/scanning/#param-miner): 앱이 이름조차 밝히지 않은 파라미터 찾기
