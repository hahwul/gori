require "../spec_helper"
require "../support/tui_contract"

# The keyset seen from the SURFACES: a hint strip, the `i` refusal and the hotkey editor's
# "reset to default" all resolve through the effective keymap, so picking `vim` has to reach
# them with no per-surface edit. That is the payoff of step 1 (the editor keys became verbs
# and the strips became `{verb.id}` templates) and the thing most likely to rot — a strip
# rewritten as a literal would keep passing every other spec while saying `x` to an operator
# whose `x` no longer selects anything.
private def with_keyset(name : String, &)
  prev = Gori::Settings.editor_keyset
  Gori::Settings.editor_keyset = name
  begin
    yield
  ensure
    Gori::Settings.editor_keyset = prev
  end
end

describe "the editor keyset, from the surfaces" do
  r = Gori::Verbs.registry

  it "moves the keys a hint strip names, without the strip being touched" do
    with_keyset("helix") do
      Gori::Hotkeys.expand(r, "{editor.insert} edit · {repeater.select-line} line · {editor.undo} undo")
        .should eq("i edit · x line · ^Z undo")
      Gori::Hotkeys.expand(r, "{editor.find} find · {notes.select-line} line")
        .should eq("^F find · x line")
    end
    with_keyset("vim") do
      Gori::Hotkeys.expand(r, "{editor.insert} edit · {repeater.select-line} line · {editor.undo} undo")
        .should eq("i edit · ⇧V line · u undo")
      Gori::Hotkeys.expand(r, "{editor.find} find · {notes.select-line} line")
        .should eq("/ find · ⇧V line")
      # Unmoved, and each for a reason the docs give: copy is already vim's letter, INSERT is
      # already `i`, and goto-line would want `:N` — which Verb::Reserved keeps for the
      # command line.
      Gori::Hotkeys.expand(r, "{repeater.copy} copy · {editor.goto-line} goto")
        .should eq("y copy · ^G goto")
    end
  end

  it "reaches a live Repeater READ pane's footer and a Notes footer" do
    TuiContract.with_session("keyset-strips") do |session|
      host = TuiContract::Host.new(session)

      host.tab = :repeater
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      rep.current_view.not_nil!.focus_pane(:request)
      with_keyset("helix") { rep.body_hint(:body).should contain("i/↵ edit") }
      with_keyset("vim") do
        hint = rep.body_hint(:body)
        hint.should contain("i/↵ edit") # `i` is vim's letter too
        hint.should contain("u undo")   # …and ^Z is not
        hint.should contain("/ find")
      end

      host.tab = :notes
      notes = Gori::Tui::NotesController.new(host)
      with_keyset("helix") { notes.body_hint(:body).should contain("^F find") }
      with_keyset("vim") { notes.body_hint(:body).should contain("/ find") }
    end
  end

  it "keeps the `i` refusal firing on the read-only pane beside an editor" do
    # The refusal is checked ahead of the keymap, and `i` is `editor.insert` under BOTH
    # keysets — so a pane that is not an editor must still explain itself rather than let the
    # press fall through to the Global intercept toggle.
    TuiContract.with_session("keyset-refusal") do |session|
      host = TuiContract::Host.new(session)
      host.tab = :repeater
      rep = Gori::Tui::RepeaterController.new(host)
      rep.repeater_new
      v = rep.current_view.not_nil!
      %w[helix vim].each do |ks|
        with_keyset(ks) do
          v.focus_pane(:response)
          rep.insert_key_refusal.should_not be_nil
          rep.editor_pane?.should be_false
          v.focus_pane(:request)
          rep.insert_key_refusal.should be_nil # the editor gets its `i`
          rep.editor_pane?.should be_true
        end
      end
    end
  end

  it "resets a rebound key to the ACTIVE keyset's spelling, not the verb file's" do
    # `default_for` is what the hotkey editor's "reset" row reverts to. Under vim that has to
    # be ⇧V: reverting to the `x` the verb file declares would hand the operator a key their
    # keyset does not use, from a button labelled "default".
    with_keyset("helix") do
      Gori::Hotkeys.default_for(r, "notes.select-line", "auto").should eq(Gori::Verb::Chord.new("x"))
    end
    with_keyset("vim") do
      Gori::Hotkeys.default_for(r, "notes.select-line", "auto")
        .should eq(Gori::Verb::Chord.new("v", shift: true))
    end
  end

  it "reports a conflict against the keyset the operator is running" do
    # Binding something to ⇧V under vim must say "Select line is there" even though the verb
    # file says `x` — the editor answers about the live keymap, not the shipped one.
    with_keyset("vim") do
      c = Gori::Hotkeys.conflict(r, "notes.copy", Gori::Verb::Chord.new("v", shift: true),
        Gori::Verb::Keymap::NO_OVERRIDES)
      c.should_not be_nil
      c.not_nil!.verb_id.should eq("notes.select-line")
    end
    with_keyset("helix") do
      Gori::Hotkeys.conflict(r, "notes.copy", Gori::Verb::Chord.new("v", shift: true),
        Gori::Verb::Keymap::NO_OVERRIDES).should be_nil
    end
  end

  it "clamps an unknown keyset name to the shipped one on the way in" do
    prev = Gori::Settings.editor_keyset
    begin
      Gori::Settings.editor_keyset = Gori::Settings.normalize_editor_keyset("vim")
      Gori::Settings.editor_keyset.should eq("vim")
      Gori::Settings.editor_keyset = Gori::Settings.normalize_editor_keyset("nano")
      Gori::Settings.editor_keyset.should eq("helix")
    ensure
      Gori::Settings.editor_keyset = prev
    end
  end
end
