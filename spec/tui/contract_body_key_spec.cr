require "../support/tui_contract"

include Gori::Tui

# CONTRACT: a chord the operator can BIND is never swallowed by a tab body.
#
# `Runner#handle_key` does `return if c.handle_body_key(ev)`, so `true` means "consumed —
# never show this key to the keymap". A pane that answers true for a chord it does not own
# silently shadows whatever the operator bound there, and nothing says so: the key just stops
# working on that tab.
#
# `ctrl_letter_guard_spec.cr` proves this for the two panes where it was reported (the
# Rewriter's extract strip and the Colormarker's colours pane, which fired their bare-letter
# actions on `^A`/`^E`/`^X` because `Event::Key#char` falls back to `key.to_char`). This is
# the same rule stated once for every controller — and it found the OTHER half of the same
# trap, the one a per-pane spec had no reason to look for: `Event::Key#key`. The parser
# decodes 0x01..0x1A as `(LowerA..LowerZ, Ctrl)`, so a `key.lower_k?` arm is true for `^K`
# too, and five panes were walking their lists on it.
#
# WHICH chords are the operator's is not a list this spec keeps. `Hotkeys.claimed?` names the
# guard family (^G/^F/^B/^E/^P/^N/^W/^Z + ^1-9 + ^,) and `Verb::Reserved.reserved?` names the
# ones a terminal cannot deliver as a distinct chord at all (^H/^I/^J/^M arrive as
# Backspace/Tab/Enter; ^C/^D quit). Everything else is offered by the hotkey editor, so
# everything else has to reach the keymap.
private def bindable_letters(ctrl : Bool) : Array(Char)
  ('a'..'z').select do |ch|
    chord = Gori::Verb::Chord.new(ch.to_s, ctrl: ctrl, alt: !ctrl)
    !Gori::Hotkeys.claimed?(chord) && Gori::Verb::Reserved.reserved?(chord).nil?
  end
end

describe "TabController contract — a bindable chord reaches the central keymap" do
  it "no controller consumes a bindable Ctrl+letter" do
    TuiContract.with_session("ctrl-contract") do |session|
      swallowed = [] of String
      TuiContract.each_controller(session) do |controller, _host|
        bindable_letters(ctrl: true).each do |ch|
          swallowed << "#{controller.class}: ^#{ch}" if controller.handle_body_key(TuiContract.ctrl(ch))
        end
      end
      swallowed.should be_empty
    end
  end

  # The ⌥ twin. `Settings.command_modifier == "alt"` makes ⌥ an *additive* alias for the
  # claimed ctrl family; outside it every ⌥+letter is bindable, and an ⌥ event carries the
  # bare letter in both `char` and `key` just as a ctrl one does. Nothing in the set is editor
  # motion either — `TabController#editing_motion?` covers only ←/→/Home/End/⌫ — so a pane has
  # no legitimate claim on any of these.
  it "no controller consumes a bindable Alt+letter" do
    TuiContract.with_session("alt-contract") do |session|
      swallowed = [] of String
      TuiContract.each_controller(session) do |controller, _host|
        bindable_letters(ctrl: false).each do |ch|
          swallowed << "#{controller.class}: ⌥#{ch}" if controller.handle_body_key(TuiContract.alt(ch))
        end
      end
      swallowed.should be_empty
    end
  end

  # The other half of the same contract, and the reason the two above are not satisfied by a
  # blanket "return false": a pane still has to take the BARE form of the key it navigates
  # with. Every controller the first example flagged reached its `k` arm through `key.lower_k?`
  # — the fix narrows that arm to the unmodified press (`TabController#nav_up?`), so this pins
  # that `k` itself still works and a future over-correction fails here instead of passing both.
  it "the bare vim keys those panes navigate with are still consumed" do
    TuiContract.with_session("bare-letter-control") do |session|
      TuiContract.each_controller(session) do |controller, _host|
        next unless {:comparer, :discover, :fuzzer, :miner, :sequencer}.includes?(controller.tab)
        controller.handle_body_key(TuiContract.plain('k')).should be_true
      end
    end
  end
end
