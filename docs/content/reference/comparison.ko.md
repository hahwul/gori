+++
title = "Gori vs Burp Suite, Caido, ZAP"
description = "Gori를 Burp Suite, Caido, ZAP과 기능 단위로 비교합니다."
weight = 40
+++

Gori, Burp Suite, Caido, ZAP은 모두 클라이언트와 타겟 사이에 자리하는 인터셉트 프록시입니다. 이 문서는 이들을 기능 단위로 비교합니다. Burp Suite는 무료 Community 에디션과 유료 Professional 에디션으로 나뉘며, 둘의 차이가 있는 항목은 표에 함께 표시합니다.

## 한눈에 보기 {#at-a-glance}

| | Gori | Burp Suite | Caido | ZAP |
|---|------|------------|-------|-----|
| **인터페이스** | 터미널(TUI), CLI, MCP | Java 데스크톱 GUI | 데스크톱 앱 / 웹 UI | Java 데스크톱 GUI |
| **라이선스 / 비용** | 무료, Apache 2.0 | Community: 무료. Pro: 유료 | 무료 플랜 제공. Pro: 유료 | 무료, Apache 2.0 |
| **플랫폼** | macOS, Linux | Windows, macOS, Linux | Windows, macOS, Linux | Windows, macOS, Linux, Docker |
| **확장 모델** | 없음(단일 바이너리) | BApp Store, Bambdas, BChecks | JS/Python 플러그인, 비주얼 Workflows | 애드온 마켓플레이스, 스크립팅 |
| **자동화 방식** | `gori run`(CLI), MCP 서버 | Extensions API | REST API, Workflows | Automation Framework, API/데몬 |

## 기능 매트릭스 {#feature-matrix}

| 기능 | Gori | Burp Suite | Caido | ZAP |
|------|------|------------|-------|-----|
| **인터셉트 프록시** | 지원: HTTP/1.1, HTTP/2, WebSocket, gRPC, SSE | 지원: HTTP/1.1, HTTP/2, WebSocket. gRPC/SSE는 확장으로 | 지원: HTTP/1.1, HTTP/2, WebSocket. gRPC/SSE는 플러그인으로 | 지원: HTTP/1.1, HTTP/2, WebSocket. gRPC/SSE는 애드온으로 |
| **수동 인터셉트(홀드/편집/포워드/드롭)** | 지원, 쿼리 언어 캐치 조건 포함 | 지원 | 지원 | 지원 |
| **리피터형 워크벤치** | Repeater. WebSocket, gRPC 모드 포함 | Repeater | Replay | Manual Request Editor |
| **인트루더형 퍼저** | Fuzzer, 4가지 모드, 헤드리스 + MCP | Intruder(Community는 속도 제한) | Automate | Fuzzer |
| **자동 취약점 스캐너** | Probe: 패시브 검사 + 안전한 메서드만 쓰는 라이트터치 액티브 검사 | Pro 전용: 완전한 패시브 + 액티브 스캐너 | 공식 Scanner 플러그인: 템플릿 기반 패시브/액티브 검사 | 완전한 패시브 + 액티브 스캐너(코어 내장) |
| **숨은 파라미터 탐색** | Param Miner | 확장(Param Miner BApp) | 플러그인 | 확장 |
| **스파이더 / 콘텐츠 탐색** | Discover(스파이더 + 브루트포스, soft-404 보정) | 크롤러(Pro) | 플러그인/Workflows로 구현 | 스파이더 3종(traditional, AJAX, Client) |
| **Match & Replace** | Rewriter 탭, 프로젝트별 규칙 | 지원 | 지원 | 지원(Replacer 애드온) |
| **JWT / SAML / GraphQL 도구** | 셋 다 인라인 디코드. 재서명과 공격 페이로드를 갖춘 전용 JWT 워크벤치 | 확장(BApp Store) | GraphQL Analyzer 플러그인. JWT는 플러그인으로 | 확장 |
| **아웃오브밴드(OOB) 탐지** | 내장 OAST 탭과 리스너 | Burp Collaborator | 서드파티 OOB 서비스 연동 | OAST 애드온(Interactsh 기반) |
| **토큰 무작위성 분석** | Sequencer | Sequencer(Pro) | 내장 기능 없음 | 내장 기능 없음 |
| **플로우 diff** | Comparer | Comparer | History 안의 diff 뷰 | Compare Requests |
| **커스텀 탐지 규칙** | Probe 커스텀 규칙(문자열/정규식 매칭) | BChecks(Pro) | 커스텀 Scanner 검사 | 커스텀 스캔 규칙(스크립팅) |
| **헤드리스 / CI 사용** | `gori run`이 TUI의 모든 동작을 그대로 반영 | Burp CI / REST API(Enterprise) | 헤드리스 모드, REST API | 데몬 모드, API, GitHub Actions |
| **AI 에이전트 연동** | 네이티브 MCP 서버: 읽기 도구 + 액션 도구, 라이브 인터셉트 코파일럿 | Burp AI(Pro) | 네이티브 MCP 서버 없음 | 네이티브 MCP 서버 없음 |
| **팀 협업** | 없음(단일 사용자, 로컬 프로젝트) | 지원(Pro, 스캔 공유) | 지원(프로젝트 공유, 실시간 동기화) | 내장 기능 없음 |

## Gori가 다른 점 {#where-gori-differs}

- **터미널 네이티브.** 실행할 GUI가 없습니다. Gori는 하나의 바이너리이고 키보드로 동작하며, SSH로도 그대로 씁니다.
- **하나의 엔진, 세 가지 진입점.** TUI, `gori run`, `gori mcp`가 같은 프로젝트와 데이터베이스를 다루므로, 수동 세션과 스크립트나 에이전트가 만든 세션이 같은 상태를 봅니다.
- **MCP는 확장이 아니라 1급 이음새입니다.** 에이전트는 사람이 쓰는 것과 같은 도구 세트를 받고, Intercept에서 라이브 코파일럿 역할도 맡습니다.
- **Probe는 일부러 조용합니다.** 액티브 검사는 안전한 메서드에만, 표면마다 한 번만 나갑니다. Burp나 ZAP의 완전한 액티브 스캐너를 대체하지는 않습니다.

## Gori가 갖추지 못한 것 {#where-gori-doesnt-compete}

- 플러그인/확장 생태계가 없습니다. Burp의 BApp Store, Caido의 플러그인, ZAP의 애드온 마켓플레이스는 기본 설치 상태의 Gori보다 훨씬 많습니다.
- 완전한 자동 액티브 스캐너가 없습니다. 이것이 핵심 워크플로우라면 Burp Pro나 ZAP을 쓰세요.
- 팀 기능이 없습니다. 프로젝트 공유, 실시간 동기화, Markdown/JSON 내보내기 이상의 내장 리포팅이 없습니다.
- 설계상 Windows 빌드와 GUI가 없습니다.

## 다음 단계 {#next-steps}

- [시작하기](/ko/getting-started/): Gori를 설치하고 첫 요청을 캡처합니다
- [스캐닝 & Issues](/ko/guide/scanning/): Probe, Param Miner, Discover 자세히 보기
- [MCP 서버](/ko/guide/mcp/): AI 에이전트가 Gori 프로젝트 안에서 할 수 있는 일
