+++
title = "공격면 매핑"
description = "스코프가 걸린 캡처를 host→path 트리로 접고, Discover로 한 번도 클릭하지 않은 엔드포인트를 드러냅니다."
weight = 20

[extra]
group = "기초"
+++

캡처는 평평한 로그이고, 공격면은 형태입니다. 이 플레이북은 캡처된 History를 중복 제거된 `host → path` 트리로 접고, 형태를 가리는 id 노이즈를 접은 뒤, Discover로 어떤 클릭도 닿지 않은 엔드포인트까지 끌어옵니다. 약 10분이 걸리며, 대부분은 Discover가 백그라운드에서 도는 시간입니다.

> **시작하기 전에.** [엔게이지먼트 준비](/ko/playbooks/set-up-an-engagement/)를 끝내 프로젝트와 스코프가 자리 잡게 하고, **History**에 접을 행이 쌓일 만큼 대상을 둘러보세요. 3단계는 실제로 요청받지 않은 트래픽을 보냅니다 — 테스트 권한이 있는 호스트에만 실행하세요. 예시는 `api.example.com`을 대역으로 씁니다.

## 1. 둘러보며 맵의 씨앗 심기 {#1-browse-to-seed-the-map}

캡처를 켠 채(`c`로 토글) 실제 사용자처럼 앱을 클릭해 둘러봅니다 — 로그인하고, 주요 화면을 열고, 폼을 제출하세요. 그런 다음 **Target → Sitemap**을 엽니다. History의 모든 플로우를 중복 제거된 `host → path` 트리로 접고, 각 엔드포인트에 method 칩을, 옆으로 scope 마커를 달아, 수백 개의 행을 열몇 개의 경로로 읽게 해 줍니다.

```bash
gori run sitemap
```

트리는 캡처 위의 뷰일 뿐 두 번째 사본이 아닙니다 — 다음에 둘러보는 것이 도착하는 즉시 나타납니다. `--in-scope`는 스코프 렌즈처럼 in-scope 호스트로 한정합니다.

<figure class="tui-shot">
  <img src="/images/tui/sitemap.svg" alt="캡처된 호스트가 method 칩과 호스트별 경로 수와 함께 경로 트리로 펼쳐진 gori Sitemap 탭">
  <figcaption><strong>Sitemap</strong>은 캡처를 method 칩과 scope 마커가 달린 <code>host → path</code> 트리로 접습니다 — 곧 테스트할 공격면의 형태입니다.</figcaption>
</figure>

**체크포인트.** 대상 호스트가 경로 트리로 펼쳐지고, 각 경로에 method 칩이 붙습니다.

## 2. 시끄러운 id 접기 {#2-fold-noisy-ids}

REST API는 식별자 아래에 형태를 파묻습니다. `/user/1`, `/user/2`, `/order/9f3c…`는 백 개의 얼굴을 쓴 하나의 엔드포인트입니다. `g`를 눌러 path-param id를 접으면, `/user/1`과 `/user/2`가 한 노드를 공유하고 긴 id는 하나의 `{uuid}`로 접힙니다. 거의 똑같던 행의 벽이 그 뒤에 있는 몇 안 되는 진짜 엔드포인트로 바뀝니다.

```bash
gori run sitemap            # id를 기본으로 접습니다; --no-group은 전부 보여 줍니다
```

**체크포인트.** 숫자와 uuid 모양의 세그먼트가 각각 한 노드로 접히고, 트리가 뚜렷한 엔드포인트만 남도록 줄어듭니다.

## 3. Discover로 한 번도 클릭하지 않은 것 찾기 {#3-find-what-you-never-clicked-with-discover}

Sitemap은 당신이 둘러본 것만 압니다. **Discover**는 나머지를 찾습니다. 클릭하지 않은 링크를 spider로 따라가고, 대상이 스스로 밝히는 것(`robots.txt`, `sitemap.xml`, `.well-known/` 레지스트리)과 JavaScript에 인용된 경로를 읽은 뒤, 링크되지 않은 디렉터리(`/admin`, `.git/config`, `/api/v2`)를 brute-force합니다. **Target → Discover**를 열거나, **Sitemap** 노드 또는 **History** 플로우에서 `Space`를 눌러 **Discover here**를 고르면 실행이 그 서브트리로 한정됩니다. 팝업에서 탐색 방식(spider, brute-force, 또는 둘 다), 최대 깊이, 크롤 스코프, 동시성을 고릅니다. 실행은 백그라운드에서 일어나며, Discover 서브탭에서 `^X`로 멈추거나 `p`로 일시정지합니다.

```bash
gori run discover --target https://api.example.com \
  --max-depth 3 \
  --extensions php,json,bak \
  --format jsonl
```

> Discover는 대상에 실제로 요청받지 않은 트래픽을 보냅니다 — 추측하는 모든 경로마다 실제 요청 하나씩. 테스트 권한이 있는 시스템에만 실행하세요. 실행은 프로젝트 스코프 안에 머물고, 샌드박스와 exclude 규칙은 항상 존중됩니다.

**체크포인트.** 둘러본 적 없는 새 경로가 Sitemap에 나타나고, 실행 요약이 무엇을 찾았고 캘리브레이터가 무엇을 억제했는지 알려 줍니다.

## 4. 공격면 읽고 손대기 {#4-read-and-act-on-the-surface}

Discover 발견은 단순한 URL이 아닙니다 — gori는 그것이 구성한 요청과 origin이 돌려준 응답을 저장하므로, 트리는 당신이 읽을 수 있는 증거입니다. 발견된 노드를 선택하고 `Enter`를 누르면 History와 같은 상세 뷰에서 그 교환이 열립니다: 헤더, 본문, 정렬된 JSON. 거기서 `^R`로 **Repeater**에 보내 손으로 찔러 보기 시작합니다.

트리아지하면서 중요한 경로를 `t`로 마킹하고(`t`를 연달아 누르면 연속된 행이 마킹됩니다), `Space` 메뉴로 태그를 달거나 바로 여기서 호스트를 스코프에 추가해, 신경 쓰는 엔드포인트가 다음 캡처까지 살아남게 하세요. 아무것도 스스로 트래픽을 보내지 않습니다 — 무엇을 열고 무엇을 쫓을지는 당신이 정합니다.

**체크포인트.** 발견된 엔드포인트를 열어 실제 응답을 읽고, 그것을 Repeater로 넘길 수 있습니다.

## 다음 단계 {#next-steps}

- [플로우 중 가로채기 및 수정](/ko/playbooks/intercept-and-modify/): 이 요청 중 하나를 잡아 와이어에서 바꿉니다
- [Proxy & History](/ko/guide/proxy/#sitemap): Sitemap 전체 레퍼런스, 접기, 마킹
- [Scanning & Issues](/ko/guide/scanning/): Discover의 캘리브레이션, 봉쇄, headless 플래그 심화
