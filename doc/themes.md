# Custom themes

gori ships five built-in colour themes — `goridark` (default), `goriday`, `latte`,
`espresso`, `tokyonight` — selectable from **`settings:theme`** in the command palette
(`^P`). The picker is a vertical, scrollable list; each row shows a small swatch of the
theme's own palette, and selecting a row previews it live (`↵` applies + persists, `esc`
reverts).

You can add your own themes as JSON files. Drop them in:

```
~/.gori/themes/<name>.json
```

(`~/.gori` is the gori home directory; override it with `$GORI_HOME`.) The **file name**
is the theme name — `ocean.json` becomes the theme `ocean`. They appear in the picker
after the built-ins, in file-name order. gori loads them at startup and again each time
you open `settings:theme`, so you can drop a file in and reopen the picker — no restart.

## Format

A theme is a JSON object mapping palette fields to `#rrggbb` hex colours. Use the
optional `"base"` key to inherit every colour you don't override from a built-in theme —
so a theme can be as small as one accent tweak:

```json
{
  "base": "goridark",
  "accent": "#ff33cc",
  "syn_header": "#33ccff"
}
```

Without `"base"`, the default (`goridark`) supplies any omitted colour.

### A full theme

Every field (all inherit from `base` when omitted):

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

| field           | used for                                             |
| --------------- | ---------------------------------------------------- |
| `bg`            | the canvas (main background)                         |
| `panel`         | top bar, status bar, overlays                        |
| `elevated`      | header bands, active segments                        |
| `border`        | resting hairline dividers                            |
| `border_focus`  | the outline of an active modal card                  |
| `focus_gold`    | the focused body pane's outline                      |
| `accent`        | the highlight colour (selection marker, emphasis)    |
| `accent_bg`     | the selection band in the focused pane               |
| `selection_dim` | the selection band in an unfocused pane              |
| `text`          | body text                                            |
| `text_bright`   | emphasised / active text                             |
| `muted`         | secondary / dimmed text                              |
| `green`         | 2xx status                                           |
| `yellow`        | 4xx status                                           |
| `red`           | 5xx status / errors                                  |
| `orange`        | accent for warnings                                  |
| `syn_header`    | header/field names, JSON keys, tag names             |
| `syn_string`    | quoted strings                                       |
| `syn_number`    | numbers, tag attribute names                         |
| `syn_literal`   | `true` / `false` / `null`                            |

## Notes

- The file name is normalised to lower-case `a–z 0–9 - _`; other characters are dropped
  (`My Theme!.json` → `mytheme`).
- A file whose name collides with a built-in (e.g. `goridark.json`) is ignored — the
  built-ins can't be redefined.
- Loading is tolerant: an unreadable file, invalid JSON, or a non-object is skipped, and
  a single malformed colour falls back to the `base` value rather than discarding the
  whole theme. A broken theme file never crashes the TUI.
- For readability, keep your functional colours (text, status, syntax) well-contrasted
  against `bg`; the built-ins target WCAG AA (≥ 4.5:1).
