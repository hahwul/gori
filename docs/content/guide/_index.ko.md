+++
title = "가이드"
description = "gori 워크벤치 심화 가이드: 프록시, 리피터, 퍼징, 스캐닝, MCP."
weight = 20
+++

## 읽을 경로 고르기 {#topics}

gori가 처음이라면 [Quick Start](/ko/getting-started/quick-start/)부터 실행하세요. 여러 도구를 넘나드는 작업 중심 실습이 필요하면 [실전 가이드](/ko/playbooks/)를 펼치고, 워크벤치의 한 부분을 깊이 이해하고 싶을 때는 이곳의 가이드를 읽으세요.

## 인터페이스 한눈에 보기 {#the-interface-at-a-glance}

gori는 탭으로 구성됩니다. `[` / `]`로 탭 사이를 이동하거나 숫자 키로 바로 점프합니다. 거의 모든 기능은 두 개의 탐색 표면으로 접근합니다. `Ctrl-P`는 **커맨드 팔레트**(앱 전역)를 열고, `Space`는 **space 메뉴**(포커스된 패널의 동작)를 엽니다. 첫날에 익힐 키 조합은 [Quick Start](/ko/getting-started/quick-start/)에 있습니다.

| 탭 | 용도 |
|-----|---------|
| **Project** | 홈: 스코프, 호스트 오버라이드, 환경 변수, 설명, 네트워크 |
| **Target** | Sitemap(host → path 엔드포인트 트리) + Discover(스파이더 & 디렉터리 브루트포스) + Diff(리테스트: 프로젝트 두 개를 엔드포인트 단위로 비교) |
| **History** | 캡처(및 임포트)된 플로우와 전체 요청/응답 상세 |
| **Intercept** | 요청/응답을 붙잡아 수동 판단을 대기 |
| **Repeater** | 요청 워크벤치 (WebSocket 및 gRPC 모드 포함) |
| **Fuzzer** | 네 가지 공격 모드를 갖춘 Intruder 스타일 Fuzzer |
| **Miner** | 숨은 파라미터 탐색 (기본 숨김) |
| **OAST** | 블라인드 취약점을 위한 아웃오브밴드 콜백 리스너 |
| **Sequencer** | 토큰 무작위성 / 예측 가능성 분석 (기본 숨김) |
| **Decoder** | 인코드 / 디코드 / 해시 파이프라인 |
| **JWT** | JSON Web Token 디코드, 재서명, 공격 (기본 숨김) |
| **Cookie** | Flask / Rack / Django 세션 쿠키 디코드, 검증, 크랙, 재서명 (기본 숨김) |
| **Comparer** | 두 플로우를 나란히 놓고 비교 |
| **Rewriter** | 오가는 트래픽을 그 자리에서 재작성하는 Match & Replace 규칙 |
| **Colormarker** | 쿼리로 History 행 색을 칠하는 규칙 (기본 숨김) |
| **Probe** | 패시브 및 light-touch 액티브 보안 스캐너 |
| **Authorize** | 요청을 여러 아이덴티티로 재전송해 접근 제어 결함 탐지 (기본 숨김) |
| **Issues** | 심각도와 상태로 결과 트리아지 |
| **Notes** | 프로젝트별 마크다운 노트 |
| **Help** | 키 바인딩과 링크 |

일부 탭(Miner, Sequencer, Cookie, Colormarker, Authorize)은 탭 바를 깔끔하게 유지하려고 새 설치에서 숨겨져 있습니다. 탭 바의 `⋯` 메뉴, 커맨드 팔레트, 또는 Preferences(`Ctrl-,`) → **Network & Tabs** → **Tabs**에서 언제든 다시 표시할 수 있습니다. 탭은 아니지만 전역적으로 작동하는 렌즈들도 있습니다. **capture**(`c`), **intercept**(`i`), **scope 렌즈**(`s`)는 어디서든 토글할 수 있습니다.
