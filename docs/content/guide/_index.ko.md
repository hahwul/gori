+++
title = "가이드"
description = "gori 워크벤치 심화 가이드 — 프록시, 리피터, 퍼징, 스캐닝, MCP."
+++

gori를 다루는 심화 가이드입니다. TUI의 각 탭은 하나의 목적에 집중한 도구이며, 이들을 합치면 캡처부터 리포트까지 전체 평가 과정을 아우릅니다.

## 주제 {#topics}

- **[Proxy & History](/ko/guide/proxy/)** — 캡처, 인터셉트, 스코프, 임포트, Match & Replace, 호스트 오버라이드.
- **[Repeater & Fuzzer](/ko/guide/repeater-and-fuzzer/)** — 요청 워크벤치, 환경 변수 토큰, Intruder 스타일 Fuzzer.
- **[Decoder](/ko/guide/decoder/)** — TUI 안에서 동작하는 인코드 / 디코드 / 해시 파이프라인.
- **[Scanning & Issues](/ko/guide/scanning/)** — Probe, Param Miner, Issues, Notes, Comparer.
- **[MCP Server](/ko/guide/mcp/)** — AI 에이전트나 스크립트로 gori를 구동합니다.
- **[Themes](/ko/guide/themes/)** — 내장 컬러 테마를 전환하거나 직접 만듭니다.
- **[Hotkeys](/ko/guide/hotkeys/)** — gori의 단축키를 재지정합니다.

## 인터페이스 한눈에 보기 {#the-interface-at-a-glance}

gori는 탭으로 구성됩니다. `[` / `]`로 탭 사이를 이동하거나 숫자 키로 바로 점프합니다. 거의 모든 기능은 두 개의 탐색 표면으로 접근합니다. `Ctrl-P`는 **커맨드 팔레트**(앱 전역)를 열고, `Space`는 **space 메뉴**(포커스된 패널의 동작)를 엽니다. 첫날에 익힐 코드는 [Quick Start](/ko/getting-started/quick-start/)에 있습니다.

| 탭 | 용도 |
|-----|---------|
| **Project** | 홈 — 스코프, 호스트 오버라이드, 환경 변수, 설명, 네트워크 |
| **Sitemap** | 중복 제거된 host → path 엔드포인트 트리 |
| **History** | 캡처(및 임포트)된 플로우와 전체 요청/응답 상세 |
| **Intercept** | 요청/응답을 붙잡아 수동 판단을 대기 |
| **Repeater** | 요청 워크벤치 (WebSocket 및 gRPC 모드 포함) |
| **Fuzzer** | 네 가지 공격 모드를 갖춘 Intruder 스타일 Fuzzer |
| **Miner** | 숨은 파라미터 탐색 (기본 숨김) |
| **Decoder** | 인코드 / 디코드 / 해시 파이프라인 |
| **Comparer** | 두 플로우의 나란한 diff |
| **Probe** | 패시브 및 light-touch 액티브 보안 스캐너 |
| **Issues** | 심각도와 상태로 결과 트리아지 |
| **Notes** | 프로젝트별 마크다운 노트 |
| **Help** | 키 바인딩과 링크 |

탭은 아니지만 전역적으로 작동하는 렌즈들이 있습니다. **Match & Replace**(`m`)는 이동 중인 요청/응답의 헤드와 본문을 재작성하고, **capture**(`c`), **intercept**(`i`), **scope 렌즈**(`s`)는 어디서든 토글할 수 있습니다.
