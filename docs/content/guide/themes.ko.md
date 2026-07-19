+++
title = "테마"
description = "gori의 내장 컬러 테마를 전환하거나, 직접 만든 테마를 넣습니다."
+++

gori는 26개의 내장 컬러 테마를 제공합니다: `goridark`(기본값), `goriday`, `latte`, `espresso`, `tokyonight`, `gruvbox`, `nord`, `dracula`, `solarized_light`, `rosepine_dawn`, `catppuccin_mocha`, `monokai`, `everforest`, `onedark`, `kanagawa`, `github_dark`, `zenburn`, `synthwave84`, `cyberpunk`, `matrix`, `cobalt2`, `high_contrast`, `github_light`, `gruvbox_light`, `one_light`, `ayu_light`.

## 테마 전환 {#switching-themes}

`Ctrl-,`(또는 상단 바의 `⚙` 칩)로 Preferences를 열고 **Appearance**로 이동한 뒤 **Theme** 행에서 `↵`를 누릅니다. 이 행은 현재 테마를 인라인으로 미리 보여줍니다. 이름과 팔레트 스와치가 함께 표시됩니다. `Ctrl-P` → **`settings:theme`**로 같은 선택기를 한 번에 열 수도 있습니다.

선택기는 세로로 스크롤되는 목록입니다. 각 행은 테마 고유 팔레트의 작은 스와치를 보여주며, 행을 선택하면 실시간으로 미리보기가 나타납니다. `Enter`는 선택을 적용하고 유지하며, `Esc`는 되돌립니다.

`Ctrl-,`는 프로젝트 선택기에서도 동작하므로, 프로젝트를 열기 전 첫 실행에서 테마를 정할 수 있습니다. 그곳에서 편집할 수 있는 섹션은 Theme뿐이고, 나머지는 프로젝트를 열어야 합니다.

같은 History 뷰를 내장 테마 네 개에서 나란히 본 모습입니다.

<div class="tui-gallery">
  <figure>
    <img src="/images/tui/theme-goridark.svg" alt="goridark 테마의 gori History 탭: 은은한 골드 포커스 아웃라인이 있는 거의 검은 캔버스">
    <figcaption>goridark (기본값)</figcaption>
  </figure>
  <figure>
    <img src="/images/tui/theme-goriday.svg" alt="goriday 라이트 테마의 gori History 탭: 어두운 텍스트가 있는 따뜻한 오프화이트 캔버스">
    <figcaption>goriday (라이트)</figcaption>
  </figure>
  <figure>
    <img src="/images/tui/theme-tokyonight.svg" alt="tokyonight 테마의 gori History 탭: 차분한 강조색이 있는 짙은 파란 캔버스">
    <figcaption>tokyonight</figcaption>
  </figure>
  <figure>
    <img src="/images/tui/theme-gruvbox.svg" alt="gruvbox 테마의 gori History 탭: 복고풍 앰버와 그린 강조색이 있는 따뜻한 어두운 캔버스">
    <figcaption>gruvbox</figcaption>
  </figure>
</div>

## 커스텀 테마 {#custom-themes}

직접 만든 테마를 JSON 파일로 추가할 수 있습니다. 다음 위치에 넣으세요.

```
~/.gori/themes/<name>.json
```

(`~/.gori`는 gori 홈 디렉터리입니다. `$GORI_HOME`으로 재정의하세요.) 파일 이름이 테마 이름입니다. `ocean.json`은 테마 `ocean`이 됩니다. 커스텀 테마는 선택기에서 내장 테마 다음에 파일 이름 순으로 나타납니다. gori는 시작 시, 그리고 테마 선택기를 열 때마다 다시 로드하므로, 파일을 넣고 재시작 없이 선택기를 다시 열 수 있습니다.

### 형식 {#format}

테마는 팔레트 필드를 `#rrggbb` 헥스 컬러에 매핑하는 JSON 객체입니다. 선택적 `"base"` 키를 사용하면 재정의하지 않은 모든 색을 내장 테마에서 상속하므로, 테마를 강조색 하나만 손보는 정도로 작게 만들 수 있습니다.

```json
{
  "base": "goridark",
  "accent": "#ff33cc",
  "syn_header": "#33ccff"
}
```

`"base"`가 없으면 기본값(`goridark`)이 생략된 색을 채웁니다.

### 전체 테마 {#a-full-theme}

모든 필드이며, 생략 시 `base`에서 상속합니다.

```json
{
  "base": "goridark",

  "bg":            "#0a0a0b",
  "panel":         "#141417",
  "elevated":      "#1b1b1f",
  "border":        "#2a2a30",
  "border_focus":  "#3a3a42",
  "focus_gold":    "#c2a05a",
  "accent":        "#fafafa",
  "accent_bg":     "#26262c",
  "selection_dim": "#19191c",
  "text":          "#c8c8cc",
  "text_bright":   "#fafafa",
  "muted":         "#6e6e76",
  "green":         "#52c77a",
  "yellow":        "#d6a13a",
  "red":           "#e5534b",
  "orange":        "#d9813f",
  "syn_header":    "#82a8c4",
  "syn_string":    "#8fb87a",
  "syn_number":    "#ca9b6a",
  "syn_literal":   "#b08ec2"
}
```

| 필드 | 사용처 |
|-------|----------|
| `bg` | 캔버스(메인 배경) |
| `panel` | 상단 바, 상태 바, 오버레이 |
| `elevated` | 헤더 밴드, 활성 세그먼트 |
| `border` | 기본 상태의 얇은 구분선 |
| `border_focus` | 활성 모달 카드의 아웃라인 |
| `focus_gold` | 포커스된 본문 패널의 아웃라인 |
| `accent` | 강조색(선택 마커, 강조) |
| `accent_bg` | 포커스된 패널의 선택 밴드 |
| `selection_dim` | 포커스되지 않은 패널의 선택 밴드 |
| `text` | 본문 텍스트 |
| `text_bright` | 강조 / 활성 텍스트 |
| `muted` | 보조 / 흐린 텍스트 |
| `green` | 2xx 상태 |
| `yellow` | 4xx 상태 |
| `red` | 5xx 상태 / 오류 |
| `orange` | 경고용 강조색 |
| `syn_header` | 헤더/필드 이름, JSON 키, 태그 이름 |
| `syn_string` | 따옴표 문자열 |
| `syn_number` | 숫자, 태그 속성 이름 |
| `syn_literal` | `true` / `false` / `null` |

### 참고 {#notes}

- 파일 이름은 소문자 `a-z 0-9 - _`로 정규화되며, 다른 문자는 제거됩니다(`My Theme!.json` → `mytheme`).
- 이름이 내장 테마와 충돌하는 파일(예: `goridark.json`)은 무시됩니다. 내장 테마는 재정의할 수 없습니다.
- 로딩은 너그럽습니다: 읽을 수 없는 파일, 잘못된 JSON, 객체가 아닌 것은 건너뛰며, 잘못된 색 하나는 테마 전체를 버리는 대신 `base` 값으로 폴백합니다. 깨진 테마 파일이 TUI를 죽이는 일은 없습니다.
- 가독성을 위해, 기능적인 색(text, status, syntax)은 `bg`와 충분히 대비되게 유지하세요. 내장 테마는 WCAG AA(≥ 4.5:1)를 목표로 합니다.

## 다음 단계 {#next-steps}

- [Hotkeys](/ko/guide/hotkeys/): 같은 방식으로 gori의 단축키를 재지정합니다
- [Settings](/ko/guide/settings/): Preferences 모달과 그 안의 모든 섹션
- [Configuration](/ko/getting-started/configuration/): `settings.json`이 있는 위치와 그 밖에 담는 내용
