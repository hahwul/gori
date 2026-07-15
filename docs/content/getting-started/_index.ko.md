+++
title = "시작하기"
description = "gori를 설치하고, CA를 신뢰하고, 첫 요청을 캡처합니다."
+++

gori에 오신 것을 환영합니다. 이 섹션은 아무것도 없는 상태에서 실제 동작하는 프록시 세션까지 안내합니다. History에 흐르는 트래픽, 손끝에 익힌 Day-1 단축키 몇 개, 그리고 첫 Repeater까지 다룹니다.

## 배울 내용 {#what-youll-learn}

1. gori를 설치하고 빌드하는 방법
2. 프록시를 시작하고 루트 CA를 신뢰하는 방법(사전 신뢰된 브라우저 포함)
3. 첫 플로우를 캡처하고, 필터링하고, 살펴보기
4. 두 가지 탐색 표면: 커맨드 팔레트(`Ctrl-P`)와 space 메뉴(`Space`)
5. 플로우를 Repeater / Fuzzer로 보내고 한 번 전송해 보기
6. gori가 데이터를 저장하는 위치와 설정 방법

## gori란? {#what-is-gori}

gori(고리 — 한국어로 *ring, link, loop*)는 전적으로 터미널에서 동작하는 키보드 중심 HTTP/HTTPS **인터셉트 프록시**이자 웹 해킹 툴킷입니다. 클라이언트와 대상 사이의 *루프에 자리 잡아*, 모든 요청/응답을 *플로우*로 기록하고, 그 트래픽을 살펴보고, Repeater로 재전송하고, 퍼징하고, 스캔할 수 있는 펜테스트 워크벤치를 제공합니다. 셸을 벗어나지 않고도 온전한 평가를 수행할 수 있습니다.

gori는 **HTTP/1.1, HTTP/2, WebSocket, gRPC, Server-Sent Events**를 이해하며, JWT, SAML, GraphQL 같은 일반적인 형식을 인라인으로 디코드합니다. TUI에서 할 수 있는 모든 작업은 `gori run`과 내장 [MCP 서버](/ko/guide/mcp/)를 통해 비대화식으로도 접근할 수 있어, 에이전트와 스크립트가 동일한 프로젝트를 다룹니다.

## 다음 단계 {#next-steps}

- [설치](/ko/getting-started/installation/) — Homebrew, AUR, Docker, 바이너리, 또는 소스에서 빌드
- [빠른 시작](/ko/getting-started/quick-start/) — 캡처, 단축키, 그리고 첫 Repeater
- [설정](/ko/getting-started/configuration/) — 설정, 저장소, 그리고 CA
