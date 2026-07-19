+++
title = "쿼리 언어"
description = "History, Sitemap, Probe, Issues, Intercept, MCP 도구 전반에서 쓰는 필터 문법."
+++

gori에는 플로우를 걸러내는 작은 쿼리 언어(QL)가 있습니다. 같은 문법이 TUI 필터 바, `gori run`(`-q`/`--query` 또는 위치 인자), 그리고 MCP 도구에서 동일하게 동작합니다. 내장 레퍼런스는 `gori run history --help`와 `ql_reference` MCP 도구로도 볼 수 있습니다.

## 필드 {#fields}

`field:value`로 필드를 매칭합니다(필드에 따라 부분 문자열 또는 완전 일치):

| Field | Matches |
|-------|---------|
| `host` | 요청 호스트 |
| `path` | 요청 경로 |
| `url` | 전체 URL |
| `method` | HTTP 메서드 |
| `scheme` | `http` / `https` |
| `proto` | 프로토콜: `http`, `ws`, `grpc`, `sse` |
| `status` | 응답 상태 코드 |
| `size` | 요청 + 응답 전체 바이트 |
| `reqsize` / `respsize` | 각 방향의 바이트 수 |
| `dur` | 응답 시간(밀리초) |
| `header` | 헤드(요청 + 응답 헤더) 부분 문자열 |
| `body` | 본문 전문 검색(trigram FTS 인덱스) |

```text
host:example.com
method:POST
status:404
```

## 상태 클래스 {#status-classes}

`status:`는 클래스 약어를 받습니다:

```text
status:2xx      status:4xx      status:5xx
```

## 비교 {#comparisons}

숫자 필드(`status`, `size`, `reqsize`, `respsize`, `dur`)는 비교 연산자 `<`, `<=`, `>`, `>=`, `=`를 지원합니다:

```text
status:>=500        서버 오류
size:>100000        큰 교환
dur:>500            500ms보다 느림
dur:<2s             2s보다 빠름 (s / ms 접미사 허용)
```

## 정규 표현식 {#regular-expressions}

`host`, `path`, `url`, `header`, `body`에 정규식 매칭을 하려면 `~`를 씁니다. `~`는 자체적으로 필드/값 구분자 역할을 하므로 앞에 콜론을 붙이지 **마세요**. 매칭은 대소문자를 구분하며, 대소문자를 무시하려면 `(?i)`를 앞에 붙입니다.

```text
path~/admin/
host~^api\.
header~set-cookie
```

## 항목 결합 {#combining-terms}

- 공백으로 구분된 항목들은 **AND**로 결합됩니다. `AND`를 직접 써도 됩니다.
- `OR`는 둘 중 하나를 매칭합니다. `NOT`과 `-` 접두사는 모두 부정입니다.
- 괄호로 묶을 수 있습니다. 우선순위는 `NOT`, `AND`, `OR` 순입니다.
- `field:`가 없는 단순 단어는 method, host, target을 대상으로 하는 자유 텍스트 검색입니다.

```text
host:example.com status:5xx           둘 다 매칭되어야 함
host:api AND status:5xx               같은 의미를 풀어 쓴 것
method:POST -status:200               POST이지만 200은 아님
host:a.com OR host:b.com              둘 중 하나의 호스트
(host:a.com OR host:b.com) -path:/js  둘 중 하나의 호스트, /js 제외
NOT (host:cdn OR host:static)         둘 다 아닌 것
login                                 자유 텍스트 검색
```

`AND`, `OR`, `NOT`은 대문자로 쓸 때만 연산자로 인식합니다. 따라서 "and", "or", "not"이라는
단어를 검색하는 것도 그대로 됩니다. 대문자라도 따옴표로 감싸면 리터럴이 됩니다.

큰따옴표는 공백이 포함된 값을 하나의 항목으로 유지합니다:

```text
host:"my host"                        공백까지 포함한 하나의 host 값
"two words"                           구 전체를 자유 텍스트로
"OR"                                  연산자가 아닌 단어 그대로
```

값 안의 괄호는 리터럴로 남으므로 `path:/a(b)`는 이스케이프가 필요 없습니다. `(`는 항목의
맨 앞에서만 그룹을 열고, `)`는 맨 뒤에서만 그룹을 닫습니다.

## 적용 범위 {#where-it-applies}

다섯 개의 필터 바가 위 문법(필드, 비교, `~` 정규식, `AND`/`OR`/`NOT`, 괄호, 따옴표)을 공유합니다. 다른 것은 필드 집합뿐입니다. 각 화면이 서로 다른 종류의 행을 거르기 때문입니다.

| 화면 | 필드 |
|------|------|
| History, `gori run history`, MCP | 위 표 전체 |
| Sitemap | 위와 동일, 여기에 노드별 경로 메모용 `tag:` 추가 |
| Probe | `severity`(`sev`), `status`(`st`), `category`(`cat`), `host`, `code` |
| Issues | `severity`(`sev`), `status`(`st`), `host`, `title` |
| Intercept 캐치 조건 | `host`, `path`, `method`, `scheme`, `status` |

Probe와 Issues는 심각도 이름(`info`, `low`, `medium`/`med`, `high`, `critical`/`crit`)과 트리아지 상태(`open`, `confirmed`/`conf`, `false-positive`/`fp`, `resolved`/`done`, 그리고 open이 아닌 모든 상태를 뜻하는 `closed`)를 받습니다. 심각도는 비교를 지원하므로 `sev:>=high`도 동작합니다.

```text
sev:>=high -status:fp          Issues: high와 critical, 오탐 제외
cat:cors sev:medium            Probe: medium 등급 CORS 발견
host:api.example.com method:POST   Intercept: 한 호스트의 POST만 홀드
```

Intercept 바는 입력하는 동안 필드 이름과 알려진 값을 Tab으로 자동 완성합니다.

## 예제 {#examples}

```bash
# 한 호스트의 오류
gori run history -q 'host:api.example.com status:5xx'

# 토큰을 언급하는 느린 POST
gori run history -q 'method:POST dur:>1s body:token'

# 정적 자산을 제외한 admin 경로
gori run history -q 'path~/admin/ -path~\.(css|js|png)$'

# 패시브 스캔의 범위 지정
gori run probe -q 'host:example.com'
```
