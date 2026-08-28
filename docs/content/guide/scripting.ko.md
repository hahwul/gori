+++
title = "스크립팅"
description = "gori run으로 gori를 헤드리스로 구동합니다. TUI와 같은 프로젝트·같은 엔진을 파이프라인과 CI에 맞춘 형태로 제공합니다."
weight = 80

[extra]
group = "자동화"
+++

gori는 하나의 프로젝트와 하나의 엔진 위에 세 개의 진입점을 둡니다. `gori`(사람을 위한 TUI), **`gori run`**(스크립트를 위한 헤드리스 CLI), 그리고 [`gori mcp`](/ko/guide/mcp/)(AI 에이전트용)입니다. 이 페이지는 스크립팅 경로를 다룹니다.

`gori run`은 TUI를 얇게 감싼 래퍼가 아닙니다. 같은 Store, Repeater, 스윕 엔진에 터미널 없는 프런트엔드를 붙인 것입니다. 손으로 캡처한 것은 스크립트에서 질의할 수 있고, 스크립트가 캡처한 것은 TUI를 열면 그대로 보입니다.

```bash
gori run <subcommand> [verb] [options]
```

전체 서브커맨드 목록은 `gori run -h`로, 모든 플래그는 [CLI 레퍼런스](/ko/reference/cli/)에서 확인하세요.

## 프로젝트 선택

각 프로젝트는 자체 SQLite 데이터베이스입니다. 읽기 서브커맨드는 다음 순서로 하나를 고릅니다.

| 선택자 | 의미 |
|--------|------|
| `--db=PATH` | 특정 데이터베이스 파일 — 무엇보다 우선 |
| `--project=NAME` | 짧은 id, 디렉터리 슬러그, 표시 이름, 고유 id 접두사로 매칭(대소문자 무시) |
| *(둘 다 없음)* | 가장 최근에 사용한 프로젝트 |

`gori run capture`만 한 가지가 다릅니다. 읽기는 이미 존재하는 프로젝트를 요구하지만, capture는 대상을 **생성하거나 다시 엽니다**.

읽기 서브커맨드는 스토어를 읽기 전용으로 열고 캡처 락을 잡지 않으므로, 라이브 TUI가 캡처 중인 프로젝트를 대상으로 실행해도 안전합니다. SQLite WAL이 읽는 쪽과 쓰는 쪽을 함께 감당합니다. `body:` 질의는 예외입니다. 검색 인덱스를 비우므로 쓰기입니다.

```bash
gori run history --project my-engagement -q 'status:5xx'
gori run issues --db /path/to/project.db --format json
```

## 스크립팅 계약

`gori run`이 뱉는 JSON은 눈으로 보라고 만든 게 아니라 파싱하라고 만든, 안정적이고 문서화된 형태입니다. 다음 네 가지 규칙이 파이프를 깔끔하게 유지합니다.

**STDOUT은 데이터, STDERR은 진단.** 경고, 개수, 안내, 내보내기 확인 메시지는 모두 STDERR로 갑니다. 그래서 `gori run … | jq`는 입력에서 잡담을 걸러낼 필요가 없습니다.

**`--format`이 형태를 정합니다.** 대부분의 서브커맨드는 `text`(기본)와 `json`을 받고, 일부는 `jsonl`, `raw`, `har`, `paths`, `markdown`을 더합니다. 실행이 길게 이어지는 곳에서는 두 JSON 형태가 다르고, 그 차이를 알아둘 만합니다.

| 서브커맨드 | `--format json` | `--format jsonl` |
|-----------|-----------------|------------------|
| `capture`, `history` | 한 줄에 JSON 객체 하나 | `json`의 별칭 — 출력 동일 |
| `fuzz`, `mine`, `discover` | 버퍼링 후 마지막에 JSON 배열 하나 | 결과가 나올 때마다 한 줄씩 |

긴 스윕을 진행 중에 소비하려면 `jsonl`을, 끝에 문서 하나를 받으려면 `json`을 씁니다.

**종료 코드에 의미가 있습니다.**

| 코드 | 의미 |
|------|------|
| `0` | 성공 |
| `1` | 오류 — 전송 실패, 열 수 없는 프로젝트, 적용되지 못한 변경 |
| `3` | `gori run fuzz --fail-if-no-matches`가 정상 완료했지만 매칭이 하나도 없음 |

매칭이 없으면서 *동시에* 모든 전송이 실패한 fuzz 실행(대상 다운, TLS 실패, 스코프 차단)은 `3`이 아니라 `1`로 끝납니다. `--fail-if-no-matches` 없이도 스크립트가 "결과 없음"과 "대상에 닿지도 못함"을 구분할 수 있습니다.

**닫힌 파이프는 오류가 아닙니다.** `gori run history | head -5`는 여느 유닉스 필터처럼 조용히 `0`으로 끝납니다.

```bash
# 프로젝트의 모든 5xx를 JSON Lines로 뽑아 jq로
gori run history -q 'status:5xx' --limit 500 --format json | jq -r '.url'

# 5분간 캡처해 이름 붙인 프로젝트에 쌓고, 파일로 스트리밍
gori run capture --project ci-run --for 5m --format jsonl > flows.jsonl

# 퍼저가 반사된 마커를 찾으면 CI 잡을 실패시키기
gori run fuzz 42 --wordlist payloads.txt --mr 'gori-canary' --fail-if-no-matches
```

## 스코프 지키기

소켓을 여는 모든 액티브 서브커맨드는 TUI와 MCP가 쓰는 것과 같은 아웃바운드 게이트를 지납니다. 스코프 규칙이 있는 프로젝트는 그 밖의 대상을 거부하며, `--allow-unscoped`가 의도적인 예외 선언입니다. 샌드박스와 명시적 제외 규칙은 이 플래그와 무관하게 항상 적용됩니다.

`--request`나 STDIN으로 원시 요청을 퍼징하면서 `--project`/`--db`를 주지 않으면 참조할 스코프 자체가 없습니다. 이때 gori는 검사한 척하지 않고 STDERR에 명시적인 unscoped 경고를 출력합니다.

## 인증이 필요한 스윕

세션 바인딩(`$SESSION` 같은 것들)은 그것을 관측한 gori 프로세스의 메모리에만 존재하며, 절대 저장되지 않습니다. 복원된 토큰은 이미 낡은 것이기 때문입니다. TUI에서는 한 프로세스가 전송과 뒤이은 스윕을 모두 쥐고 있으니 문제가 없지만, `gori run`은 프로세스마다 한 번만 실행됩니다.

`--bind-from FLOW-ID`가 그 빈틈을 메웁니다. 캡처된 플로우 하나를 먼저 재생해서, 그 응답이 같은 프로세스 안에서 fuzz·mine·sequence·discover 템플릿이 읽을 바인딩을 채우게 합니다.

```bash
gori run fuzz 42 --bind-from 41 --wordlist ids.txt
```

바인딩을 정의하는 추출 규칙은 [세션 바인딩](/ko/guide/proxy/#session-bindings)을 참고하세요.

## 프로세스 훅

gori에는 플러그인 SDK가 없고 앞으로도 없습니다. 변환을 *계산*해야 할 때 — JWT 재서명, 바디
재압축, 독자 포맷 봉투 복호화, 진짜 탐지기 실행 — 이미 가지고 있는 프로그램에 바이트를 넘기면
됩니다. stdin으로 바이트를 주고 stdout으로 교체 바이트를 받습니다. 확장 표면은 이게 전부이고,
같은 원시 도구가 세 군데에 붙어 있습니다.

| 이음매 | 위치 | 하는 일 |
|--------|------|---------|
| Rewriter `pipe` 액션 | Rewriter 탭, `gori run rewriter add --op=pipe`, MCP `create_rule` | 매치된 구간을 명령에 넘기고 stdout으로 교체 — 프록시에서 실시간으로 |
| Decoder `exec:` 스텝 | Decoder 탭 체인, `gori run decoder`, `§value¦chain§` 마커 | 체인의 한 스텝이 컨버터가 아니라 명령 |
| Probe `exec` 룰 | Probe 룰, `gori run probe rules add --exec` | 구간을 명령에 넘겨 exit 0이면 발견, stdout이 근거 |

```bash
# 브라우저에서 나가는 모든 JWT를 내 서명기로 재서명한다.
gori run rewriter add --op=pipe --match=regex --part=body \
  --find='eyJ[A-Za-z0-9._-]+' --value='./resign.sh --key dev.pem'

# base64 바디를 디코드해 내 파서에 통과시키고 예쁘게 출력한다.
gori run decoder 'base64-decode > exec:./parse-envelope --json > json-pretty' "$BLOB"

# 정규식 대신 진짜 탐지기가 판정하게 한다.
gori run probe rules add --title 'envelope leak' --exec --pattern './detect-leak --stdin'
```

**명령은 직접 exec됩니다. 셸이 없습니다.** `argv`는 따옴표와 백슬래시 규칙(`'a b'`, `"a b"`,
`a\ b`)으로만 토큰화되어 `execvp`에 데이터로 전달됩니다 — `$FOO`, `*`, `` ` ``, `;`, `&&`, `|`,
`>`는 인자 안의 평범한 문자일 뿐 연산자가 아닙니다. 훅을 통과하는 캡처 바이트가 셸에 해석될
길은 없습니다. Decoder 체인에서는 세 구분자(`>`, `|`, `,`)가 스텝을 읽기 전에 소비되므로
`exec:` 스텝의 인자 안에는 들어갈 수 없습니다.

**훅은 프록시를 멈추지 못합니다.** 모든 실행에 하드 벽시계 타임아웃(settings.json의
`hooks.timeout_secs`, 기본 5초, 상한 60초)과 32 MiB stdout 상한이 걸립니다. 명령이 타임아웃되거나,
0이 아닌 코드로 종료되거나, 실행 자체에 실패하거나, stdout을 넘치게 쏟으면 **원본 바이트가 그대로
통과**하고 실패는 프로젝트 이벤트 피드에 알림으로 기록됩니다. 멈춘 훅 때문에 플로우를 잃는 일은
없습니다. Rewriter에서 타임아웃은 한 번의 재작성에 걸린 모든 pipe 룰과 모든 매치가 나눠 쓰는
*예산*입니다. 400번 매치되는 패턴도, 한 헤드에 걸린 pipe 룰 4개도 예산 한 번만큼만 듭니다. 메시지
하나는 헤드와 바디로 두 번 재작성되므로 메시지가 보는 한계는 그 두 배입니다.

**의도적으로 연결하지 않은 두 곳.** MCP `decode` 툴은 `exec:` 스텝을 거부합니다(저장된 체인
포함) — read-only·unbound로 노출되는 툴이라 순수 계산으로 남깁니다. 훅이 필요한 에이전트는 `pipe`
rewriter 룰이나 `exec` probe 룰을 만들면 되고, 둘 다 운영자가 볼 수 있는 게이트된 쓰기입니다. 그리고
Probe `exec` 룰은 패시브 분석기에서 **플로우당 한 번** 실행되므로, 느린 탐지기는 라이브 캡처 중 룰
셋 전체의 병목이 됩니다. 명령을 빠르게 유지하세요.

**훅은 당신 권한으로 실행됩니다.** 샌드박스도, 감옥도, 격리도 없습니다 — `--config` 파일이나 다른
Rewriter 룰과 같은 신뢰 수준입니다. gori가 훅을 스스로 만들어내는 일은 없습니다. 전부 사람이 쓴
설정이고, 각각은 자기가 속한 룰 목록에 그대로 보입니다. 열어둔 프로젝트에 다른 세션(에이전트,
두 번째 TUI)이 `pipe` 룰을 추가하면, 이 세션은 지금부터 당신을 대신해 로컬 명령을 실행하게
되었다고 그대로 말해줍니다.

## 무엇을 쓸까

| 할 일 | 서브커맨드 |
|-------|-----------|
| CI에서 헤드리스로 트래픽 캡처 | `capture` |
| History 질의·내보내기(HAR 포함) | `history`, `show` |
| 요청 재전송과 비교 | `repeater`, `compare` |
| 페이로드 스윕, 숨은 파라미터 탐색 | `fuzz`, `mine` |
| 엔드포인트 크롤링·브루트포스 | `discover`, `sitemap` |
| 아이덴티티별 접근 제어 시험 | `authorize` |
| 스캔과 트리아지 | `probe`, `issues`, `notes` |
| 프로젝트 없이 순수 계산 | `decoder`, `jwt`, `cookie` |
| 프로젝트·스코프·env·규칙 관리 | `project`, `rewriter`, `colormarker` |

## 다음 단계

- [CLI 레퍼런스](/ko/reference/cli/): 모든 서브커맨드와 플래그
- [쿼리 언어](/ko/reference/query-language/): `-q`가 받는 필터 문법
- [MCP 서버](/ko/guide/mcp/): 셸 대신 AI 에이전트가 같은 프로젝트를 구동하는 길
