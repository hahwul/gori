+++
title = "플레이북"
description = "하나의 gori 워크플로우를 처음부터 끝까지 따라 실행하는 실습 문서 — 스코프, 매핑, 인터셉트, 퍼징, 리포트까지 체크포인트를 하나씩 밟습니다."
weight = 15
+++

[Quick Start](/ko/getting-started/quick-start/)는 코어 루프에서 끝납니다. 요청을 캡처하고, Repeater로 보내고, 바꾸고, 다시 보내는 것까지요. 플레이북은 그다음입니다. 하나의 워크플로우를 처음부터 끝까지 실행하되, 매 단계 끝에 체크포인트를 두어 지금 제대로 가고 있는지 늘 확인하게 합니다.

이 문서들은 레퍼런스가 아닙니다. [Guide](/ko/guide/)는 각 탭을 도구 하나씩 깊이 있게 다루지만, 플레이북은 실제 평가가 그러하듯 탭을 넘나들며 하나의 작업을 끝냅니다. 캡처 전에 스코프를 잡고, 퍼징 전에 캡처하고, 파일링 전에 확인합니다. 도구가 *무엇인지* 알고 싶으면 Guide를, 그것으로 *무엇을 할지* 배우고 싶으면 플레이북을 펼치세요.

> **시작하기 전에.** 플레이북은 실제 트래픽을 보냅니다. 당신이 테스트 권한을 가진 대상(자신의 앱, 스테이징 서버, 또는 의도적으로 취약하게 만든 연습 대상)에만 gori를 겨누고, 그 대상을 [스코프](/ko/guide/proxy/#scope) 안에 두세요. 정확한 결과가 필요한 단계에서는 `example.com` 같은 안정적인 대상을 씁니다. 각 단계는 **체크포인트**로 끝납니다. 다음으로 넘어가기 전에 무엇이 보여야 하는지 알려 줍니다.

## 주제 {#topics}

**기초** — 대상을 건드리기 전에 가드레일부터:

- **[엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)**: 프로젝트, 스코프, 샌드박스 — 이것들 없이는 왜 모든 액티브 도구가 발동을 거부하는지.
- **[공격면 매핑](/ko/playbooks/map-the-attack-surface/)**: 사이트맵을 만들고, 클릭하지 않은 경로를 Discover가 찾게 합니다.

**수동 루프** — 직접 손으로 하는 테스트의 핵심:

- **[플로우 중 가로채기 및 수정](/ko/playbooks/intercept-and-modify/)**: 요청을 붙잡아 바꿔 흘려보내고, 그 편집을 규칙으로 고정합니다.
- **[파라미터 퍼징](/ko/playbooks/fuzz-a-parameter/)**: 위치를 표시하고, 워드리스트를 붙이고, 눈에 띄는 결과를 읽습니다.
- **[세션 유지](/ko/playbooks/carry-a-session/)**: 토큰을 한 번 추출해 모든 요청과 모든 스윕에 인증 상태로 재생합니다.

**워크벤치** — 각각 한 가지 일에 집중한 도구:

- **[데이터 디코드와 변환](/ko/playbooks/decode-and-transform/)**: 변환기를 이어 붙여 저장·재사용 가능한 파이프라인을 만듭니다.
- **[JWT 공격](/ko/playbooks/attack-a-jwt/)**: 토큰을 디코드하고, 클레임을 변조하고, 서버가 서명을 검사하는지 시험합니다.
- **[세션 쿠키 크랙과 위조](/ko/playbooks/crack-and-forge-cookies/)**: 서명된 Flask/Rack/Django 쿠키를 읽고, 비밀키를 복구하고, 직접 만듭니다.
- **[토큰 랜덤성 평가](/ko/playbooks/grade-token-randomness/)**: 세션 토큰 수백 개를 모아 Sequencer가 예측 가능성을 채점하게 합니다.
- **[OAST로 블라인드 취약점 확인](/ko/playbooks/confirm-blind-vulns-oast/)**: 아웃오브밴드 페이로드를 심고, 그것이 발동했음을 증명하는 콜백을 잡습니다.

**마무리** — 발견을 리포트로, 또는 프로젝트를 에이전트에게:

- **[트리아지와 리포트](/ko/playbooks/triage-and-report/)**: 이슈를 파일링하고, Comparer로 수정을 증명하고, 동료가 읽을 리포트를 내보냅니다.
- **[AI 코파일럿 세션 실행](/ko/playbooks/run-an-ai-co-pilot/)**: MCP로 같은 프로젝트에 에이전트를 붙이고, 그 모든 동작을 지켜봅니다.

## 다음 단계 {#next-steps}

- [Quick Start](/ko/getting-started/quick-start/): 아직 안 했다면, 코어 루프까지 10분 경로
- [Guide](/ko/guide/): 플레이북이 다루는 모든 도구의 심화 레퍼런스
- [Reference](/ko/reference/): 모든 CLI 서브커맨드, 설정 키, 쿼리 언어 필터
