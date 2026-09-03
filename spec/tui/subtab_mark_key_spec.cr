require "../spec_helper"

# `t` / `⇧T` on the sub-tab strip mark chips (#683). As with the find key beside them, there
# is no Runner in any spec, so the strip's key table cannot be driven here. What CAN be pinned
# in source is the set of rules a future edit would break silently — and two of them break
# without a compiler, a boot gate, or a visible symptom:
#
#   1. `⇧T` is read as `upper_t?`, never as `shift? && lower_t?`. A terminal delivers a typed
#      capital as the character itself with no shift modifier (Keybind.from_event), so the
#      modifier spelling is dead code. A verb chord spelled that way is refused at boot by
#      `validate_chords!`; a raw handler arm has no such gate.
#   2. `t` is the mark key on EVERY strip, not a Repeater-only arm. It used to be Repeater's
#      tag prompt; the whole point of the move is that `t` now means one thing on every list
#      and strip in gori, so a scope guard creeping back is a regression, not a refinement.
#
# The remaining rules are the same shape the find key pins: the hint advertises the letter
# the handler claims, on exactly the strips that have it.
#
# Comments are stripped before every check — a comment explaining a rule contains the tokens
# the rule looks for.
private def code_lines(path : String) : Array(String)
  File.read(path).lines.reject(&.lstrip.starts_with?('#'))
end

private def tui_src(*parts : String) : String
  File.join(__DIR__, "..", "..", "src", "gori", "tui", *parts)
end

private def method_body(lines : Array(String), name : String) : Array(String)
  start = lines.index(&.includes?("def #{name}"))
  start.should_not be_nil, "#{name} is gone — this scan rotted before the rule did"
  rest = lines[start.not_nil! + 1..]
  stop = rest.index { |l| l.rstrip == "  end" }
  rest[0...(stop || 0)]
end

describe "the strip's mark keys" do
  subtabs = code_lines(tui_src("runner", "subtabs.cr"))
  toggle = method_body(subtabs, "mark_chord?").join('\n')
  all = method_body(subtabs, "mark_all_chord?").join('\n')
  table = method_body(subtabs, "handle_subtabs_key")

  it "reads ⇧T as its own key, not as shift plus t" do
    all.should contain("upper_t?")
    all.should_not contain("shift?")
    all.should_not contain("lower_t?")
  end

  it "asks for ⇧T before t, so the capital cannot fall into the lowercase arm" do
    i_all = table.index(&.includes?("mark_all_chord?(ev)"))
    i_t = table.index(&.includes?("mark_chord?(ev)"))
    i_all.should_not be_nil
    i_t.should_not be_nil
    i_all.not_nil!.should be < i_t.not_nil!
  end

  it "marks on every strip that can, with no Repeater-only guard" do
    toggle.should contain("lower_t?")
    toggle.should contain("subtab_marks_shown?")
    toggle.should_not contain("@active_tab")
    # And the tag prompt no longer has a bare-letter arm on the strip: it is a menu entry.
    table.none?(&.includes?("open_tag_edit")).should be_true
  end

  it "lets esc drop the marks before it leaves the strip" do
    i_clear = table.index { |l| l.includes?("key.escape?") && l.includes?("subtab_marked_count") }
    i_leave = table.index { |l| l.includes?("key.escape?") && l.includes?("key.up?") }
    i_clear.should_not be_nil, "no esc-clears-marks arm"
    i_leave.should_not be_nil, "no esc-pops-to-menu arm"
    i_clear.not_nil!.should be < i_leave.not_nil!
  end

  it "never gives the mark verbs a chord — they are menu rows, the keys live here" do
    # A chord could not fire on the strip (`@focus == :subtabs` returns before the keymap) and
    # WOULD fire in the body, marking a sub-tab while the operator reads a response.
    r = Gori::Verbs.registry
    r.select { |v| v.id.ends_with?(".subtab-mark-all") || v.id.ends_with?(".subtab-mark-clear") }
      .tap(&.size.should(eq(18)))
      .each { |v| v.chords.should be_empty, "#{v.id} carries a chord" }
  end

  # The strip hints: the mark token is a local the two navigable hints splice in, and the
  # letter it names has to be the one the handler claims.
  runner = code_lines(tui_src("runner.cr"))
  mk_line = runner.find(&.includes?("mk = subtab_marks_shown?"))

  it "advertises the same letter the handler claims" do
    mk_line.should_not be_nil, "the strip hint no longer builds a mark token"
    letter = toggle.match(/lower_([a-z])\?/).try(&.[1])
    mk_line.not_nil!.should contain("#{letter} mark")
  end

  hints = runner.flat_map do |line|
    line.scan(/"([^"]*)"/).map(&.[1]).select(&.starts_with?("←/→ switch sub-tab"))
  end
  navigable, fixed = hints.partition(&.includes?("^W close"))

  it "puts the token on every strip that marks, and on no fixed strip" do
    navigable.size.should be >= 2
    navigable.each { |h| h.should contain("\#{mk}"), "a strip hint has no mark token: #{h}" }
    fixed.should_not be_empty
    fixed.each { |h| h.should_not contain("mark"), "a fixed strip hint names a dead key: #{h}" }
  end
end
