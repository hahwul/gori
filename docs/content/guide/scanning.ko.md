+++
title = "스캐닝 & Issues"
description = "Probe 스캐너, Param Miner, 그리고 결과를 Issues로 트리아지하기."
+++

gori에는 수동 테스트와 나란히 돌아가는 자동 분석 기능이 있습니다. **Probe**는 트래픽에서 이슈를 감시하고, **Param Miner**는 숨은 입력을 발견하며, **Issues**는 결과를 트리아지하는 곳입니다.

## Probe: 스캐너 {#probe-the-scanner}

**Probe**는 보안 이슈를 유형과 심각도로 묶습니다. 패시브 체크는 브라우징하는 동안 실행되며(추가 요청은 전혀 없이) **History** 플로우와 **Repeater** 전송 결과를 검사합니다.

**액티브** 체크는 의도적으로 *light-touch*로 설계되었습니다. 이미 캡처한 트래픽에 대해 안전하고 저용량인 프로브 몇 개를 보낼 뿐입니다. 안전한 메서드(`GET` / `HEAD`)만 프로브하고, 고유한 표면마다 한 번씩만 테스트하며, 액티브 모드를 활성화하기 전에는 아무것도 나가지 않습니다. 흔적을 최소로 남기면서 빠른 직감을 확인하도록(파라미터가 반사되는지, origin이 허용되는지) 만들어졌습니다.

<figure class="tui-shot">
  <img src="/images/tui/probe.svg" alt="심각도와 범주로 묶인 패시브 이슈를 나열하는 gori Probe 스캐너: 허용적 CORS, 누락된 CSP와 HSTS, 쿠키 플래그 문제, 캐시 가능한 응답, 각각 영향받는 호스트 표시">
  <figcaption><strong>Probe</strong>는 브라우징하는 동안 패시브 이슈(CORS, 쿠키 위생, 누락된 보안 헤더, 정보 노출)를 심각도와 범주로 묶어 드러냅니다.</figcaption>
</figure>

| 범주 | 다루는 내용 |
|----------|----------------|
| `headers` | 보안 헤더(HSTS, CSP, …), 평문 Basic 인증, 혼합 콘텐츠, 캐시 가능한 API 응답 |
| `cookies` | `Secure` / `HttpOnly` / `SameSite` 및 관련 쿠키 위생 |
| `tech` | 기술 및 프로토콜 핑거프린트(Project 탭에도 표시) |
| `infoleak` | 본문 노출, URL / WS 프레임의 비밀 값, GraphQL introspection |
| `cors` | 와일드카드 / null origin / 자격 증명 관련 오설정; 액티브 origin 반사 |
| `active` | light-touch 프로브로 확인됨(예: 반사되는 파라미터). TUI 액티브 스캔 전용 |

심각도는 `info`, `low`, `medium`, `high`, `critical` 순입니다. 헤드리스 `gori run probe`는 **패시브** 체크만 실행합니다(`active`를 제외한 범주).

패시브 분석을 헤드리스로 실행하세요. 이미 캡처된 것(History + Repeater 응답)을 읽기만 하고 아무것도 보내지 않습니다.

```bash
gori run probe                       # all issues
gori run probe --severity high       # only high-severity
gori run probe --category cors       # a single category
gori run probe -q 'host:example.com' # filter History with QL (Repeater still scanned)
```

## Param Miner {#param-miner}

**Miner**는 서버가 받아들이지만 드러내지 않는 파라미터를 발견합니다. 플로우를 지정하면 쿼리 문자열, 폼 본문, JSON, 헤더, 쿠키 등 여러 위치에서 후보 이름을 프로브하고, 추측을 효율적으로 버킷으로 묶어 응답을 변화시키는 것들을 보고합니다.

```bash
gori run mine <flow-id> \
  --locations query,headers \
  --wordlist params.txt \
  --bucket 50
```

> Miner 탭은 기본적으로 숨겨져 있습니다. 필요할 때 커맨드 팔레트(`Ctrl-P`)에서 활성화하세요.

## Issues {#issues}

**Issues**는 트리아지 목록입니다. 추적할 가치가 있는 것이라면 무엇이든(Probe, Fuzzer, Miner, 또는 직접 검사한 결과에서) 심각도와 상태를 붙여 이슈로 승격하고, 증거 플로우로 바로 되돌아갈 수 있습니다. 이슈는 리포트용으로 익스포트할 수 있습니다.

```bash
gori run issues --format markdown --export report.md
```

## Notes & Comparer {#notes-comparer}

두 가지 도구가 분석을 마무리합니다.

- **Notes**: 자유 형식의 프로젝트별 마크다운 문서(프로젝트당 여러 노트). Notes 탭에서 노트를 생성, 편집, 닫을 수 있고, `gori run notes` / `gori run notes --all`로 헤드리스에서 목록을 보거나 덤프할 수 있습니다. 에이전트는 MCP(`list_notes`, `get_note`, `create_note`, …)로 노트를 관리할 수 있습니다.
- **Comparer**: 두 플로우를 슬롯 A와 B에 불러와 줄 단위로 diff합니다. 요청 간 응답이 어떻게 바뀌었는지 파악하는 데 유용합니다. History에서 `Space` → Comparer로 플로우를 보내거나, Comparer 탭에서 슬롯을 교체하세요.

이슈, 노트, 리피터, 퍼즈/마이너 세션은 서로 링크할 수 있어, 이슈에서 증거 플로우나 그것을 만든 세션으로 바로 점프할 수 있습니다.

## 다음 단계 {#next-steps}

- [MCP Server](/ko/guide/mcp/): 에이전트가 스캔을 실행하고 이슈를 읽게 합니다
- [CLI Reference](/ko/reference/cli/): `probe`, `mine`, `issues`, `notes` 플래그
- [Query Language](/ko/reference/query-language/): 스캔 범위를 좁힙니다
