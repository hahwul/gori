+++
title = "Statusline"
description = "직접 작성한 셸 명령이 채우는, TUI 맨 아래의 한 줄."
weight = 120

[extra]
group = "커스터마이즈"
+++

**statusline**은 TUI 맨 아래에 선택적으로 붙는 행입니다. gori가 일정 간격으로 셸 명령을 실행하고 그 stdout을 그 행에 렌더링합니다 — 직접 쓰는 상태 바이고, Claude Code의 상태 표시줄에서 영감을 받았습니다. 기본적으로 꺼져 있으며, 무언가 바꾸기 전까지 `statusline` 섹션은 `settings.json`에 들어가지 않습니다.

<figure class="tui-shot">
  <img src="/images/tui/statusline.svg" alt="상태 바 아래 맨 마지막 행에 statusline이 붙은 gori History 탭. token 58m left, 빨간색 1 × 5xx, 그리고 todo 2와 첫 미완료 항목 본문이 차례로 보인다">
  <figcaption><strong>statusline</strong>은 상태 바 아래 맨 마지막 행입니다. 이 행은 <a href="#script">아래의 스크립트</a>입니다 — 테스트 중인 토큰이 얼마나 남았는지, 타깃이 5xx를 뱉었는지, 할 일이 몇 개 남았는지. 위쪽 크롬이 말해 줄 수 없는 것들입니다.</figcaption>
</figure>

## 켜기

`Ctrl-,`로 Preferences를 열고 **General**로 가면 **Statusline** 행들이 있습니다. `Enabled`, `Command` 입력란, 그리고 `Interval`과 `Timeout` 초입니다. 명령을 입력하면 상태 바 아래에 행이 나타납니다.

`settings.json`으로는 이렇습니다:

```json
{
  "statusline": {
    "enabled": true,
    "command": "date '+%H:%M'",
    "interval": 3,
    "timeout": 10
  }
}
```

시계일 뿐입니다. 여기서는 모양이 중요하고, `command`에 무엇을 넣을지는 이 페이지의 나머지가 답합니다.

키 하나하나의 기본값과 정확한 의미는 [설정 레퍼런스의 `statusline`](/ko/reference/config/#statusline)에 있습니다.

명령을 쓰기 전에 알아둘 것 셋:

- **stdout의 첫 줄만 사용되고**, 터미널 너비로 잘립니다. 여러 줄을 출력하는 스크립트는 첫 줄만 그려집니다.
- **ANSI/SGR 색상 이스케이프가 해석됩니다** — 16색, 256색, truecolor에 볼드·밑줄까지 — 그래서 행을 평평한 문자열이 아니라 색상 세그먼트로 만들 수 있습니다.
- **편집은 즉시 반영됩니다.** `command` · `interval` · `timeout`을 저장하면 현재 간격이 끝나기를 기다리지 않고 다음 프레임에 다시 실행합니다.

UI를 막는 일은 없습니다. 실행은 그리기 경로 밖에서 일어나고, 서로 겹치지도 않습니다 — 이전 실행이 끝난 뒤에야 다음 실행을 띄웁니다.

## 프리셋 {#presets}

상단 바는 이미 gori가 자기 자신에 대해 아는 것들을 나릅니다. 프로젝트, 캡처 상태, 바인딩
주소, 스캔 모드. statusline이 한 줄을 차지할 값을 하려면 바가 말할 수 **없는** 것을 말해야
합니다 — gori 바깥의 사실이거나, gori가 갖고는 있지만 세어 주지 않는 것.

아래는 모두 한 줄이며 `command`에 그대로 넣으면 됩니다 — 설정 폼의 입력란도 한 줄입니다.
`\u001b`는 `jq`가 이스케이프 문자를 적는 방식이고, 색상은 선택 사항입니다. 각 명령 아래는 그
명령이 실제로 만들어낸 행입니다.

{% preset(title="지금 쓰는 토큰이 얼마나 남았는지", src="/images/tui/statusline-token.svg", alt="statusline 한 줄: 초록 점, 그리고 token 58m left", note="테스트 중인 베어러 토큰을 파일에 두면 행이 남은 시간을 세어 주고, 5분 밑으로 떨어지면 빨강이 됩니다 — 스윕이 401로 돌아오기 시작해 엉뚱한 곳을 10분 뒤지기 전에. JWT 도구면 무엇이든 되고, gori에도 하나 있습니다.") %}
```sh
jq -rn --argjson exp "$(gori run jwt "$(cat "${GORI_HOME:-$HOME/.gori}/token.jwt")" --format json | jq .payload.exp)" '(($exp - now) / 60 | floor) as $m | if $m < 5 then "\u001b[31m⚠ token \($m)m left\u001b[0m" else "\u001b[32m●\u001b[0m token \($m)m left" end'
```
{% end %}

{% preset(title="타깃이 5xx를 뱉기 시작했는지", src="/images/tui/statusline-errors.svg", alt="빨간색 statusline 한 줄: 1 × 5xx", note="타이머로 도는 History 쿼리입니다. History가 지금 걸어 둔 필터가 아니라 프로젝트 전체에 묻고, 타깃이 멀쩡한 동안은 아무것도 출력하지 않습니다 — 그래서 무언가 무너지는 순간에만 행이 나타납니다.") %}
```sh
p=$(jq -r .project); gori run history --project "$p" -q 'status:>=500' --format json 2>/dev/null | jq -rs 'length | if . == 0 then "" else "\u001b[31m\(.) × 5xx\u001b[0m" end'
```
{% end %}

{% preset(title="노트에 아직 안 끝낸 일", src="/images/tui/statusline-todo.svg", alt="statusline 한 줄: todo 2, 그리고 프로젝트 노트의 첫 번째 미완료 항목 본문", note="프로젝트 노트의 `- [ ]` 항목을 세고, 첫 항목은 본문까지 펼칩니다. 체크리스트가 열어 봐야 하는 탭이 아니라 눈앞에 남습니다.") %}
```sh
p=$(jq -r .project); gori run notes --all --project "$p" | awk '/^- \[ \]/ { n++; if (n == 1) first = substr($0, 7) } END { if (n) printf "todo %d · %s", n, first }'
```
{% end %}

물론 [컨텍스트](#context)의 모든 필드도 쓸 수 있습니다 — `\(.flows)`, `\(.issues)`, 모드
플래그들 — 다만 상단 바를 먼저 보세요. 칩을 그대로 되풀이하는 세그먼트는 한 줄을 쓰고
아무것도 알려주지 않습니다. 값을 하는 모양은 위의 것들, 즉 gori의 데이터와 gori가 알 길이
없는 사실을 엮는 쪽입니다:

```sh
# 프로젝트, 그리고 그것을 테스트하고 있는 브랜치.
printf '%s · %s' "$(jq -r .project)" "$(git branch --show-current 2>/dev/null)"
```

## 한 줄로 모자랄 때 {#script}

세그먼트가 한둘을 넘어가면 `command`는 타이핑하는 입력란이 아니라 보관하는 스크립트가 됩니다.
그쪽을 가리키게 하세요:

```json
{
  "statusline": {
    "enabled": true,
    "command": "sh \"${GORI_HOME:-$HOME/.gori}/statusline.sh\"",
    "interval": 5
  }
}
```

```sh
#!/bin/sh
# statusline.sh — one row: how long the token has, whether the target is erroring,
# and what is still unchecked. The context arrives on stdin, so read it once.
ctx=$(cat)
project=$(printf '%s' "$ctx" | jq -r .project)

token=$(jq -rn --argjson exp "$(gori run jwt "$(cat "${GORI_HOME:-$HOME/.gori}/token.jwt")" --format json | jq .payload.exp)" \
  '(($exp - now) / 60 | floor) as $m | if $m < 5 then "\u001b[31m⚠ token \($m)m left\u001b[0m" else "\u001b[32m●\u001b[0m token \($m)m left" end')
errors=$(gori run history --project "$project" -q 'status:>=500' --format json 2>/dev/null |
  jq -rs 'length | if . == 0 then "" else "\u001b[31m\(.) × 5xx\u001b[0m" end')
todo=$(gori run notes --all --project "$project" |
  awk '/^- \[ \]/ { n++; if (n == 1) first = substr($0, 7) } END { if (n) printf "todo %d · %s", n, first }')

printf '%s' "$token"
[ -n "$errors" ] && printf '   %s' "$errors"
[ -n "$todo" ] && printf '   %s' "$todo"
printf '\n'
```

이 페이지 맨 위 사진의 행이 바로 이것입니다. 위의 프리셋 셋을 합치되, 각 조각은 할 말이 있을
때만 출력합니다. 두 가지가 핵심입니다 — stdin은 파이프이므로 컨텍스트를 `$ctx`에 **한 번만**
읽고([위 참고](#context)), 마지막 문장을 평범한 `printf`로 두어 조용한 실행도 exit 0으로
끝나게 합니다(안 그러면 `⋯ (exit 1)`이 찍힙니다).

`interval`은 5 이상을 주세요. 실행마다 짧은 프로세스 셋을 띄우는데, 브라우저에 비하면 아무것도
아니지만 매초 할 일은 아닙니다.

## stdin으로 들어오는 컨텍스트 {#context}

각 실행은 라이브 세션을 설명하는 JSON 컨텍스트를 stdin으로 받으므로, 스크립트는 gori를 쿼리하지 않고도 프록시 상태를 표시할 수 있습니다:

```json
{
  "version": 1,
  "project": "acme",
  "capturing": true,
  "flows": 1234,
  "proxy": { "host": "127.0.0.1", "port": 8070, "addr": "127.0.0.1:8070" },
  "upstream": "",
  "upstream_rules": 0,
  "scope": { "active": true, "rules": 2, "sandbox": false },
  "intercept": { "enabled": false, "queued": 0, "direction": "both" },
  "probe": "passive",
  "issues": 7,
  "jobs": { "running": 1, "label": "fuzzing 1" }
}
```

| Field | Type | Description |
|-------|------|-------------|
| `version` | integer | 컨텍스트 스키마 버전 (현재 `1`) |
| `project` | string | 활성 프로젝트 이름 |
| `capturing` | bool | 프록시가 현재 캡처 중인지 여부 |
| `flows` | integer | 캡처한 플로우 수 |
| `proxy.host` / `proxy.port` / `proxy.addr` | string / integer / string | 프록시가 실제로 리스닝 중인 주소 |
| `upstream` | string | **캐치올** 업스트림 프록시 주소/URI, 직접 연결이면 비어 있음. [업스트림 규칙](/ko/reference/config/#upstream-rules)에 걸린 목적지는 다른 경로로 나가며, 이 필드는 그것을 반영하지 않음 |
| `upstream_rules` | integer | 적용 중인 [업스트림 규칙](/ko/reference/config/#upstream-rules) 수. 0이 아니면 라우팅이 목적지별로 갈라지므로 `upstream` 하나로는 트래픽 경로를 설명할 수 없음 |
| `scope.active` / `scope.rules` | bool / integer | [스코프](/ko/guide/proxy/#scope) 필터가 실제로 작동 중인지 — 렌즈가 켜져 있고 **동시에** 규칙이 하나 이상 — 그리고 규칙이 몇 개인지 |
| `scope.sandbox` | bool | [Sandbox](/ko/guide/proxy/#sandbox)가 스코프 밖 목적지를 기록만 안 하는 게 아니라 아예 차단하고 있는지 |
| `intercept.enabled` | bool | catch가 켜져 있는지. 켜져 있는 동안 실제 클라이언트가 붙잡혀 있음 |
| `intercept.queued` | integer | 지금 결정을 기다리는 메시지 수 |
| `intercept.direction` | string | `both` · `requestonly` · `responseonly` — 어느 쪽 다리를 붙잡는지 |
| `probe` | string | [스캐너](/ko/guide/scanning/#probe-the-scanner) 모드: `off` · `passive` · `active` · `aggressive` |
| `issues` | integer | 이 프로젝트에 기록된 이슈 수 |
| `jobs.running` | integer | 진행 중인 백그라운드 작업 수 (fuzz · mine · discover 등) — 활동 칩이 세는 바로 그 장부라, 전송 중인 Repeater 요청은 포함되지 않음 |
| `jobs.label` | string \| null | 상태 바의 활동 칩이 말하는 문구, 예: `"fuzzing 1"`. 실행 중인 게 없으면 `null` |

`scope`부터 아래는 이미 캡처한 것이 아니라 **gori가 다음에 무엇을 할지**를 설명합니다. 상단 바의 칩들이 나르는 바로 그 사실이라, 위를 올려다보지 않고도 "intercept가 아직 켜져 있나?"를 statusline이 답할 수 있습니다. 필드는 추가만 되었고 `version`은 `1` 그대로입니다. 이전 컨텍스트에 맞춰 쓴 스크립트는 똑같이 동작합니다.

**stdin은 한 번만 읽힙니다.** 파일이 아니라 파이프이므로 먼저 읽는 명령이 전부 가져가고 두 번째는 아무것도 못 받습니다 — `"$(jq -r .project)" "$(jq -r .flows)"`는 플로우 수를 조용히 빈 값으로 출력합니다. 위 프리셋들처럼 `jq` 하나로 전체를 읽거나, 먼저 담아 두세요:

```sh
ctx=$(cat); printf '%s · %s flows' "$(echo "$ctx" | jq -r .project)" "$(echo "$ctx" | jq -r .flows)"
```

## 명령이 실패했을 때 {#failures}

아무것도 출력하지 못하고 실패한 명령은 행을 비워 두는 대신 종료 상태를 보고합니다. 명령을 찾지 못했으면 `⋯ (exit 127)`, 시그널로 끝났으면 `⋯ (killed)`. `timeout`을 넘긴 실행은 종료되고 행은 `⋯ (timed out)`이 됩니다. 정상 종료했는데 출력이 없으면 행은 비어 있습니다(스크립트가 그렇게 할 수 있는 정당한 선택입니다). 어느 쪽이든 stderr는 버려집니다.

이 표식들은 본문 색이 아니라 주의 색으로 그려지므로, 멈춰 버린 statusline이 "나쁜 소식을 전하는 멀쩡한 statusline"으로 읽히지 않습니다.

`timeout`은 `interval`과 의도적으로 분리되어 있습니다. 실행이 겹치지 않기 때문에 `interval`보다 느린 스크립트는 매번 죽는 대신 가능한 만큼만 천천히 갱신되고, 실행을 끝내는 것은 오직 `timeout`입니다.

백그라운드로 일을 넘기는 명령(`curl … &`)은 스스로 뒷정리를 해야 합니다. gori는 자기가 띄운 `/bin/sh`만 죽일 수 있고, 그 셸이 fork한 것에는 손이 닿지 않습니다 — gori 자신의 프로세스 그룹을 공유하므로 그룹에 시그널을 보내면 gori까지 함께 죽습니다. 타임아웃된 실행에는 `SIGKILL` 전에 `SIGTERM`을 먼저 보내므로 `cmd & wait` 주위의 `trap … TERM`은 정리할 기회를 얻습니다. 더 간단한 답은 명령 자체에 한도를 거는 것입니다 (`curl --max-time 2`, `timeout 2 …`).

## 명령을 실을 수 있는 다른 자리

statusline은 데이터가 아니라 명령을 담는 다섯 설정 중 하나입니다. 나머지는 [프로세스 훅](/ko/guide/scripting/#프로세스-훅)과 외부 에디터입니다. `gori settings export`로 내보낸 프로필은 이들을 모두 실어 나를 수 있고, 전송의 양쪽 끝이 [그 사실을 말해 줍니다](/ko/reference/cli/#profiles-that-carry-commands).
