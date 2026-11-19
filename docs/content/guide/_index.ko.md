+++
title = "HTTP 프록시와 웹 보안 가이드"
description = "HTTP 인터셉트, Repeater, 퍼징, 스캐닝, MCP 워크플로우를 다루는 gori 심화 가이드입니다."
weight = 20
+++

## 읽을 경로 고르기 {#topics}

gori가 처음이라면 [Quick Start](/ko/getting-started/quick-start/)부터 실행하세요. 여러 도구를 넘나드는 작업 중심 실습이 필요하면 [실전 가이드](/ko/playbooks/)를 보세요. 이곳의 가이드는 워크벤치의 한 부분을 깊이 다룹니다.

## 인터페이스 한눈에 보기 {#the-interface-at-a-glance}

gori는 탭으로 구성됩니다. `[` / `]`로 탭 사이를 이동하거나 숫자 키로 바로 점프합니다. 키 두 개면 모든 동작에 접근할 수 있습니다. `Space`는 **space 메뉴**(포커스된 패널에서 가장 자주 하는 동작, 동작마다 글자 하나)를 열고, `Ctrl-P`는 **커맨드 팔레트**(아무 동작이나 이름으로 찾기)를 엽니다. 둘 다 [space 메뉴와 팔레트](/ko/guide/space-menu-and-palette/)에서 다룹니다. 첫날에 익힐 키 조합은 [Quick Start](/ko/getting-started/quick-start/)에 있습니다.

| 탭 | 용도 |
|-----|---------|
| **Project** | 홈: 스코프, 호스트 오버라이드, 환경 변수, 설명과 태그, 네트워크 |
| **Target** | Sitemap(host → path 엔드포인트 트리) + Discover(스파이더 & 디렉터리 브루트포스) + Diff(리테스트: 프로젝트 두 개를 엔드포인트 단위로 비교) + Params(엔드포인트별 파라미터 목록) |
| **History** | 캡처(및 임포트)된 플로우와 전체 요청/응답 상세 |
| **Intercept** | 요청/응답을 붙잡아 두고 수동으로 판단 |
| **Repeater** | 요청 워크벤치 (WebSocket 및 gRPC 모드 포함) |
| **Fuzzer** | 네 가지 공격 모드를 갖춘 Intruder 스타일 Fuzzer |
| **Miner** | 숨은 파라미터 탐색 (기본은 `0` 뒤) |
| **OAST** | 블라인드 취약점을 위한 아웃오브밴드 콜백 리스너 (기본은 `0` 뒤) |
| **Sequencer** | 토큰 무작위성 / 예측 가능성 분석 (기본은 `0` 뒤) |
| **Decoder** | 인코드 / 디코드 / 해시 파이프라인 (기본은 `0` 뒤) |
| **JWT** | JSON Web Token 디코드, 재서명, 공격 (기본은 `0` 뒤) |
| **Cookie** | Flask / Rack / Django 세션 쿠키 디코드, 검증, 크랙, 재서명 (기본은 `0` 뒤) |
| **Comparer** | 두 플로우를 나란히 놓고 비교 (기본은 `0` 뒤) |
| **Rewriter** | 오가는 트래픽을 그 자리에서 재작성하는 Match & Replace 규칙 (기본은 `0` 뒤) |
| **Colormarker** | 쿼리로 History 행 색을 칠하는 규칙 (기본은 `0` 뒤) |
| **Probe** | 패시브 및 light-touch 액티브 보안 스캐너 |
| **Authorize** | 요청을 여러 아이덴티티로 재전송해 접근 제어 결함 탐지 (기본은 `0` 뒤) |
| **Issues** | 심각도와 상태로 결과 트리아지 |
| **Evidence** | 동결된 요청/응답 스냅숏 보관함 (첫 스냅숏이 생기면 나타남) |
| **Notes** | 프로젝트별 마크다운 노트 |
| **Help** | 키 바인딩과 링크 (기본은 `0` 뒤, 어디서든 `?`를 누르면 키 목록이 팝업으로 열림) |

탭 바에는 번호가 붙은 슬롯이 아홉 개 있습니다. 새로 설치하면 가장 자주 쓰는 탭으로 채워집니다.

```text
1:Project  2:Target  3:History  4:Intercept  5:Repeater  6:Fuzzer  7:Probe  8:Issues  9:Notes   0:Tabs
```

`1`-`9`로 슬롯에 점프하고, 나머지 열두 개는 **`0`**을 눌러 타이핑으로 거르는
카탈로그 목록에서 엽니다. `0` 뒤에는 가끔 여는 탭(OAST, Decoder,
JWT, Comparer, Rewriter)과 특수 워크벤치(Miner, Sequencer, Cookie, Colormarker, Authorize),
그리고 Help가 있습니다. Help의 키 목록은 어디서든 `?`를 누르면 팝업으로 열립니다. **Evidence**도 `0` 뒤에 있으며, 프로젝트에 첫 동결
스냅숏이 생긴 뒤에만 목록에 나타납니다.

아홉 개의 구성은 Preferences(`Ctrl-,`) → **Network & Tabs** → **Tabs** 또는 팔레트의
`settings:tabs`에서 바꿉니다. 이음선 위의 행들이 순서대로 아홉 슬롯이고
아래는 `0`으로 여는 탭들이며, 슬롯 번호는 옮길 때마다 다시 매겨집니다. `⇧K`/`⇧J`로 행을 옮기는데
이음선을 넘겨 위로 올리면 그 탭이 바에 올라가고 마지막 슬롯이 내려갑니다.
`space`는 행을 곧장 반대편으로 보냅니다. 상한 없는 예전
바를 원하면 **Display → Tab bar slots**를 끄세요. `0`은 어느 쪽이든 동작합니다.

탭이 아닌 전역 렌즈도 있습니다. **capture**(`c`), **intercept**(`i`),
**scope 렌즈**(`s`)는 어디서든 토글할 수 있습니다.
