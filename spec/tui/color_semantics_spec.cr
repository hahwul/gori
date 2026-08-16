require "../spec_helper"

include Gori::Tui

# `theme.cr` states the intent in its own header: "Only HTTP status keeps functional colour",
# and every one of the 28 palettes annotates its three semantic slots the same way —
# green 2xx, yellow 4xx, red 5xx/error. `Theme.status_color` is that ladder as code.
#
# The Repeater then hand-rolled the mapping twice, twenty lines apart in one file, and got two
# different answers for the same fact: `st >= 400 ? red : text` on the gRPC transcript and
# `st >= 400 ? yellow : green` on the head line. So a 404 was RED in one pane and yellow in
# the next — red being the colour every other surface reserves for 5xx.
describe "HTTP status colour" do
  it "comes from Theme.status_color, never a local >= 400 test" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "theme.cr" # the ladder itself
      File.read(path).lines.each_with_index do |line, i|
        # A status threshold deciding a colour on the same line — the shape both Repeater
        # sites had. Comparisons only: `status:>=500` inside the Intercept filter bar's
        # EXAMPLE string is prose about the query language, not a colour decision, and it
        # sits on a line that also names a Theme colour for the bar itself.
        next unless line.matches?(/[a-z_]\s*>=?\s*(400|500|200|300)\b/)
        next unless line.matches?(/\?.*Theme\.|Theme\..*:/)
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "keeps the ladder's four rungs distinct in intent" do
    # Not a rendering assertion — the palettes are free to collapse rungs (19 of 28 make
    # `accent` equal `text` or `text_bright`, which is why every one of these cells also
    # carries the NUMBER). This pins the mapping itself, which is what the hand-rolled
    # versions got wrong: one collapsed 3xx into green, the other 4xx into red.
    Theme.apply("goridark")
    Theme.status_color(204).should eq(Theme.green)
    Theme.status_color(301).should eq(Theme.accent)
    Theme.status_color(404).should eq(Theme.yellow)
    Theme.status_color(503).should eq(Theme.red)
    Theme.status_color(nil).should eq(Theme.muted)
  end
end

# A state an operator acts on must be readable WITHOUT colour. gori ships HIGH_CONTRAST (where
# accent, text and text_bright are all `#ffffff`) and palettes like MATRIX where the semantic
# hues sit close together, so a hue-only signal is not merely an accessibility nicety here —
# it is invisible on themes the app itself offers.
describe "state signals carry a word or a glyph" do
  it "says whether capture is running, in words" do
    # Both states used to render the byte-identical `● 127.0.0.1:8070`, differing only by
    # green-vs-muted. The project picker already wrote `off`; the top bar now does too.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "chrome.cr"))
    body = src[/def self\.listen_chip.*?\n    end/m]?.should_not be_nil
    src[/def self\.listen_chip.*?\n    end/m].not_nil!.should contain("off")
  end

  it "marks a hotkey rebind's outcome with a glyph, not just a hue" do
    # `✓` / `✗` — the notification centre's vocabulary. Both outcomes used to print `•` and
    # differ only by green-vs-yellow, the closest pair in several shipped palettes.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "hotkeys_overlay.cr"))
    footer = src[/def render_footer.*?\n    end/m].not_nil!
    footer.should contain("'✓'")
    footer.should contain("'✗'")
  end

  it "spells :error the same colour wherever the symbol is used" do
    # `:error` was yellow in the Hotkeys footer and red in the notification centre — one
    # symbol name, one meaning, two hues.
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        # Colour branches only. `:error` is also a key in the mascot's FACE table and the
        # companion's mood map, where it selects a glyph and an animation — different channels,
        # and neither names a colour.
        next unless line.matches?(/when :error\s+then.*Theme\./)
        next if line.includes?("Theme.red")
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end
end

# Two axes, one ladder. Severity (CRIT/HIGH/MED/LOW/INFO) and triage status
# (conf/fp/done/open) are drawn five columns apart on every row of the Issues and Probe
# lists, and both used to draw from red/accent/muted — so `CRIT conf` was two reds meaning
# two different things and `LOW open` two accents. On a list whose entire job is "scan for
# red", three of five reds could be triage state.
describe "severity and triage status" do
  it "do not share a colour ladder" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    # The hues severity owns. A status branch reaching for any of them is the collision.
    severity_hues = ["Theme.red", "Theme.orange", "Theme.yellow", "Theme.accent"]
    offenders = [] of String
    # Both ladders live in ONE module now (IssuePresentation), included by the Issues and
    # Probe tabs — so this reads the single home rather than two copies of it.
    shared = File.read(File.join(root, "issue_presentation.cr"))
    body = shared[/def status_color\(s : Store::Status\).*?\n    end/m]?
    body.should_not be_nil
    severity_hues.each do |hue|
      offenders << "issue_presentation.cr — status_color uses #{hue}" if body.not_nil!.includes?(hue)
    end
    # A tab that re-declares its own `status_color` shadows the shared one, which is how the
    # two ladders collided in the first place. Having one home only helps if nobody reopens
    # a second, so the guard checks for that too.
    {"issues_view.cr", "probe_view.cr"}.each do |name|
      src = File.read(File.join(root, name))
      offenders << "#{name} — re-declares status_color instead of using IssuePresentation" if src.includes?("def status_color")
    end
    # The picker teaches what a status colour MEANS, so it must not contradict the lists.
    picker = File.read(File.join(root, "choice_picker.cr"))
    status_block = picker[/def self\.for_status.*?\n    end/m].not_nil!
    severity_hues.each do |hue|
      offenders << "choice_picker.cr — for_status uses #{hue}" if status_block.includes?(hue)
    end
    offenders.should be_empty
  end
end

# `theme.cr` sanctions exactly two jobs for `focus_gold`: the brand mark, and the focus
# outline. Everything else that reached for it made one of those two unreadable — the
# Repeater's transport chip rides the same card border that goes gold on focus, and the
# chain overlay borrowed it (through `marker_accent`) to mean provenance.
describe "focus_gold" do
  it "does not fill a chip that rides a focusable card's own border" do
    # The Repeater's `^V:h2` transport chip fills when the operator has overridden transport
    # auto-detection, and it sits ON the TARGET card's top border — the same border that goes
    # `focus_gold` when the card has focus. Filling it gold put two golds on one edge and
    # "gold means focus is here" stopped being readable. It is a bold ACCENT pill now: still
    # the loudest thing on the band, no longer competing with the focus outline.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "repeater_view", "render.cr"))
    chip = src[/if transport_badge_lit\?.*?end/m].not_nil!
    chip.should_not contain("focus_gold")
  end

  it "does not stand in for provenance on the chain overlay" do
    # `marker_accent` IS `focus_gold` under another name, documented for one job: the closing
    # § of a marker that hides a ¦chain. The step list borrowed it to mean "this resolved to a
    # SAVED library chain" — provenance, which is the question `env_known` already answers for
    # a `$TOKEN` that resolved.
    # Match the STEP-STATE line, not a guessed spelling of the expression: the first attempt
    # asserted `category.saved? ? Theme.marker_accent` and the real code reads
    # `try(&.category.saved?) ?`, so the control run reintroducing the bug passed.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "chain_overlay.cr"))
    step_line = src.lines.find(&.includes?("category.saved?")).not_nil!
    step_line.should_not contain("marker_accent")
  end

  # NOT asserted here, and deliberately: `RepeaterView#pane_border` returns `accent` instead of
  # `focus_gold` while a focused pane is in INSERT mode, so the most active pane in the app is
  # the one that is not gold. That reads like the same defect — two axes (focus, mode) sharing
  # one channel, with the mode already stated by the `↵:READ`/`INS` badge on the same border —
  # but it is long-standing behaviour the Fuzzer copies, and changing it moves the most-used
  # pane in gori. It wants its own decision, not a spec smuggled in beside two settled ones.
end

# A pane's border answers ONE question: does this pane have focus. The mode it is in — READ or
# INS — is answered by the badge riding that same border, and putting both on the outline made
# the most active pane in the app the one that was not gold.
#
# Three views carried a private `pane_border` with a third dress for "focused and typing"
# (`insert ? Theme.accent : Theme.focus_gold`) while four insert-capable panes — Decoder, JWT,
# Issues, Intercept — never had one. It cost legibility too: `accent` equals `text_bright` on
# nine of the 28 palettes, so the pane being typed into outlined itself in the brightest colour
# the theme has.
describe "pane borders" do
  it "are drawn by Frame.pane_border alone" do
    # No local copy, not even a pass-through: a private `pane_border` that merely forwards is
    # exactly the seam the third dress grew in, and four files had one.
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "frame.cr"
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/def [a-z_]*pane_border/)
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "take focus as their only input" do
    Theme.apply("goridark")
    Frame.pane_border(true).should eq(Theme.focus_gold)
    Frame.pane_border(false).should eq(Theme.border)
  end
end
