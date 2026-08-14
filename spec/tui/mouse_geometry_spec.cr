require "../spec_helper"

include Gori::Tui

# What gori DRAWS and what it HIT-TESTS, held to each other.
#
# This axis has produced real defects three times over: the Fuzzer's SNI badge overpainted the
# mode chip so clicking the visible `SNI` letters toggled insert; `Frame.mode_badge` was passed
# `focused && insert?` in three views, so an unfocused-but-inserting pane drew nothing while a
# five-cell click target stayed live; and the Issues RELATED list drew its selection bar only
# when active. Every rule below is a shape that has actually shipped broken.
describe Gori::Tui::Frame do
  # `toggle_badge` returns its `right_edge` UNCHANGED when a badge does not fit, so the chain
  # keeps going and a SHORTER badge further left still draws at that same edge. The hit-test
  # used to `break` out of the loop while its own doc comment claimed "(same as draw)".
  describe ".right_badge_hit" do
    it "skips a badge that does not fit and keeps testing the shorter ones, like the draw" do
      # ` ^R:SEND ` is 9 cells and ` ^L:CL ` is 7. At a width where SEND cannot be drawn but CL
      # can, CL is on screen — and used to be un-clickable.
      badges = [{:send, "^R", "SEND"}, {:cl, "^L", "CL"}] of {Symbol, String, String}
      right_edge = 20
      min_x = 13 # SEND would start at 11 (< min_x); CL starts at 13 (fits)
      Frame.right_badge_hit(14, 0, 0, right_edge, min_x, badges).should eq(:cl)
    end

    it "returns the same edge the draw does, so the next badge chains correctly" do
      badges = [{:send, "^R", "SEND"}, {:cl, "^L", "CL"}] of {Symbol, String, String}
      # SEND skipped (edge unchanged at 20), CL drawn at 13 → the next badge's edge is 13.
      Frame.right_badge_edge(20, 13, badges).should eq(13)
    end
  end

  # `Frame.chip` does not clip itself, so a caller that stops drawing at a limit must tell the
  # hit-test — the Repeater's RESPONSE cluster is half-width and used to run through its own
  # '╮' on the draw side only.
  describe ".left_chip_hit" do
    chips = [{:diff, " d:diff "}, {:hex, " ^X:hex "}] of {Symbol, String}

    it "stops at the first chip that would cross the limit" do
      # d:diff spans 10..17, ^X:hex 19..26. A limit of 20 means ^X:hex was never drawn.
      Frame.left_chip_hit(20, 0, 0, 10, chips, limit: 20).should be_nil
      Frame.left_chip_hit(12, 0, 0, 10, chips, limit: 20).should eq(:diff)
    end

    it "walks the whole run when no limit is given" do
      Frame.left_chip_hit(20, 0, 0, 10, chips).should eq(:hex)
    end
  end

  # The gauge is the one piece of chrome an operator reflexively grabs, and for 46 draw sites
  # there was no hit-test of any kind.
  describe ".scroll_gauge_top" do
    content = Rect.new(0, 0, 10, 10) # gauge column is x == 10 (content.right)

    it "refuses when the draw would refuse — a body that fits has no gauge to click" do
      Frame.scroll_gauge_top(content, 10, 10, 0).should be_nil
      Frame.scroll_gauge_top(Rect.new(0, 0, 10, 1), 100, 10, 0).should be_nil
    end

    it "refuses anywhere but the gauge column" do
      Frame.scroll_gauge_top(content, 100, 9, 5).should be_nil
      Frame.scroll_gauge_top(content, 100, 11, 5).should be_nil
    end

    it "puts the clicked cell in the MIDDLE of the thumb, and clamps at both ends" do
      Frame.scroll_gauge_top(content, 100, 10, 0).should eq(0)
      Frame.scroll_gauge_top(content, 100, 10, 9).should eq(90) # total - track
      mid = Frame.scroll_gauge_top(content, 100, 10, 5).not_nil!
      (0 < mid < 90).should be_true
    end
  end

  describe ".scroll_gauge_row" do
    content = Rect.new(0, 0, 10, 10)

    it "maps the track's ends onto the FIRST and LAST rows" do
      Frame.scroll_gauge_row(content, 100, 10, 0).should eq(0)
      Frame.scroll_gauge_row(content, 100, 10, 9).should eq(99)
    end

    it "refuses off the gauge column and when nothing overflows" do
      Frame.scroll_gauge_row(content, 100, 9, 5).should be_nil
      Frame.scroll_gauge_row(content, 10, 10, 5).should be_nil
    end
  end
end

# A mode badge states its pane's OWN mode and is drawn unconditionally. `Frame.mode_badge`'s
# contract says so and spells out the failure; three views broke it once and were fixed, then
# the Decoder and JWT INPUT cards were found doing the same thing by gating the whole DRAW on
# focus while their controllers hit-tested the bare mode. A click on blank border flipped the
# editor into insert.
describe "mode badges" do
  it "are never drawn behind a focus gate" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      next if File.basename(path) == "frame.cr" # the helper itself
      lines = File.read(path).lines
      lines.each_with_index do |line, i|
        # CODE only. The first pass matched `focused&&mode` inside the Repeater's own comment
        # saying NOT to do that — the third time a source-grep spec here has been fooled by the
        # prose explaining the very rule it enforces.
        code = line.sub(/\s#.*$/, "")
        next unless code.includes?("Frame.mode_badge(")
        # The two shapes that gate it: a `focused &&`-style argument on the call itself, and an
        # `if <focus-ish>` on the line above wrapping the call.
        offenders << "#{File.basename(path)}:#{i + 1} — #{code.strip}" if code.matches?(/Frame\.mode_badge\(.*\b(focused|active|reading)\b\s*&&/)
        prev = lines[i - 1]?.try(&.sub(/\s#.*$/, ""))
        next unless prev
        offenders << "#{File.basename(path)}:#{i} — gated by #{prev.strip}" if prev.matches?(/^\s*if\s+(focused|active|reading)\b/)
      end
    end
    offenders.should be_empty
  end
end

# A hit-test must not accept a row the render RESERVED for something else. Three lists had this
# and each was found separately: the Colormarker note row, the Sitemap tag prompt, and the
# Probe Rules description footer. In every case a sibling on the same render pass (the gauge)
# already had the geometry right.
describe "reserved rows" do
  it "are subtracted by the hit-test wherever the draw subtracts them" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    {"colormarker_view.cr" => "list_h",
     "sitemap_view.cr"     => "@tagging",
     "probe_rules_view.cr" => "list_h"}.each do |file, token|
      src = File.read(File.join(root, file))
      body = src[/def row_at\(.*?\n    end/m]?
      body.should_not be_nil
      body.not_nil!.should contain(token)
    end
  end
end

# A hit-test derived from a rect the renderer did not draw. `results_rect` backs both the
# Fuzzer's RESULTS badge hits and its row hits, and had no `@focus == :detail` gate — while
# `render_bottom` hands the whole band to the DETAIL card in exactly that state. A click on the
# detail card's top border toggled DIST/MATCH/sort *and* threw the operator out of the detail.
describe "FuzzerView#results_rect" do
  it "is nil while the RESULT DETAIL card owns the band" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "fuzzer_view.cr"))
    body = src[/private def results_rect\(rect : Rect\) : Rect\?.*?\n    end/m].not_nil!
    # CODE lines only. The first control run PASSED with the gate removed, because the comment
    # explaining the gate names the very expression being looked for — the same way the mode-badge
    # check above was fooled. A source-grep spec has to read what RUNS.
    code = body.lines.map(&.sub(/\s*#.*$/, "")).join("\n")
    code.should contain("return nil if @focus == :detail")
  end
end

# The shell used to gate `handle_double_click` on `supports_drag?`, which conflates "can extend
# a text selection" with "can receive a double-click". Colormarker implements the gesture (it
# opens the rule editor) and, being a list with no text, answers `supports_drag?` false — so
# the shell never asked and a double-click read as two selects. Silent, and invisible from the
# controller alone.
describe "Runner double-click dispatch" do
  # Mouse routing lives in `tui/runner/mouse.cr`, which reopens Runner — so the method body
  # sits one level shallower than it did inside `runner.cr`'s `module Gori::Tui`. Anchor the
  # terminator on the two-space `end` that file actually has; a stale four-space anchor
  # matches nothing and `not_nil!` turns the whole guard into an error instead of a failure.
  mouse_src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "mouse.cr"))

  it "does not require drag support" do
    body = mouse_src[/private def dispatch_double_click.*?\n  end/m].not_nil!
    body.should_not contain("drag_press_target?")
    body.should contain("double_click_target?")
  end

  it "keeps the same context rejections as the drag tier" do
    # Both must refuse the space menu, the pickers and the bottom prompts. Shared, so they
    # cannot drift: the whole point of splitting them was to change ONE of the two questions.
    mouse_src[/private def drag_press_target?.*?\n  end/m].not_nil!.should contain("pointer_capture_elsewhere?")
    mouse_src[/private def double_click_target?.*?\n  end/m].not_nil!.should contain("pointer_capture_elsewhere?")
  end
end

# A key printed on a badge or in a hint must be a key that DOES something. The Repeater's
# ` ^K:MARK ` badge and two hint strings advertised ctrl-K, which at the time was bound
# nowhere in the app — legacy from a marking flow `^T` had replaced. Nothing failed; the key
# simply did nothing, and only a hand audit would ever notice.
#
# So: every `^<letter>` this pane PRINTS must be reachable in it. The two panes answer that
# question by different routes — the Repeater defers every ctrl chord to the keymap, the
# Fuzzer claims a few directly in `chord_action` — so the check unions both.
describe "advertised chords" do
  registry = Gori::Verbs.registry

  # Ctrl letters a scope can actually receive: registry bindings, plus the letters the
  # controller intercepts itself before the keymap sees them.
  reachable = ->(scope : Gori::Verb::Scope, controller : String) do
    keys = Set(String).new
    registry.each { |v| v.chords.each { |c| keys << c.key if c.ctrl && v.scope == scope } }
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers", controller))
    if body = src[/private def chord_action.*?\n    end/m]?
      body.scan(/key\.lower_([a-z])\?/) { |m| keys << m[1] }
    end
    # Plus the shell's own — ^G goto, ^F find, ^B reveal and friends are dispatched in
    # `Runner#handle_key` before any tab sees them, so a hint naming one is telling the truth.
    # Derived, not listed: a hard-coded set would rot the moment the shell grew a chord.
    shell = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    shell.scan(/ev\.ctrl\? && ev\.key\.lower_([a-z])\?/) { |m| keys << m[1] }
    keys.concat(%w(p w z n)) # palette / close sub-tab / undo / new, claimed per-controller
    keys
  end

  # Ctrl letters PRINTED by a file — badge labels and hint strings alike.
  advertised = ->(file : String) do
    out = Set(String).new
    File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", file)).each_line do |line|
      next if line.matches?(/^\s*#/) # prose, not a label
      line.scan(/\^([A-Z])/) { |m| out << m[1].downcase }
    end
    out
  end

  {
    {"repeater_view.cr", "repeater_controller.cr", Gori::Verb::Scope::Repeater},
    {"fuzzer_view.cr", "fuzzer_controller.cr", Gori::Verb::Scope::Fuzzer},
  }.each do |(view, controller, scope)|
    it "prints only chords #{view.split('_').first} can actually receive" do
      have = reachable.call(scope, controller)
      # `^C`/`^D` are the terminal's, and the hex editors print `^X`-style prose about BYTES.
      shown = advertised.call(view) - Set{"c", "d"}
      (shown - have).should be_empty
    end
  end
end

describe "marker actions across the two template editors" do
  registry = Gori::Verbs.registry

  {"mark-word" => "k", "insert-marker" => "t"}.each do |action, chord|
    it "binds ^#{chord.upcase} to #{action} in BOTH panes" do
      # `repeater.insert-marker` is the exception the pair does not break: `^T` there is
      # `repeater.toggle-decoded`, one context-sensitive key that switches envelope/decoded on
      # a SAML/GraphQL/WS tab and inserts a § everywhere else. Same keystroke, same gesture.
      fuzz = registry["fuzz.#{action}"]
      fuzz.chords.any? { |c| c.key == chord && c.ctrl }.should be_true
      next if action == "insert-marker"
      rep = registry["repeater.#{action}"]
      rep.chords.any? { |c| c.key == chord && c.ctrl }.should be_true
    end
  end

  # The space-menu letter is the thing a hand learns, so the two panes must not disagree on
  # it. Three of the five did — auto-mark was 'a' in the Repeater and 'm' in the Fuzzer, and
  # attach-chain / clear-marks were 'c'/'e' against 'e'/'c', i.e. SWAPPED: pressing the letter
  # you know from one pane ran a DIFFERENT action in the other, which is worse than a no-op.
  # Aligned on the Repeater's letters, where the muscle memory is.
  {
    {"repeater.auto-mark", "fuzz.automark"},
    {"repeater.mark-word", "fuzz.mark-word"},
    {"repeater.insert-marker", "fuzz.insert-marker"},
    {"repeater.clear-marks", "fuzz.clear-marks"},
    {"repeater.attach-chain", "fuzz.attach-chain"},
    {"repeater.pretty-request", "fuzz.pretty-template"},
    {"repeater.toggle-http2", "fuzz.toggle-http2"},
  }.each do |(rep, fuzz)|
    it "gives #{rep.split('.').last} the same menu letter in both panes" do
      registry[rep].menu_key.should eq(registry[fuzz].menu_key)
    end
  end

  it "leaves the SNI pair apart, because the Fuzzer cannot have the Repeater's letter" do
    # NOT drift, and the one pair deliberately left unmatched: the space menu shows COMMON
    # plus the focused section, and `fuzz.stop` already owns 's' in the Fuzzer's COMMON —
    # the Repeater has no stop verb, so 's' was free there. Aligning would raise at boot.
    registry["repeater.toggle-sni"].menu_key.should eq('s')
    registry["fuzz.toggle-sni"].menu_key.should_not eq('s')
    registry.find { |v| v.scope == Gori::Verb::Scope::Fuzzer && v.section == :common && v.menu_key == 's' }
      .should_not be_nil
  end

  it "gives every marker action a space-menu entry in both panes" do
    # `menu_key` nil ⇒ the verb is EXCLUDED from the space menu. That is what the Fuzzer's
    # two `chord_action` arms amounted to: no verb, so nothing to list.
    %w(mark-word insert-marker automark clear-marks).each do |a|
      fuzz_id = a == "automark" ? "fuzz.automark" : "fuzz.#{a}"
      registry[fuzz_id].menu_key.should_not be_nil
    end
    %w(mark-word insert-marker auto-mark clear-marks).each do |a|
      registry["repeater.#{a}"].menu_key.should_not be_nil
    end
  end
end

# Review findings, each pinned so the fix is a rule rather than a patch.
describe "code-review fixes" do
  it "keeps the ^T:MARK badge off a decode split, where ^T means something else" do
    # `repeater.toggle-decoded` is context-sensitive: on a SAML/GraphQL tab `^T` switches
    # ENVELOPE ⇄ DECODED instead of inserting a §. `req_split?` routes those through the SAME
    # `render_request`, so the badge was drawn — and clickable — reading `^T:MARK` while the
    # key it names did something unrelated. Draw and hit are gated together.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "repeater_view.cr"))
    draw = src[/# NOT on a decode split either\..*?end/m].not_nil!
    draw.should contain("!decode_mode?")
    hit = src[/` \^T:MARK ` chains LEFT.*?return :mark/m].not_nil!
    hit.should contain("!decode_mode?")
  end

  it "makes a rule-list click SELECT, never toggle, in all three lists" do
    # `probe-rules.toggle` gave up its `↵` because "a reflex carried from any other rule list
    # silently disabled a scanning rule here" — and the pointer path kept exactly that hazard,
    # toggling on a second click while neither sibling does.
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers")
    {"probe_controller.cr", "rewriter_controller.cr", "colormarker_controller.cr"}.each do |f|
      src = File.read(File.join(root, f))
      body = src[/def handle_click.*?\n    end/m].not_nil!
      body.should_not match(/selected_index == idx \? \w*toggle/)
    end
  end

  it "snaps the Probe Rules gauge to a row that can actually take the selection" do
    # `@rows` interleaves three `:header` rows and an `:empty` placeholder; `select_index`
    # refuses them, so a raw proportional hit was a silent no-op on ~4 of ~40 track positions.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "probe_rules_view.cr"))
    src[/def gauge_row_at.*?\n    end/m].not_nil!.should contain("nearest_selectable")
  end
end

# The ⌕ affordance carves columns off the LEFT of the sub-tab chip row. Render narrows the
# rect it hands `Chrome.render_tab_strip`; both mouse paths have to narrow the rect they hand
# `Chrome.strip_segments` by the same amount, or chip 1 sits under the pill — a left-click on
# ⌕ would jump to session 1 and a right-click would open its rename prompt.
#
# Two independent paths (left-click chip select, right-click rename) regress separately, so
# this counts CALLS rather than asserting one of them.
describe "sub-tab strip hit-tests" do
  it "never hand Chrome.strip_segments an un-narrowed chip row" do
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner", "mouse.cr"))
    # CODE only — the comment above `subtab_strip_split` names the very shape being banned,
    # and a grep that reads prose is the way three specs in this file were fooled before.
    code = src.lines.map(&.sub(/\s*#.*$/, ""))
    calls = code.select(&.includes?("Chrome.strip_segments("))
    calls.size.should eq(2) # left-click select + right-click rename
    calls.each do |line|
      line.should_not contain("BodyChrome.tab_row"),
        "a strip hit-test measures the full row, so the ⌕ pill's columns belong to chip 1: #{line.strip}"
    end
    # And the split itself is derived from the same helper the renderer uses.
    split = code.join("\n")[/private def subtab_strip_split.*?\n  end/m].not_nil!
    split.should contain("BodyChrome.find_icon_split")
  end
end
