require "../spec_helper"
require "../support/memory_backend"

include Gori::Tui

# `frame.cr` owns the card chrome — the rounded card, the tee'd divider, the scroll gauge, the
# annotation that rides a top border. The workbench tabs (Repeater, Fuzzer, Discover, Miner,
# Sequencer, …) had always drawn through it. The policy and settings pages had not: they
# hand-rolled the same three devices per file, and the copies drifted.
#
# These examples pin the two drifts that were measurable in source, so the next card added to
# this family inherits the shared geometry instead of a fresh copy of it.
describe "shared card chrome" do
  root = File.join(__DIR__, "..", "..", "src", "gori", "tui")

  it "puts no hand-rolled border annotation where Frame.border_meta belongs" do
    # The tell: a `screen.text` positioned by `rect.right - meta.size - N` — the right-aligned
    # meta each card used to place itself. Six files carried one, with five different guard
    # constants (+10 / +14 / +16 / +18 / +20) for the same layout, so sibling cards dropped
    # their count at different widths. None of the numbers was derived from the title they
    # were protecting; `Frame.border_meta` derives it.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "frame.cr"
      File.read(path).lines.each_with_index do |line, i|
        next unless line.includes?("screen.text")
        next unless line.matches?(/\.right\s*-\s*meta\./)
        # Only a TOP-BORDER annotation, which is what the helper owns: the y argument is the
        # card's own `.y`. A right-aligned meta on a LIST ROW (project_picker draws each
        # project's flow count that way) is a different device at a per-row `y`, and forcing it
        # through a border helper would be the opposite mistake.
        next unless line.matches?(/,\s*\w+\.y\s*,/)
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end

  it "leaves the ‹/› cycler to Frame.option_cycle" do
    # Three dialects had grown for one control: the full strip (four rule forms, byte-identical
    # private copies), the lit value alone (OAST provider, the Scope form's `kind:` row), and a
    # value with the cue in its own colour drawn on every row whether focused or not (Miner,
    # Sequencer, Probe active, Compact, Discover). The middle one is the costly one — a form
    # whose entire first question is "include or exclude?" showed only the current answer.
    #
    # Colormarker's colour row is the sole exception and draws its own: each option carries a
    # hue swatch, which no generic renderer can place. It is required to spell the cue the
    # same way, which is what this check enforces for it.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "frame.cr"
      File.read(path).lines.each_with_index do |line, i|
        next unless line.includes?("‹/›")
        next unless line.includes?("screen.text")
        # The one hand-drawn cue left, and it must match `option_cycle`'s exactly.
        next if File.basename(path) == "colormarker_rule_overlay.cr" &&
                line.includes?(%[" ‹/›", Theme.muted, bg) if row_sel])
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end

  it "insets every modal from the body by the same margin" do
    # Eight overlays sat `area.w - 6` / `area.h - 4` against everyone else's `- 4` / `- 2`, and
    # the group was not a group: a one-line name prompt shared the wider margin with the export
    # sheet. It showed most where it mattered least to have it — the Rewriter stub editor opens
    # FROM the Rewriter rule form, so on any terminal narrower than 78 the card jumped in by a
    # column on each side when you pressed ↵ on `response:`.
    # Scoped to `overlay_box`, which is where a modal states its CARD geometry. The same
    # `area.w - N` shape appears in three other places that are not that: a confirm dialog
    # sized to its own text, a "terminal too small" degraded card, and a row-count fit — and
    # holding those to a card's margin would be meaningless.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      src = File.read(path)
      next unless body = src[/def overlay_box.*?\n    end/m]?
      # ConfirmDialog is the one modal that sizes to its CONTENT (`content + 6`) rather than
      # filling out to a cap; its `area.w - 2` is the ceiling on that, not a margin from the
      # body. A dialog three lines tall has no card edge to align with anything.
      next if File.basename(path) == "confirm_dialog.cr"
      body.each_line do |line|
        next unless line.matches?(/\{area\.w - (?!4\b)\d+,|\{area\.h - (?!2\b)\d+,/)
        offenders << "#{File.basename(path)} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "gives every add/edit-one-rule form the same card" do
    # Six forms for one kind of task, reached from adjacent tabs. Opening two in a row must not
    # resize the card under the operator, so all six take their width and floors from the
    # `RULE_FORM_*` constants rather than a number typed into their own `overlay_box`.
    forms = %w[
      rewriter_rule_overlay colormarker_rule_overlay custom_rule_overlay
      extract_rule_overlay scope_rule_overlay oast_provider_overlay
    ]
    offenders = [] of String
    forms.each do |name|
      src = File.read(File.join(root, "#{name}.cr"))
      body = src[/def overlay_box.*?\n    end/m]? || ""
      # Not "does it use the right constants" — the whole computation belongs to
      # `Overlay.rule_form_box`, so the form should state only its ROW COUNT and whether it
      # carries a preview band. A form that spells any of the arithmetic here has started its
      # own copy, which is where the six drifted apart the first time.
      unless body.matches?(/Overlay\.rule_form_box\(area, (ROW_COUNT|row_count)(, preview: true)?\)/)
        offenders << "#{name}: overlay_box does not delegate to Overlay.rule_form_box"
      end
      offenders << "#{name}: re-derives card arithmetic" if body.includes?("area.w -") || body.includes?("area.h -")
    end
    offenders.should be_empty
  end

  it "phrases an add-me-something empty state one way" do
    # Five spellings for one sentence, split by which file drew it: the Project panes wrote
    # `(no vars — a to add)` in parentheses with a bare key, the tab views wrote
    # `no rules — press a to add` without them. Same list, same absence, same instruction.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        # Keyed on the `a` KEY specifically: a settings opener row saying `↵ to add` is a
        # different affordance, and "no flows left to add" is a toast, not an empty state.
        next unless line.includes?("a to add")
        next if line.includes?("press a to add")
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "leaves the scroll affordance to Frame.scroll_gauge" do
    # The Settings theme list painted ▲ / ▼ / ↕ into its own last interior column — an
    # affordance no other list in gori had, which said "there is more" without saying how
    # much, and cost a column the swatch wanted. The gauge answers both on the hairline.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.includes?("screen.cell")
        next unless line.includes?("'▲'") || line.includes?("'▼'") || line.includes?("'↕'")
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end
end

describe Gori::Tui::Frame do
  describe ".border_meta" do
    # 40 wide, title ` SCOPE ` from x+2 → the title ends at x + 2 + 5 + 2 = x + 9.
    card = Rect.new(0, 0, 40, 10)

    it "right-aligns the annotation two cells inside the card's right edge" do
      backend = MemoryBackend.new(40, 10)
      Frame.border_meta(Screen.new(backend), card, "SCOPE", "7 rules")
      # The run is ` 7 rules ` (padded like the card title and every badge), 9 cells ending at
      # x = 37 — two clear of the edge, where `Frame.card` puts its right border and corner.
      # So the text itself sits at 30, and cell 37 is the trailing space that keeps it off the
      # hairline resuming behind it.
      backend.row(0)[30, 7].should eq("7 rules")
      backend.row(0)[29].should eq(' ')
      backend.row(0)[37].should eq(' ')
    end

    it "answers the same left edge it drew at" do
      # `border_meta_x` is what a caller whose chrome must clear the meta reads; the draw and
      # that answer may not drift (the gRPC transcript's chip limit is derived from it).
      backend = MemoryBackend.new(40, 10)
      x = Frame.border_meta(Screen.new(backend), card, "SCOPE", "7 rules")
      x.should eq(Frame.border_meta_x(card, "7 rules"))
    end

    it "draws nothing rather than landing on the title" do
      # A card too narrow to hold both drops the meta — the title is the one that must survive,
      # since it says WHAT the card is. The hand-rolled versions clamped instead, which is how
      # a count could end up written over the title's last letters.
      backend = MemoryBackend.new(40, 10)
      narrow = Rect.new(0, 0, 14, 10)
      Frame.border_meta(Screen.new(backend), narrow, "HOST OVERRIDES", "12 entries")
      backend.contains?("12 entries").should be_false
    end

    it "ignores an empty annotation" do
      backend = MemoryBackend.new(40, 10)
      Frame.border_meta(Screen.new(backend), card, "SCOPE", "")
      backend.contains?("SCOPE").should be_false # nothing drawn at all — card() draws the title
    end
  end

  describe ".option_cycle" do
    it "draws the whole strip when there is room for it" do
      # The point of a strip: the alternatives are visible without pressing anything.
      backend = MemoryBackend.new(60, 4)
      Frame.option_cycle(Screen.new(backend), 0, 0, 60, Theme.panel,
        "kind:", ["include", "exclude"], 0, false)
      backend.row(0).should contain("include")
      backend.row(0).should contain("exclude")
    end

    it "falls back to the chosen value alone when the strip will not fit" do
      # `MAX_REQ_CHOICES` is eight numbers plus `uncapped`; on a narrow card the strip would
      # run off the row. The fallback is a WIDTH decision made here, which is what lets every
      # caller use one renderer — the Miner and Sequencer configs used to hard-code it.
      backend = MemoryBackend.new(30, 4)
      opts = ["uncapped", "100", "250", "500", "1000", "2500", "5000", "10000"]
      Frame.option_cycle(Screen.new(backend), 0, 0, 30, Theme.panel,
        "max requests:", opts, 2, false)
      backend.row(0).should contain("250")
      backend.row(0).should_not contain("uncapped")
      backend.row(0).should_not contain("10000")
    end

    it "shows the ‹/› cue only while the row has focus" do
      # Several forms drew it on every row at once, which advertises keys that do nothing
      # unless that row is the selected one.
      focused = MemoryBackend.new(60, 4)
      Frame.option_cycle(Screen.new(focused), 0, 0, 60, Theme.panel,
        "kind:", ["include", "exclude"], 0, true)
      focused.row(0).should contain("‹/›")

      resting = MemoryBackend.new(60, 4)
      Frame.option_cycle(Screen.new(resting), 0, 0, 60, Theme.panel,
        "kind:", ["include", "exclude"], 0, false)
      resting.row(0).should_not contain("‹/›")
    end

    it "reserves room for the cue, so focusing a row cannot push the strip off the edge" do
      # A width that fits the strip but NOT the strip plus the cue must take the fallback,
      # or selecting the row would silently truncate the last option.
      opts = ["alpha", "bravo", "charlie"]
      # label 5 + 1, strip = 7 + 7 + 9 = 23 → 29; the cue is 4 more.
      backend = MemoryBackend.new(40, 4)
      Frame.option_cycle(Screen.new(backend), 0, 0, 31, Theme.panel,
        "kind:", opts, 1, true)
      backend.row(0).should contain("bravo")
      backend.row(0).should_not contain("charlie")
    end

    it "returns the x past what it drew, for a caller placing something after it" do
      # The Colormarker style row puts a live sample two cells past the cycler and used to
      # re-derive that x from the label width, the option padding and the cue width.
      backend = MemoryBackend.new(60, 4)
      stop = Frame.option_cycle(Screen.new(backend), 0, 0, 60, Theme.panel,
        "style:", ["full row", "strip"], 0, false)
      # "style:" (6) + 1 + " full row " (10) + " strip " (7) = 24
      stop.should eq(24)
    end
  end
end

# The sub-tab strip is the same chrome on six tabs, and its labels are drawn VERBATIM
# (`Chrome.render_tab_strip`), so three spellings reached the screen: Project shouted
# `DESCRIPTION`/`SCOPE`, the Rewriter whispered `rules`/`extract`, and the other four used
# Title Case. Moving between tabs, the same strip in the same place read three ways.
describe "fixed sub-tab strip labels" do
  it "are Title Case everywhere" do
    root = File.join(__DIR__, "..", "..", "src", "gori")
    offenders = [] of String
    Dir.glob(File.join(root, "tui", "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/^\s+(SUBTABS|SUB_LABELS|PANE_LABELS|PAGE_LABELS|SUBS)\s*=\s*\[/)
        line.scan(/"([^"]+)"/) do |m|
          label = m[1]
          # First letter upper, and not SHOUTED — `Host overrides` is right, `HOST OVERRIDES`
          # and `rules` are not. A one-word acronym label would be a fair exception; there is
          # none today, so the rule stays simple until there is.
          ok = label[0].uppercase? && label != label.upcase
          offenders << "#{File.basename(path)}:#{i + 1} — #{label}" unless ok
        end
      end
    end
    offenders.should be_empty
  end
end

# The last of the hand-rolled chrome: a right-anchored run of bare text chips on a filter bar,
# a count baked into a card TITLE, and the `▎` marker used as a trailing glyph.
describe "the last hand-rolled chrome" do
  root = File.join(__DIR__, "..", "..", "src", "gori", "tui")

  it "leaves the filter bar's right cluster to Frame.right_text_chain" do
    # Four views wrote this out — History (`count · ⇧S scope · f:follow · N marked`), Sitemap
    # (`… g:fold …`), and the bare pair in Issues and Probe. The tell is the hand-rolled
    # right-to-left cursor: `rx = rect.right - 1` followed by `rx -= …`. They had already
    # drifted on the gap, stepping TWO columns after the count and ONE between the chips in
    # the same method.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      src = File.read(path)
      # Filter BARS only. `probe_view` runs the same right-to-left cursor INSIDE a list row
      # to right-align `status · host · ×N` — a per-row column layout, not a bar cluster, and
      # no shared helper covers it.
      next if File.basename(path) == "probe_view.cr"
      src.lines.each_with_index do |line, i|
        next unless line.matches?(/^\s+rx -= \w+\.size \+ \d/)
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "keeps counts out of card titles" do
    # A count in the title makes the title's WIDTH a moving target, and two views derive a
    # badge's `min_x` from exactly that width — so the chrome shifted as the number gained a
    # digit. `Frame.border_meta` is the slot, right-aligned and independent of the title.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        # A COUNT, specifically — `"FINDINGS (#{n})"`, `"ATTACKS · #{n}"`. A title that
        # interpolates WHAT the card is showing is not the same thing and stays: `RESULT #3`,
        # `SETTINGS · NETWORK`, `PICK FLOW REPEATER`, `IMPORT HAR · source path`. The tell is
        # a bare size/count expression, not a name.
        inline = line.includes?("Frame.card(") &&
                 line.matches?(/Frame\.card\([^,]+,\s*[^,]+,\s*"[^"]*#\{[^}]*\.size[^}]*\}/)
        # …and the same title BOUND FIRST and passed on the next line, which is the form this
        # check originally missed: Discover built `title = "RUNS (#{@runs.size})"` a line above
        # its `Frame.card`, so the inline pattern never saw it and the audit found it by hand.
        bound = line.matches?(/^\s*\w*title\w* = "[^"]*#\{[^}]*\.size[^}]*\}/)
        next unless inline || bound
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "uses ▎ as a leading marker, never a trailing one" do
    # Every list in gori writes `▎` in the row's marker column. History's preview titles were
    # the one place it followed its label instead.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/"[^"]*\S\s*▎"/)
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end
end
