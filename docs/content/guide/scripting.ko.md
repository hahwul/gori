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

읽기 서브커맨드는 캡처 락을 잡지 않으므로, 라이브 TUI가 캡처 중인 프로젝트를 대상으로 실행해도 안전합니다. SQLite WAL이 읽는 쪽과 쓰는 쪽을 함께 감당합니다.

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
