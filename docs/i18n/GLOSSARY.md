# Korean glossary and style for gori

One vocabulary for the TUI catalog (`src/gori/i18n/locales/ko.json`) and the docs (`docs/content/**/*.ko.md`), so a word means the same thing on screen and on the page. Pull terms from here before inventing one; add a row when you settle a new one.

## Register

| Surface | Register | Example |
|---|---|---|
| Labels, key legends, verb titles, overlay titles (`ui`) | Terse noun / verb-stem phrase, no sentence ending | `↵ 실행 · esc 닫기`, `플로우 상세 열기` |
| Toasts, notifications (`system`) | Terse result state; 합니다체 only when carrying a consequence or an instruction | `설정 저장됨`, `캡처가 꺼져 있습니다 — c로 시작` |
| Confirm bodies, Help, hints, wizard copy (`help`, confirm bodies in `system`) | 합니다체, as the docs | `이 작업은 되돌릴 수 없습니다.` |
| Miss Ring (`companion`) | 해요체, playful, short; keeps her `!` | `안녕! 준비되면 시작해요` |

No terminal period on a label or a toast. Errors keep the English engine noun as their prefix: `repeater 오류: %{err}`.

## What stays English

gori, Miss Ring, every tab and tool name (History, Repeater, Fuzzer, Miner, OAST, Sequencer, Decoder, JWT, Cookie, Comparer, Rewriter, Colormarker, Probe, Authorize, Issues, Notes, Help, Project, Target, Intercept, Sitemap), setting values (`lively`/`calm`/`still`, `body`/`bar`, `on`/`off`), the READ / INS mode names, "Copy as" tool names (cURL, httpie, wscat …), field identifiers (`status:`, `$KEY`), file and path names, and every language's own name (English, 한국어).

## Tokens and spacing

- Key tokens stay as written and are followed by one space: `^P 명령`, `↵ 열기`, `esc 닫기`, `⇧X`, `←/→`, `space`.
- A space between Hangul and a Latin word or a number (`Repeater 탭`, `플로우 3개`); none before a particle (`Repeater로`, `History에서`).
- Counters: 플로우·요청 → 개/건 (`요청 2건`, `플로우 3개`).
- Separators unchanged: ` · ` between legend fragments, ` — ` between a fact and its consequence, `…` for in progress.
- `%{name}` placeholders and `^X` key tokens must survive translation verbatim (the catalog spec checks both).

## Length budgets (cells; one Hangul syllable is two)

| Where | Budget |
|---|---|
| Focus badge | ≤ 8 |
| Overlay title, key-legend fragment, verb title, settings field hint | ≤ the English cell width |
| Empty-state title | one row |
| Miss Ring's bubble | ≤ 30 |
| Any row-budgeted prose line | ≤ the English cell width |

## Terms

| English | 한국어 |
|---|---|
| toast | 토스트 |
| notification, the ring | 알림 |
| status line / bar | 상태 줄 |
| speech bubble | 말풍선 |
| badge | 배지 |
| mascot / sprite | 마스코트 / 스프라이트 |
| background job | 백그라운드 작업 |
| command palette | 커맨드 팔레트 |
| project picker | 프로젝트 선택기 |
| setup wizard | 설정 마법사 |
| tutorial, the tour | 가이드 투어 |
| hotkey / rebind / unbind | 단축키 / 재지정 / 바인딩 해제 |
| chord | 키 조합 |
| modifier | 모디파이어 |
| sub-tab / strip / chip | 서브탭 / 서브탭 스트립 / 칩 |
| space menu | space 메뉴 |
| scope lens | scope 렌즈 |
| flow / capture / session | 플로우 / 캡처 / 세션 |
| send / resend | 전송 / 재전송 |
| working copy / save / discard | 작업 사본 / 저장 / 버리기 |
| reset to default / factory reset | 기본값으로 초기화 / 공장 초기화 |
| clear (a whole tab) / delete | 비우기 / 삭제 |
| environment variable | 환경 변수 |
| hostname override | 호스트네임 오버라이드 |
| upstream / bind address | 업스트림 / 바인드 주소 |
| forward (intercept) | 포워드 |
| copied | 복사됨 |
| language / follow default / auto | 언어 / 기본값 따름 / 자동 |

Group headers: COMMON 공통 · REQUEST 요청 · RESPONSE 응답 · VIEW 보기 · SEND 보내기 · TRIAGE 분류 · COPY 복사 · SCOPE 스코프 · DANGER 삭제 · WIPE 비우기.
