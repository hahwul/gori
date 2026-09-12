require "../spec_helper"
require "../support/tui_contract"
require "../support/fake_context"

include Gori::Tui

# The digit family — bare `0`-`9` for the tab bar's nine slots and its Go-to picker, `⇧0`-`⇧9`
# for the active tab's sub-tabs — has to mean the SAME thing from every focus state, because
# the bar paints the numbers where the operator can see them. It did not: a dozen handlers in
# `Runner#handle_key` return before the keymap is consulted (the sub-tab strip swallows
# everything it does not recognise, the drill-in details and every controller's
# `handle_body_key` claim their own bare keys), so the digits worked on the tab bar and in
# about half the panes underneath it.
#
# The shell now claims the family ABOVE all of them, gated on one question: is this keystroke
# TEXT? Three things have to hold, and each is pinned below:
#
#   1. the keymap answers the digits at all, in every scope (no scope shadows one);
#   2. the gate — `TabController#body_takes_text?` — says "text" in exactly the panes that
#      take characters and "navigation" everywhere else;
#   3. the claim SITS above the handlers that used to swallow the digits and below the ones
#      that own text, which is an ordering in one method and therefore a source scan.
#
# `Runner.new` owns a terminal and appears nowhere under spec/, so (3) is read from source the
# way spec/tui/subtab_find_key_spec.cr reads the strip's key table. Comments are stripped
# first: a comment explaining a rule contains the tokens the rule looks for.
private def runner_code : Array(String)
  File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "runner.cr"))
    .lines.reject(&.lstrip.starts_with?('#'))
end

describe "the digit family — keymap" do
  keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry)

  it "binds 1-9 to the nine slots and 0 to the Go-to picker" do
    (1..9).each do |n|
      keymap.lookup(Gori::Verb::Chord.new(n.to_s), Gori::Verb::Scope::Global).should eq("nav.pos#{n}")
    end
    keymap.lookup(Gori::Verb::Chord.new("0"), Gori::Verb::Scope::Global).should eq("nav.goto")
  end

  it "binds ⇧1-⇧9 to the sub-tabs and ⇧0 to the sub-tab find" do
    (1..9).each do |n|
      keymap.lookup(Gori::Verb::Chord.new(n.to_s, shift: true), Gori::Verb::Scope::Global)
        .should eq("subtab.pos#{n}")
    end
    keymap.lookup(Gori::Verb::Chord.new("0", shift: true), Gori::Verb::Scope::Global)
      .should eq("subtab.find")
  end

  it "is shadowed by NO scope — a digit means the same thing on every tab" do
    # The whole point of painting numbers on the bar. A scoped digit binding would be legal
    # and silent: the shell resolves scope-then-Global, so one `Chord.new("3")` in
    # Verb::Scope::Repeater would make `3` mean two different things one tab apart.
    Gori::Verb::Scope.values.each do |scope|
      ("0".."9").each do |d|
        [false, true].each do |shift|
          id = keymap.lookup(Gori::Verb::Chord.new(d, shift: shift), scope)
          next if id.nil?
          id.should match(/\A(nav|subtab)\./), "#{scope} binds #{shift ? "⇧" : ""}#{d} to #{id}"
        end
      end
    end
  end

  it "opens the two pickers through the palette too, and keeps the jumps out of it" do
    # `0` and `⇧0` open a thing worth finding by name; the eighteen positional jumps are keys,
    # not commands, and would bury the palette's first page under "Go to tab 4".
    Gori::Verbs.registry["nav.goto"].hidden?.should be_false
    Gori::Verbs.registry["subtab.find"].hidden?.should be_false
    (1..9).each do |n|
      Gori::Verbs.registry["nav.pos#{n}"].hidden?.should be_true
      Gori::Verbs.registry["subtab.pos#{n}"].hidden?.should be_true
    end
  end

  it "gates the sub-tab family on the active tab HAVING a strip" do
    # Without the gate, ⇧3 on the History tab would fire into a controller with no sub-tabs.
    # With it, the chord falls through to Global and is simply unbound there.
    ctx = FakeExecContext.new
    ctx.subtab_search_tab_count = 0
    Gori::Verbs.registry["subtab.pos3"].available?(ctx).should be_false
    Gori::Verbs.registry["subtab.find"].available?(ctx).should be_false
    ctx.subtab_search_tab_count = 4
    Gori::Verbs.registry["subtab.pos3"].available?(ctx).should be_true
    Gori::Verbs.registry["subtab.find"].available?(ctx).should be_true
  end

  it "dispatches ⇧N to the ONE generic sub-tab jump, not nine per-controller copies" do
    ctx = FakeExecContext.new
    ctx.subtab_search_tab_count = 9
    Gori::Verbs.registry["subtab.pos7"].call(ctx)
    ctx.args_for(:subtab_jump).should eq(["7"])
  end
end

# The focus-state matrix. Each row is a place the hand can be standing; the question is
# whether a bare `3` is a TAB JUMP or the character "3". The gate the shell asks is
# `body_takes_text?` on the active tab's controller, so the matrix is driven through real
# controllers over a real Session.
describe "the digit family — focus-state matrix" do
  it "is navigation in every pane a tab opens in" do
    # At rest — a list, a table, a read-only pane, an empty workbench — no controller takes
    # text, so the digits are the bar's. This is the row that covers the tabs with no
    # interesting modes of their own (OAST, Comparer, Sequencer, Colormarker, Evidence, Help…)
    # and every tab added after this spec was written.
    TuiContract.with_session("digit-rest") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        controller.body_takes_text?.should be_false,
          "#{controller.class} takes text at rest — a digit would not reach the tab bar"
      end
    end
  end

  it "is navigation on the tab bar, the 0:tabs stop and the sub-tab strip" do
    # These three are `@focus != :body`, and the gate asks the controller only for `:body` —
    # so the answer is structural rather than per-controller. Pinned on the predicate itself:
    # the `@focus == :body` clause IS the rule, and dropping it would make a Repeater session
    # in INS swallow a digit pressed while standing on the strip above it.
    body = runner_code.join('\n')[/private def text_input_active\?.*?\n    end/m]
    body.should_not be_nil
    body.not_nil!.should contain("@focus == :body")
    # …with one exception, and only one: the `/` sub-tab filter is opened FROM the strip, so
    # it takes keys while `@focus` is `:subtabs`.
    body.not_nil!.should contain("subtab_filter_editing?")
  end

  it "is navigation in the Repeater request in READ, and text in INS" do
    TuiContract.with_session("digit-repeater") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      v = ctl.current_view.not_nil!
      v.focus_pane(:request)
      ctl.body_takes_text?.should be_false # READ: `3` is the tab bar's
      v.enter_request_insert!
      ctl.body_takes_text?.should be_true # INS: `3` is a character
    end
  end

  it "is navigation in the Repeater RESPONSE pane, which is read-only whatever the request is doing" do
    TuiContract.with_session("digit-response") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      v = ctl.current_view.not_nil!
      v.enter_request_insert! # the pane BESIDE it is mid-edit…
      v.focus_pane(:response) # …but this one is not
      ctl.body_takes_text?.should be_false
    end
  end

  it "is text in the Repeater TARGET field, where a port is digits" do
    # The row `editor_captures_tab?` alone would have got wrong: Tab is a pane move on a
    # single-line field, so the default gate says "not an editor" — and `:8080` would have
    # jumped tabs three times.
    TuiContract.with_session("digit-target") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      ctl = RepeaterController.new(host)
      ctl.repeater_new
      v = ctl.current_view.not_nil!
      v.focus_pane(:target)
      v.enter_target_insert!
      ctl.editor_captures_tab?.should be_false # the default gate would have said "navigation"
      ctl.body_takes_text?.should be_true
    end
  end

  it "is navigation in the Intercept queue — and the gate asks about the HEX editor too" do
    TuiContract.with_session("digit-intercept") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :intercept
      ctl = InterceptController.new(host)
      ctl.body_takes_text?.should be_false # the queue is a list; nothing is held
      ctl.view.toggle_edit                 # nothing to edit → still the queue
      ctl.body_takes_text?.should be_false
    end
    # The hex editor cannot be stood up without a held binary message, so its half of the
    # gate is pinned in source: its whole alphabet is `0`-`9a`-`f`, and a digit claimed for
    # the tab bar there would be a byte the operator could not type.
    src = File.read(File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers", "intercept_controller.cr"))
    body = src[/def body_takes_text\?.*?
    end/m].not_nil!
    body.should contain("hex_editing?")
    body.should contain("text_editing?")
    body.should contain("querying?")
  end

  it "is navigation in the Decoder INPUT in READ, and text in INS" do
    TuiContract.with_session("digit-decoder") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :decoder
      ctl = DecoderController.new(host)
      ctl.body_takes_text?.should be_false
      # `i` is `editor.insert` (Verb::Scope::Editor), resolved by the shell and dispatched
      # into this seam — the pane no longer claims the letter itself.
      ctl.editor_enter_insert.should be_true
      ctl.body_takes_text?.should be_true
    end
  end

  it "is text in the Decoder CHAIN field, where every converter name carries a digit" do
    # The regression #1050 left behind, and the one that blocked a whole loop: the CHAIN has
    # no READ mode — every printable goes to `edit_chain` the moment the pane is focused —
    # but the default gate answers for the INPUT editor alone, so `6` in `base64` jumped to
    # the Fuzzer and took the half-typed chain with it. `base32`, `sha256`, `rot13`, `md5`,
    # `utf16`: no chain worth typing is digit-free.
    TuiContract.with_session("digit-decoder-chain") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :decoder
      ctl = DecoderController.new(host)
      ctl.pane_advance(1) # INPUT ▸ CHAIN
      ctl.body_takes_text?.should be_true

      "base64".each_char { |ch| ctl.handle_body_key(TuiContract.plain(ch)) }
      ctl.chain_spec.should eq("base64") # the character landed; the tab did not change
    end
  end

  it "is text in the Evidence `/` filter" do
    # Same class as History's and Issues' query bars, and it was missed the same way: the
    # controller has a filter bar and no override, so `evidence:26` jumped two tabs.
    TuiContract.with_session("digit-evidence") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :evidence
      ctl = EvidenceController.new(host)
      ctl.body_takes_text?.should be_false
      ctl.view.start_query
      ctl.body_takes_text?.should be_true

      ctl.handle_body_key(TuiContract.plain('6')).should be_true
      ctl.view.query.should eq("6")
    end
  end

  it "is text in the Help `/` search" do
    TuiContract.with_session("digit-help") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :help
      ctl = HelpController.new(host)
      ctl.body_takes_text?.should be_false
      ctl.handle_body_key(TuiContract.plain('/')).should be_true
      ctl.body_takes_text?.should be_true
      # `body_badge` is the controller's own public answer to "a search is running"; the
      # typed character is read off the view, which owns the query string.
      ctl.handle_body_key(TuiContract.plain('6')).should be_true
      ctl.body_badge.should eq(:editor)
    end
    # …and the character itself, at the seam that holds it (HelpView#search_query).
    view = HelpView.new
    view.handle_search_key(TuiContract.plain('/'), :shortcuts).should be_true
    "utf16".each_char { |ch| view.handle_search_key(TuiContract.plain(ch), :shortcuts) }
    view.search_query.should eq("utf16")
  end

  it "is text in the Fuzzer SNI row even when the mode badge dropped the field out of INS" do
    # The TARGET card's second row takes characters whenever it is the active field —
    # `FuzzerController#edit_target` routes to `edit_sni` before it consults the mode — so
    # a click on the mode badge could leave a field swallowing letters while the gate said
    # "navigation". RepeaterView's `pane_insert?` already read it this way.
    TuiContract.with_session("digit-fuzz-sni") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :fuzzer
      ctl = FuzzerController.new(host)
      ctl.fuzz_new
      v = ctl.current_view.not_nil!
      v.focus_pane(:target)
      v.toggle_sni_field # ^S → the SNI row, in INS
      ctl.body_takes_text?.should be_true
      v.exit_target_insert! # what the mode-badge click does, without closing the row
      ctl.body_takes_text?.should be_true
    end
  end

  it "is navigation in Notes' READ mode, and text in INS" do
    TuiContract.with_session("digit-notes") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :notes
      ctl = NotesController.new(host)
      ctl.body_takes_text?.should be_false
      ctl.view.enter_insert!
      ctl.body_takes_text?.should be_true
    end
  end

  it "is navigation in the Issues list and detail, and text in the detail's notes editor" do
    TuiContract.with_session("digit-issues") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :issues
      ctl = IssuesController.new(host)
      ctl.body_takes_text?.should be_false
      ctl.view.start_query # the `/` bar IS text
      ctl.body_takes_text?.should be_true
    end
  end

  it "is text in the History `/` query bar" do
    TuiContract.with_session("digit-history") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :history
      ctl = HistoryController.new(host)
      ctl.body_takes_text?.should be_false
      ctl.view.start_query
      ctl.body_takes_text?.should be_true # `status:404` must not jump four tabs
    end
  end
end

# Where the claim SITS in `Runner#handle_key`. The whole fix is an ordering, and an ordering
# is exactly what a later edit moves without noticing.
describe "the digit family — dispatch order" do
  code = runner_code
  claim = code.index(&.includes?("tab_digit_family?(ev)"))

  it "is claimed once, above every handler that used to swallow it" do
    claim.should_not be_nil, "the digit arm is gone — `1`-`9` are back to working in half the panes"
    i = claim.not_nil!
    # The four families of early return the audit found. Each returns before the keymap, so a
    # digit reaching them never reaches `nav.posN`.
    {
      "handle_subtabs_key(ev)"  => "the sub-tab strip",
      "handle_detail_key(ev)"   => "the Issues / History drill-in details",
      "handle_body_key(ev)"     => "every controller's body keys",
      "handle_editor_tab(ev)"   => "the editor Tab claim",
      "handle_complete_key(ev)" => "the Decoder chain autocomplete",
    }.each do |token, what|
      at = code.index(&.includes?(token))
      at.should_not be_nil, "#{what} is gone — this scan rotted before the rule did"
      at.not_nil!.should be > i, "the digit family is claimed BELOW #{what}, so it is swallowed there"
    end
  end

  it "is claimed below the modals and prompts, which own their own digits" do
    i = claim.not_nil!
    # A picker's filter, the CVSS calculator's score keys, the hotkey editor recording a
    # chord, the ^G "go to line" prompt: every one of them is a digit that is not a tab jump,
    # and every one of them returns before this arm.
    {
      "raw_capture && ov"                => "the hotkey capture branch",
      "return handle_goto_key(ev)"       => "the ^G go-to-line prompt",
      "return handle_search_key(ev)"     => "the ^F find prompt",
      "return handle_palette_key(ev)"    => "the command palette",
      "dispatch_overlay_key(ov, ev)"     => "every migrated modal",
      "return handle_space_menu_key(ev)" => "the space menu",
    }.each do |token, what|
      at = code.index(&.includes?(token))
      at.should_not be_nil, "#{what} is gone — this scan rotted before the rule did"
      at.not_nil!.should be < i, "the digit family is claimed ABOVE #{what}, so it steals its digits"
    end
  end

  it "stands down while a field is taking text" do
    line = runner_code.find(&.includes?("tab_digit_family?(ev)")).not_nil!
    line.should contain("text_input_active?")
  end

  it "resolves through the keymap, so the family stays rebindable" do
    # Not `focus_visible_tab(n)` inline: the hotkey editor lists `nav.goto` and the eighteen
    # positional verbs, and a rebind that the shell's own pre-keymap arm ignored would be a
    # setting that silently does nothing.
    line = runner_code.find(&.includes?("tab_digit_family?(ev)")).not_nil!
    idx = runner_code.index(line).not_nil!
    runner_code[idx + 1].should contain("dispatch_chord(ev)")
  end
end
