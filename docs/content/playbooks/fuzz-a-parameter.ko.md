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

실행 전에 알아 둘 것 하나: **쿼리 문자열이나 form-urlencoded 본문 값에 치환되는 페이로드는 gori가 URL 인코딩해 줍니다.** 그 자리의 원시 공백이나 `<`는 요청 타깃을 끊거나 프레이밍을 깨뜨리므로 퍼센트 인코딩합니다 — `--encode url`이 늘 하던 그 일을, 이제 기억하지 않아도 됩니다. 그 밖의 자리는 쓰인 그대로 나갑니다: 경로 세그먼트, JSON이나 원시 본문, 헤더, 쿠키 값 — 트래버설 탐침의 `%2F`는 표시한 것과 다른 시험이기 때문입니다. 원시 바이트 자체가 페이로드일 때는 `--no-encode`로 기본값을 끕니다 — 페이로드가 이미 퍼센트 이스케이프일 때도 그렇습니다. `%`도 예외 없이 인코딩되므로 `%00`은 `%2500`으로 나가고, origin의 디코더 자체를 겨눈 널바이트·overlong-UTF-8 탐침은 그냥 텍스트로 도착합니다. 프로세서는 나가는 길에 각 페이로드를 변환합니다 — 접두/접미, URL·base64·hex 인코딩, 대소문자 접기, 해싱, 또는 정규식 치환 — 그리고 그중 `--encode`는 기본 인코딩 위에 겹치는 대신 그것을 대체합니다. 나머지는 대체하지 않습니다: 접두·대소문자 접기·해싱·정규식 치환은 페이로드가 무엇인지를 말할 뿐 와이어가 그것을 어떻게 적는지는 말하지 않으므로, 쿼리나 form 위치라면 그 출력도 인코딩됩니다. 마커 안에 커서를 두고 `Ctrl-Y`를 누르면 그 프로세서 체인이 열리며, 요청 하나가 나가기 전에 값이 모든 단계를 거친 결과를 미리 보여 줍니다.

```bash
gori run fuzz <flow-id> --auto --mode sniper --wordlist params.txt
```

**체크포인트.** CONFIG에 페이로드 세트가 나열되고, `Ctrl-Y`는 각 페이로드가 실제로 나가는 모습을 보여 줍니다. `gori run fuzz`도 첫 요청 전에 몇 개의 쿼리/폼 위치를 인코딩하는지 한 번 알려 줍니다.

## 4. 매처 설정하고 실행하기 {#4-set-a-matcher-and-run}

매처는 어떤 응답이 주목할 값어치가 있는지 정하므로, 결과 표는 모든 응답이 아니라 신호를 드러냅니다. status, size, words, lines, 또는 본문 정규식으로 필터링하고(ffuf 스타일) — **자동 보정(auto-calibration)** 을 켜서 노이즈 기준선(소프트 404, 뭐든 받아 주는 200)이 진짜 히트를 묻어 버리지 않게 하세요. `Ctrl-R`로 실행합니다.

헤드리스에서 매처 플래그는 `--mc`/`--fc`(status), `--ms`/`--fs`(size), `--mw`/`--fw`(words), `--ml`/`--fl`(lines), `--mt`/`--ft`(왕복 시간, ms), `--mr`/`--fr`(본문 정규식), 그리고 자동 보정용 `--ac`입니다:

```bash
gori run fuzz <flow-id> \
  --auto \
  --wordlist params.txt \
  --mode sniper \
  --mc 200,302 \
  --fs 0 \
  --ac
```

### 차이가 시계뿐일 때 {#when-the-only-difference-is-the-clock}

시간 기반 블라인드 페이로드 — `' OR SLEEP(5)--`, `; ping -c 10 127.0.0.1`, `pg_sleep` — 는 아무 일도 하지 않은 페이로드와 status도, 바이트 길이도, 단어 수도, 본문도 똑같이 돌아옵니다. 위의 모든 차원이 이것을 보지 못하므로, 스윕이 우연히나 잡아낼 수 있는 유일한 부류였습니다. `--mt`는 이것을 직접 지목합니다.

```bash
gori run fuzz <flow-id> --auto -w sleep-payloads.txt --mt '>=4500' --timeout 15
```

단위는 밀리초입니다. **타임아웃된** 전송도 `--mt`에서는 매치로 셉니다 — 오리진을 당신이 정한 타임아웃 너머로 밀어낸 페이로드는 같은 신호의 가장 큰 형태인데, 예전에는 그것이 에러로 버려지고 정작 실패한 sleep이 40 ms에 돌아와 보고됐기 때문입니다. 그 밖에는 달라지는 것이 없습니다. 거부되거나 닿지 않은 전송은 여전히 결과가 아니고, `--mt`를 `--mc 200`과 함께 쓰면 응답이 필요한데 타임아웃에는 응답이 없습니다. `--retries`도 `--mt` 실행에서는 타임아웃을 재전송하지 않습니다 — 그 행은 실패한 전송이 아니라 발견이므로, 재전송해 봐야 타임아웃 한 번과 오리진에 대한 요청 하나를 더 쓸 뿐입니다.

타이밍은 원래 노이즈가 많습니다(공유 오리진, 느린 홉, 운 나쁜 일시 정지 한 번). 그러니 `--mt` 행은 다른 매치와 똑같이 손으로 재전송해 볼 실마리로 다루세요.

<figure class="tui-shot">
  <img src="/images/tui/fuzzer.svg" alt="gori Fuzzer tab: a captured request template with one value wrapped in marker highlights, the payload set and attack mode in the CONFIG pane, a filling results table, and a status and size distribution sidebar">
  <figcaption><strong>Fuzzer</strong>: 템플릿에 표시된 위치 하나, CONFIG 패널의 페이로드 세트와 <code>sniper</code> 모드, 그리고 각 요청이 도착할 때마다 채워지는 결과 표.</figcaption>
</figure>

**체크포인트.** 요청이 도착할수록 결과 표가 채워집니다. status나 size로 정렬해 튀는 값을 위로 끌어올리세요.

## 5. 결과 읽고 다음 단계의 씨앗 심기 {#5-read-results-and-seed-the-next-step}

발견은 이웃과 어울리지 않는 행입니다 — 나머지가 `404`인데 혼자 뜬금없는 `200`이나 `500`, 또는 페이로드 하나가 다르게 안착하며 길이가 튀는 곳. 그 행은 결론이 아니라 실마리입니다. 결과에서 `Space` 메뉴로 **Repeater**에 넘기거나 **Comparer**로 기준선과 diff를 떠서, 튀어나온 그 페이로드 하나를 손으로 계속 파고드세요.

실행 전체를 남기려면, 끝난 뒤 에디터를 READ 모드에 둔 채 **`Shift-S`** 를 누르세요. 스윕이 도는 동안 gori는 완전한 요청/와이어/응답 행을 전부 디스크에 비공개로 스풀하고, 화면은 5,000행 / 64 MiB로 제한된 창을 유지합니다. Shift-S는 그 완전한 스풀을 프로젝트로 승격시킵니다. 마지막으로 성공한 실행은 해당 Fuzzer 세션과 함께 제한된 창으로 자동으로 다시 열리고, **Space → Run history** 로 더 오래된 실행을 고를 수 있으며, CLI/MCP는 아카이브 전체를 페이지 단위로 읽습니다. 헤드리스에서는 영구 저장을 명시하고 id로 들여다봅니다:

```bash
gori run fuzz save <flow-id> --auto --wordlist params.txt --mc 200,302
gori run fuzz list
gori run fuzz show RUN_ID
gori run fuzz show RUN_ID RESULT_INDEX --format json
```

원래의 `gori run fuzz …`는 계속 일회성이므로, 업그레이드했다고 기존 스크립트가 갑자기 프로젝트 데이터베이스를 불리기 시작하지는 않습니다.

앱이 아예 이름조차 밝히지 않은 숨은 파라미터는 다른 일입니다. Fuzzer가 볼 수 있는 값을 변형하는 곳에서, **Miner**는 서버가 받아 주지만 광고하지 않는 후보 이름을 추측합니다 — [Param Miner](/ko/guide/scanning/#param-miner)를 보세요.

## 다음 단계 {#next-steps}

- [세션 이어 가기](/ko/playbooks/carry-a-session/): 이후의 모든 요청을 로그인한 사용자로 재전송
- [Fuzzer 레퍼런스](/ko/guide/repeater-and-fuzzer/#fuzzer): 어택 모드, 페이로드 세트, 매처 전체
- [Param Miner](/ko/guide/scanning/#param-miner): 앱이 이름조차 밝히지 않은 파라미터 찾기
