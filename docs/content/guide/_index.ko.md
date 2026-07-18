+++
title = "가이드"
description = "gori 워크벤치 심화 가이드: 프록시, 리피터, 퍼징, 스캐닝, MCP."
+++

gori를 다루는 심화 가이드입니다. TUI의 각 탭은 하나의 목적에 집중한 도구이며, 이들을 합치면 캡처부터 리포트까지 전체 평가 과정을 아우릅니다.

## 주제 {#topics}

- **[Proxy & History](/ko/guide/proxy/)**: 캡처, 인터셉트, 스코프, 임포트, Match & Replace, 호스트 오버라이드.
- **[Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/)**: 요청 워크벤치, 환경 변수 토큰, Intruder 스타일 Fuzzer.
- **[Decoder](/ko/guide/decoder/)**: TUI 안에서 동작하는 인코드 / 디코드 / 해시 파이프라인.
- **[JWT](/ko/guide/jwt/)**: JSON Web Token을 디코드, 재서명, 공격합니다.
- **[Sequencer](/ko/guide/sequencer/)**: 세션·CSRF 토큰의 무작위성을 평가합니다.
- **[OAST](/ko/guide/oast/)**: 아웃오브밴드 콜백을 잡아 블라인드 취약점을 확인합니다.
- **[Scanning & Issues](/ko/guide/scanning/)**: Probe, Param Miner, Discover(스파이더 & 브루트포스), Issues, Notes, Comparer.
- **[MCP Server](/ko/guide/mcp/)**: AI 에이전트나 스크립트로 gori를 구동합니다.
- **[Themes](/ko/guide/themes/)**: 내장 컬러 테마를 전환하거나 직접 만듭니다.
- **[Hotkeys](/ko/guide/hotkeys/)**: gori의 단축키를 재지정합니다.

## 인터페이스 한눈에 보기 {#the-interface-at-a-glance}

gori는 탭으로 구성됩니다. `[` / `]`로 탭 사이를 이동하거나 숫자 키로 바로 점프합니다. 거의 모든 기능은 두 개의 탐색 표면으로 접근합니다. `Ctrl-P`는 **커맨드 팔레트**(앱 전역)를 열고, `Space`는 **space 메뉴**(포커스된 패널의 동작)를 엽니다. 첫날에 익힐 코드는 [Quick Start](/ko/getting-started/quick-start/)에 있습니다.

| 탭 | 용도 |
|-----|---------|
| **Project** | 홈: 스코프, 호스트 오버라이드, 환경 변수, 설명, 네트워크 |
| **Target** | Sitemap(host → path 엔드포인트 트리) + Discover(스파이더 & 디렉터리 브루트포스) |
| **History** | 캡처(및 임포트)된 플로우와 전체 요청/응답 상세 |
| **Intercept** | 요청/응답을 붙잡아 수동 판단을 대기 |
| **Rewriter** | 이동 중인 트래픽을 재작성하는 Match & Replace 규칙 (기본 숨김) |
| **Repeater** | 요청 워크벤치 (WebSocket 및 gRPC 모드 포함) |
| **Fuzzer** | 네 가지 공격 모드를 갖춘 Intruder 스타일 Fuzzer |
| **Miner** | 숨은 파라미터 탐색 (기본 숨김) |
| **OAST** | 블라인드 취약점을 위한 아웃오브밴드 콜백 리스너 |
| **Sequencer** | 토큰 무작위성 / 예측 가능성 분석 (기본 숨김) |
| **Decoder** | 인코드 / 디코드 / 해시 파이프라인 |
| **JWT** | JSON Web Token 디코드, 재서명, 공격 (기본 숨김) |
| **Comparer** | 두 플로우의 나란한 diff |
| **Probe** | 패시브 및 light-touch 액티브 보안 스캐너 |
| **Issues** | 심각도와 상태로 결과 트리아지 |
| **Notes** | 프로젝트별 마크다운 노트 |
| **Help** | 키 바인딩과 링크 |

일부 탭(Rewriter, Miner, Sequencer, JWT)은 탭 바를 깔끔하게 유지하려고 새 설치에서 숨겨져 있습니다. 탭 바의 `⋯` 메뉴, 커맨드 팔레트, 또는 **Settings: Tabs**에서 언제든 다시 표시할 수 있습니다. 탭은 아니지만 전역적으로 작동하는 렌즈들도 있습니다. **capture**(`c`), **intercept**(`i`), **scope 렌즈**(`s`)는 어디서든 토글할 수 있습니다.
