+++
title = "트리아지와 리포트"
description = "흩어진 발견들을 이슈로 모으고, diff로 수정을 증명하고, 동료가 읽을 수 있는 리포트로 내보냅니다."
weight = 110

[extra]
group = "마무리"
+++

지금쯤이면 발견들이 Probe 탭, Repeater 탭, 그리고 당신의 기억 속에 흩어져 있을 겁니다. 이 플레이북은 그것들을 넘겨줄 수 있는 형태로 모읍니다. 심각도가 붙은 이슈, 그것을 증명하는 diff, 그리고 gori 없이도 동료가 읽을 수 있는 리포트로요. 약 10분이 걸립니다. 여기서는 새 트래픽을 거의 보내지 않습니다 — 이미 캡처한 것으로 작업합니다.

> **시작하기 전에.** 리포트로 쓸 만한 캡처·테스트 트래픽이 담긴 엔게이지먼트가 필요합니다 — 앞선 플레이북을 먼저 끝내거나, 당신의 프로젝트를 가져오세요. 예시는 `api.example.com`을 대역으로 씁니다.

## 1. 패시브 발견 훑어보기 {#1-skim-passive-findings}

**Probe**는 당신이 캡처하는 모든 플로우와 모든 Repeater 전송에 대해 패시브 검사를 돌립니다. 추가 비용이 없습니다 — 이 발견을 만들려고 요청이 당신의 머신을 떠나지 않습니다 — 그래서 여기가 가장 값싼 출발점입니다. **Probe** 탭을 여세요. 발견은 검사와 호스트로 묶여 있어, 한 행이 수십 건의 히트를 대표할 수 있습니다(관대한 CORS, 누락된 보안 헤더, 쿠키 위생, URL 속 시크릿 등).

행을 열면 **AFFECTED URLS** 목록이 증거입니다. `↑`/`↓`로 훑고, `Enter`로 그 URL이 캡처된 플로우를 History와 같은 상세 뷰로 열며, `r`로 Repeater에 보내 더 파고듭니다.

같은 집합을 헤드리스로 읽을 수 있고, 이 역시 스스로는 아무것도 보내지 않습니다:

```bash
gori run probe                       # 패시브 발견만
gori run probe --severity high       # high 심각도 행만
gori run probe --category cors       # 단일 카테고리
```

**체크포인트.** Probe 탭에 발견이 심각도와 카테고리로 묶여 나열되고, 각 항목은 그것이 나온 플로우로 열립니다 — 그리고 이를 만드느라 History의 요청 수는 움직이지 않았습니다.

## 2. 이슈 파일링 {#2-file-an-issue}

**Issues**는 결국 리포트에 넘길 트리아지 목록입니다. **History** 플로우나 Repeater 전송에서 `Shift-F`를 눌러 하나를 파일링하고, **Probe** 발견은 Probe 탭에서 이슈로 승격합니다. 심각도(`info`부터 `critical`까지)와 상태(`open`, `confirmed`, `false-positive`, `resolved`)를 부여하세요. 파일링한 플로우가 증거로 링크되므로 이슈가 스스로 증거를 담습니다 — 이슈에서 `Enter`를 누르면 그 교환으로 바로 돌아갑니다.

<figure class="tui-shot">
  <img src="/images/tui/issues.svg" alt="gori Issues tab listing triaged findings with severity, status, host and title columns, one row selected and its linked evidence flow shown">
  <figcaption><strong>Issues</strong> 탭: 승격한 모든 발견이 심각도와 상태를 갖고, 그것을 증명하는 증거 플로우로 다시 링크됩니다.</figcaption>
</figure>

스크립트에서는 이슈를 직접 파일링·갱신할 수 있습니다 — `--flow`가 같은 동작에서 증거를 링크합니다:

```bash
gori run issues create --title "IDOR on /v1/users/{id}" --severity high --host api.example.com --flow 42
gori run issues update 7 --status confirmed --notes "Verified on staging"
gori run probe promote 12            # Probe 발견을 Issues로 확정
```

**체크포인트.** **Issues** 탭에 심각도와 함께 당신의 이슈가 보이고, 그것을 열면 증거 플로우로 점프합니다.

## 3. Comparer로 증명하기 {#3-prove-it-with-the-comparer}

발견은 이전과 이후를 나란히 놓으면 더 강하게 꽂힙니다 — 인증 없는 `403` 옆에 인증된 `200`, 또는 패치된 응답 옆에 취약한 응답처럼요. **Comparer**는 두 메시지 A와 B를 담아 diff합니다.

요청과 응답이 있는 곳이면 어디서든 슬롯을 채웁니다. **History**에서 첫 플로우를 선택하고 `Space` → **Send to Comparer**를 누르면 슬롯 A에 들어갑니다. 두 번째도 같은 방식으로 보내 슬롯 B를 채웁니다. Repeater 전송이나 Fuzzer 결과 행도 같은 방식으로 들어가며 — 둘 다 캡처된 플로우를 남기지 않으므로, 이것이 그들이 diff로 들어가는 유일한 경로입니다. Comparer 탭에서는 `a` / `b`로 캡처된 플로우를 각 슬롯에 바로 골라 넣습니다.

두 컬럼 사이의 구분선은 한 줄을 읽기도 전에 A→B 델타를 알려 줍니다. `403 → 200`이면 대개 그게 답 전부입니다. `←`/`→`로 요청 diff와 응답 diff를 오가고, 변경된 행에서는 실제로 다른 바이트만 빨강·초록으로 켜지므로, 뒤바뀐 값 하나가 줄을 읽지 않아도 눈에 띕니다.

```bash
gori run compare 41 42 --pane response --changes-only
```

**체크포인트.** diff가 발견을 증명하는 변화를 강조합니다 — `403 → 200` 같은 상태 전환이나, 움직인 그 값 하나를요.

## 4. 노트와 링크 남기기 {#4-keep-notes-and-links}

모든 것이 이슈는 아닙니다. **Notes**는 자유 형식의 프로젝트별 Markdown 문서입니다(프로젝트당 여러 개). 시도한 것, 통한 페이로드, 나중에 다시 볼 단서를 적는 기록장이죠. **Notes** 탭에서 만들고 편집합니다.

흩어진 증거를 하나로 묶으려면 History, Repeater, Fuzzer, Miner에서 `Space` → **Link…**를 누르세요. 하나의 카드에 모든 이슈 *와* 모든 노트가 나열되고, 위에 `+ New issue…` / `+ New note…`가 고정됩니다 — 지금 보고 있는 것을 기존 이슈에 붙이는 것과, 이미 링크된 새 이슈를 파일링하는 것이 같은 키 입력입니다. 입력한 글자는 제목·호스트·상태로 필터링하고, 생성 행에 닿으면 새 이슈의 제목이 됩니다.

```bash
gori run notes create --text "SSRF candidate on /fetch — needs OAST to confirm"
gori run notes --all
```

**체크포인트.** Notes 탭에 노트가 담기고, 링크한 이슈 아래에 증거 플로우나 세션이 나열됩니다.

## 5. 리포트 내보내기 {#5-export-the-report}

이슈 트리아지가 끝나면, gori 없이도 동료가 읽을 수 있는 단일 Markdown 문서로 내보냅니다:

```bash
gori run issues --format markdown --export report.md
```

발견 뒤의 원본 트래픽까지 — 요약본만이 아니라 — 넘기려면, History 쿼리를 하나의 HAR 로그로 내보내세요. STDOUT으로 쓰이고, Burp·Charles·브라우저 네트워크 패널로 불러들일 수 있으며, gori로 그대로 다시 임포트됩니다:

```bash
gori run history -q 'host:api.example.com status:200' --format har > evidence.har
```

**체크포인트.** `report.md`가 디스크에 존재하고 심각도 순으로 정렬된 이슈 목록으로 읽히며, `evidence.har`가 그 뒤의 플로우들을 담습니다.

## 다음 단계 {#next-steps}

- [AI 코파일럿 세션 실행](/ko/playbooks/run-an-ai-co-pilot/): 같은 프로젝트에 에이전트를 붙이고 그 모든 동작을 지켜봅니다
- [Scanning & Issues](/ko/guide/scanning/): Probe, Issues, Notes, Comparer 전체 레퍼런스
- [CLI Reference](/ko/reference/cli/): `run issues`, `run compare`, `run history --format har` 전문
