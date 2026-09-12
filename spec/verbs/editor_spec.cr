require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/editor.cr — `Verb::Scope::Editor`, the FOCUS dimension the keymap did not
# have. Three invariants carry the file:
#   1. Every verb lives in Scope::Editor and nowhere else. The scope is consulted AHEAD of
#      the active tab's own scope while a text editor pane holds focus (Runner#resolve_verb_id),
#      so a verb that leaked into a tab scope would either shadow or be shadowed silently.
#   2. The BARE-key verbs gate on READ mode. In INS every editor ladder claims printables
#      upstream of dispatch, so a bare-key verb available in INS would be a verb that can
#      never fire — and worse, would read as one that should.
#   3. `^Z`/`^F`/`^G` are guard-claimed chords. They are declared so a KEYSET has a row to
#      respell, and listed in Hotkeys::FIXED_IDS so the per-verb rebind editor never offers
#      to move a chord a hardcoded handler answers first.
describe "Gori::Verbs.register_editor" do
  r = Gori::Verbs.registry

  ids = %w[editor.insert editor.insert-enter editor.append editor.exit-insert
    editor.undo editor.top editor.bottom editor.goto-line editor.find]

  it "registers the editor family in Scope::Editor and nowhere else" do
    ids.each { |id| r[id].scope.should eq(Gori::Verb::Scope::Editor) }
    # …and nothing ELSE claims that scope, so the chain's first link is exactly this file.
    r.select(&.scope.editor?).map(&.id).sort!.should eq(ids.sort)
  end

  it "keeps today's keys: i / ↵ INSERT, esc back, ^Z ^F ^G — and nothing else bound" do
    r["editor.insert"].chords.should eq([Gori::Verb::Chord.new("i")])
    r["editor.insert-enter"].chords.should eq([Gori::Verb::Chord.new("enter")])
    r["editor.exit-insert"].chords.should eq([Gori::Verb::Chord.new("escape")])
    r["editor.undo"].chords.should eq([Gori::Verb::Chord.new("z", ctrl: true)])
    r["editor.find"].chords.should eq([Gori::Verb::Chord.new("f", ctrl: true)])
    r["editor.goto-line"].chords.should eq([Gori::Verb::Chord.new("g", ctrl: true)])
    # Keyless on purpose: gori's READ panes have no append and no bare top/bottom key today,
    # and the default keyset is "today's keys". They exist for a keyset to spell (and for a
    # user to bind — a keyless verb stays assignable in the hotkey editor).
    %w[editor.append editor.top editor.bottom].each { |id| r[id].chords.should be_empty }
  end

  it "gates the bare-key verbs on READ mode, not merely on the pane" do
    ctx = FakeExecContext.new
    bare = %w[editor.insert editor.insert-enter editor.append editor.undo editor.top editor.bottom]
    bare.each { |id| r[id].available?(ctx).should be_false } # no editor pane at all

    ctx.editor_pane = true
    bare.each { |id| r[id].available?(ctx).should be_false } # a pane, but it is taking text

    ctx.editor_read_mode = true
    bare.each { |id| r[id].available?(ctx).should be_true }
  end

  it "gates exit-insert on INS and the two prompts on the whole pane" do
    ctx = FakeExecContext.new
    ctx.editor_pane = true # INS: a pane, not in read mode
    r["editor.exit-insert"].available?(ctx).should be_true
    ctx.editor_read_mode = true
    r["editor.exit-insert"].available?(ctx).should be_false

    # ^G / ^F work from BOTH modes — finding while typing is the normal case.
    [true, false].each do |read|
      ctx.editor_read_mode = read
      r["editor.goto-line"].available?(ctx).should be_true
      r["editor.find"].available?(ctx).should be_true
    end
    ctx.editor_pane = false
    r["editor.find"].available?(ctx).should be_false
  end

  it "routes each verb to its own intent" do
    ctx = FakeExecContext.new
    ctx.editor_pane = true
    ctx.editor_read_mode = true
    {
      "editor.insert"       => :editor_enter_insert,
      "editor.insert-enter" => :editor_enter_insert,
      "editor.append"       => :editor_append_insert,
      "editor.undo"         => :editor_undo,
      "editor.top"          => :editor_to_top,
      "editor.bottom"       => :editor_to_bottom,
      "editor.goto-line"    => :editor_goto_line,
      "editor.find"         => :editor_find,
    }.each do |id, intent|
      c = FakeExecContext.new
      c.editor_pane = true
      c.editor_read_mode = true
      r[id].call(c)
      c.calls.map(&.name).should eq([intent])
    end
    ctx.editor_pane = true # exit-insert is the INS one
    ctx.editor_read_mode = false
    r["editor.exit-insert"].call(ctx)
    ctx.calls.map(&.name).should eq([:editor_exit_insert])
  end

  it "keeps the guard-claimed chords out of the per-verb rebind editor" do
    # Hotkeys::FIXED_IDS, same reason as view.reveal-ws's ^B: a hardcoded handler answers the
    # chord before the keymap, so a rebind would be accepted and then silently do nothing.
    %w[editor.exit-insert editor.undo editor.find editor.goto-line].each do |id|
      Gori::Hotkeys.rebindable?(r[id]).should be_false
    end
    # The rest ARE rebindable — including the keyless ones, which is how a helix-shaped
    # operator gets an `a` without adopting a whole keyset.
    %w[editor.insert editor.append editor.top editor.bottom].each do |id|
      Gori::Hotkeys.rebindable?(r[id]).should be_true
    end
  end

  it "carries distinct space-menu mnemonics, and no bare-letter default outside `i`" do
    keys = ids.compact_map { |id| r[id].menu_key }
    keys.uniq.size.should eq(keys.size)
    # The Editor scope is a KEYMAP scope, not a menu scope (the space menu renders exactly one
    # Scope, and an EDITOR bucket merged into eight tab menus has no collision-free set of
    # mnemonics — see .github/DESIGN.md). The mnemonics exist so that stays a choice, not a
    # dead end; what must hold today is that the scope claims exactly one bare letter.
    bare = ids.flat_map { |id| r[id].chords }.select { |c| !c.ctrl && !c.alt && !c.shift && c.key.size == 1 }
    bare.map(&.key).should eq(["i"])
  end
end
