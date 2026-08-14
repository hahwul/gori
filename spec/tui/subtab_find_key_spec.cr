require "../spec_helper"

# `f` on the sub-tab strip opens the ⌕ picker from whichever chip the operator is standing on.
#
# There is no Runner in any spec in this repo (`Runner.new` appears nowhere under spec/), so
# the strip's key table cannot be driven here — `handle_subtabs_key` is private on a class that
# owns a terminal. What CAN be pinned in source is the pair of rules that made the key worth
# adding, and both of them are rules a future edit would break silently:
#
#   1. The gate is EXISTENCE (`subtab_find_shown?`), not WIDTH (`subtab_find_icon_rect`).
#      A terminal too narrow to draw the pill is precisely where the `←` route already fails —
#      `step_left_or_find` checks the rect and no-ops — so a key that vanished with the glyph
#      would leave the one state with no keyboard route to the picker at all.
#   2. The strip hint names the same letter the handler claims. The hint is a hand-written
#      string with no compiler behind it, and it is the operator's only notice that the key
#      exists (strip focus returns before the keymap, so the key is in no menu and no Hotkeys
#      row). The letter is READ from the handler here rather than spelled twice, so changing
#      one side fails rather than drifting.
#
# Comments are stripped before every check: a comment explaining a rule contains the tokens the
# rule looks for, and a whole-file `includes?` passes on the strength of its own prose. This
# file has been fooled that way three times.
private def code_lines(path : String) : Array(String)
  File.read(path).lines.reject(&.lstrip.starts_with?('#'))
end

private def tui_src(*parts : String) : String
  File.join(__DIR__, "..", "..", "src", "gori", "tui", *parts)
end

# The body of a `private def name` at method indentation, comments already gone.
private def method_body(lines : Array(String), name : String) : Array(String)
  start = lines.index(&.includes?("def #{name}"))
  start.should_not be_nil, "#{name} is gone — this scan rotted before the rule did"
  rest = lines[start.not_nil! + 1..]
  stop = rest.index { |l| l.rstrip == "  end" }
  rest[0...(stop || 0)]
end

describe "the strip's find-sub-tab key" do
  subtabs = code_lines(tui_src("runner", "subtabs.cr"))
  guard = method_body(subtabs, "find_subtab_chord?").join('\n')
  letter = guard.match(/lower_([a-z])\?/).try(&.[1])

  it "claims a bare letter and hands it to the shared picker entrance" do
    letter.should_not be_nil, "find_subtab_chord? no longer matches a letter key"
    # The arm, and the one method behind every entrance to the picker (pill ↵, click, verbs).
    arm = subtabs.index(&.includes?("find_subtab_chord?(ev)"))
    arm.should_not be_nil
    subtabs[arm.not_nil! + 1].should contain("subtab_search_open")
  end

  it "gates on whether the strip HAS a picker, never on whether the pill fits" do
    guard.should contain("subtab_find_shown?")
    # `subtab_find_icon_rect` recomputes the layout to answer "is the pill on screen at this
    # width", and `subtab_find_focused?` is that plus a focus hint. Either one as the gate
    # re-closes the narrow-terminal hole this key was added to open.
    guard.should_not contain("subtab_find_icon_rect")
    guard.should_not contain("subtab_find_focused?")
  end

  # Every strip hint gori emits, split by the one thing that tells the two families apart:
  # a FIXED strip (Help/Probe/Target/OAST) has no create/close, and no ⌕ pill either.
  runner = code_lines(tui_src("runner.cr"))
  hints = runner.flat_map do |line|
    line.scan(/"([^"]*)"/).map(&.[1]).select(&.starts_with?("←/→ switch sub-tab"))
  end
  navigable, fixed = hints.partition(&.includes?("^W close"))

  it "advertises the key on every strip that has one" do
    navigable.size.should be >= 2 # Miner/Sequencer read-only strips + the editor strips
    navigable.each do |hint|
      hint.should contain("#{letter} find"), "a strip hint names no find key: #{hint}"
    end
  end

  it "does not advertise it on the strips that have no picker" do
    # `subtab_find_shown?` is false for a fixed strip, so naming `f` there would be a key that
    # does nothing — the exact defect the hint above exists to avoid in the other direction.
    fixed.should_not be_empty
    fixed.each do |hint|
      hint.should_not contain("#{letter} find"), "a fixed strip hint names a dead key: #{hint}"
    end
  end
end
