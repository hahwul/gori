+++
title = "단축키"
description = "settings:hotkeys에서 gori의 단축키를 재지정합니다."
+++

gori의 단축키는 커맨드 팔레트(`Ctrl-P`)의 **`settings:hotkeys`**에서 재지정할 수 있습니다. 에디터는 재지정 가능한 모든 동작을 발생 위치별(GLOBAL, HISTORY, REPEATER, FUZZER, INTERCEPT, …)로 묶어 나열합니다. 행을 고르고, 새 키를 누르면, 끝입니다.

```text
Ctrl-P → settings:hotkeys
```

## 키 예산 (새 단축키가 키를 얻는 방식) {#key-budget-how-new-shortcuts-earn-a-key}

맨 글자 키는 귀합니다. 새 동작은 키를 차지하기 전에 **가격 등급**을 정해야 합니다.

| 등급 | 가격 | 언제 | 예시 |
|------|-------|------|----------|
| **L0 구조적** | `Esc` `Enter` `Tab` 화살표 `Space`(리더) | 항상 | 포커스, 열기/닫기, READ/INS, space 메뉴 |
| **L1 루프** | 맨 글자 또는 스티키 패밀리(`^R`) | 분당 여러 번 | History `j/k` `/` `y`, Repeater 전송 |
| **L2 세션 호흡** | Global 맨 글자 — **상한: `c` `i` `s`만** | 세션당 여러 번 | capture, intercept, scope 렌즈 |
| **L3 맥락적** | `Space` 다음 니모닉 | 가끔, 패널 로컬 | compare, mine, send-group, copy-as |
| **L4 드묾 / 설정** | 팔레트(`Ctrl-P`) 전용 | 드묾 | 설정, Match & Replace, 알림 |

경험칙:

- **새 패널 동작의 기본값은 L3**(space 메뉴 전용)입니다. 루프가 입증된 뒤에야 직접 키로 승격하세요.
- **Ctrl**은 타이핑 중(INS)에도 작동해야 하는 동작이나 파괴적인 동작을 위한 것입니다 — 맨 글자를 손쉽게 승격하는 수단이 아닙니다.
- **History → Repeater**와 **Repeater 전송**은 **`Ctrl-R`**로 유지됩니다(동일한 근육 기억). History→Repeater를 맨 글자 `r`로 옮기지 마세요.
- Match & Replace와 알림은 **키 없이**(팔레트 / 배지) 제공됩니다. Global 코드를 원하면 재지정하세요.

## 편집 {#editing}

에디터는 작업 복사본을 엽니다 — `Enter`를 누르기 전에는 아무것도 저장되지 않으며, `Esc`는 모든 변경을 버립니다.

| 키 | 동작 |
|-----|--------|
| `↑` / `↓` (또는 `j` / `k`), 휠 | 선택 이동 |
| `e` 또는 `Space` | 선택한 동작 재지정 — 그다음 **새 키를 누릅니다** |
| `x` 또는 `Backspace` | 선택한 동작의 바인딩 해제 |
| `r` | 선택한 동작을 기본값으로 초기화 |
| `Shift-R` | 모든 동작을 기본값으로 초기화 |
| `←` / `→` | OS 기본 프로파일 순환(아래 참고) |
| `Enter` | 저장 + 적용(실시간 — 재시작 없음) |
| `Esc` | 버리고 닫기 |

재지정을 시작하면 푸터에 *"press a key to bind"*가 표시됩니다. 아래 *예약된 키*에 나열된 것들을 제외하고, 원하는 코드를 수정자와 함께 누르세요. 키가 예약되어 있거나 **같은 위치**의 다른 동작에서 이미 사용 중이면, 에디터는 이를 거부하고 이유를 알려줍니다. 캡처는 열린 채로 남아 다른 키를 시도할 수 있습니다.

바인딩된 것이 없으면 행의 코드에 `(unbound)`가 표시됩니다. `●` 마커는 기본값에서 변경했음을 뜻하고, `·`은 기본값 상태를 뜻합니다.

## 충돌 {#conflicts}

두 동작은 **다른** 위치에서 발생할 때만 키를 공유할 수 있습니다 — 이는 의도된 동작입니다(`s`는 거의 모든 곳에서 "scope 렌즈"지만 Comparer 탭에서는 "swap", `c`는 Intercept 큐에서 catch 방향을 순환하는 것을 제외하면 어디서나 "toggle capture"). 에디터는 **같은 위치**의 충돌만 막습니다. 거기서는 키맵이 둘 중 하나만 남길 수 있기 때문입니다.

## 예약된 키 {#reserved-keys}

일부 키는 터미널이나 gori가 필요로 하므로 재지정할 수 없습니다.

- **종료** — `Ctrl-C`, `Ctrl-D`.
- **명명된 키와 구별 불가** — `Ctrl-M` / `Ctrl-J` (Enter), `Ctrl-I` (Tab), `Ctrl-H` (Backspace), `Ctrl-[` (Escape).
- **구조적** — `Enter`, `Esc`, `Tab`, `Backspace`, 그리고 맨 `:`(명령줄).
- **키맵보다 먼저 점유되는 gori 단축키** — `Ctrl-G` (go to line), `Ctrl-F` (find), `Ctrl-B` (reveal whitespace), `Ctrl-E` (external editor), `Ctrl-P` (command palette), `Ctrl-N` (new repeater/fuzz/note), `Ctrl-W` (close sub-tab), 그리고 `Ctrl-1`…`Ctrl-9` (switch sub-tab). 이들은 키맵보다 먼저 하드코딩된 가드로 처리되므로, 여기에 바인딩해도 절대 발동하지 않습니다. 같은 이유로 **Command palette**, **New repeater request**, **New fuzz session**은 에디터에 나열되지 않습니다 — 그 키는 고정입니다.

`Ctrl-S` 같은 흐름 제어/시그널 코드는 예약되어 있지 **않습니다** — gori는 터미널을 raw 모드로 실행하므로 이들이 앱에 도달합니다(Repeater의 SNI 토글은 `Ctrl-S`로 제공됩니다).

## OS 기본 프로파일 {#os-default-profiles}

`←` / `→` 프로파일 선택기는 새(재정의되지 않은) 바인딩이 어떤 **기본** 키 세트를 사용할지 고릅니다: `auto`(gori가 빌드된 플랫폼을 추적), `macOS`, `Linux`, `Windows`. 직접 지정한 재바인딩은 OS와 무관하게 항상 선택한 프로파일 위에 얹힙니다.

현재 OS별 기본값은 동일합니다. 터미널에서 `Ctrl`+글자 코드는 macOS, Linux, Windows 모두에서 애플리케이션에 도달하며, 정말 위험한 키는 위의 예약된 제어 문자들입니다(어디서나 차단됨). 프로파일 메커니즘은 실제 터미널별 충돌이 생겼을 때 디스패치를 건드리지 않고 바로잡을 수 있도록 마련해 둔 것입니다 — 지금으로서는 `auto`가 모두에게 옳은 선택입니다.

## 저장 위치 {#where-its-stored}

`~/.gori/settings.json`(디렉터리는 `$GORI_HOME`으로 재정의)의 희소한 `hotkeys` 블록에 저장됩니다 — 변경한 바인딩만 동작 id별 코드 라벨 목록으로 기록되며, 빈 목록은 명시적 바인딩 해제입니다.

```json
{
  "hotkeys": {
    "os": "auto",
    "bindings": {
      "rules.edit": ["g"],
      "scope.edit": []
    }
  }
}
```

없는 동작은 프로파일 기본값을 사용합니다. 알 수 없는 id와 파싱 불가능한 코드는 로드할 때 무시되므로, 수동 편집이나 버전 차이가 있어도 무리 없이 동작합니다.

## 제약 {#limitations}

- 동작의 **주** 코드만 표시/편집됩니다. 탐색 별칭(예: `j` / `k`의 화살표 키 중복)은 나열되지 않습니다.
- **커맨드 팔레트**와 **Help** 탭(verb id에 연결된 Global / History / Repeater 행)은 재지정 후 유효 키맵을 통해 코드를 해석합니다. 다른 Help 섹션과 일부 상태 칩은 여전히 정제된 기본값을 사용할 수 있습니다.
- Space 메뉴 **니모닉** 글자는 동작을 가리키는 안정적인 식별자입니다(Helix와 비슷). 재지정은 *직접* 코드만 바꿀 뿐 space 메뉴 글자는 바꾸지 않습니다.
- 한 글자를 공유하는 패널 로컬 키(Repeater 응답 `x` = hex 대 요청/대상 `x` = 줄 선택)는 두 의미가 공존할 수 있도록 컨트롤러 소유로 유지됩니다.
- 탐색 가능한 컨텍스트에서 **`?`**를 누르면 **Help** 탭(mitmproxy 스타일 치트시트)으로 점프합니다.

## 다음 단계 {#next-steps}

- [Themes](/ko/guide/themes/) — 같은 방식으로 컬러 테마를 전환하거나 만듭니다
- [Configuration Reference](/ko/reference/config/) — `settings.json`의 `hotkeys` 키
