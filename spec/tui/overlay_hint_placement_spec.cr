require "../spec_helper"

# WHERE a modal's key hint is allowed to live.
#
# The shell already draws the open modal's `hint` in the bottom status strip
# (`Runner#key_hints` → `active_overlay.hint`), so a card that also painted a hint band was
# showing the same advice twice — and the two copies had drifted, because only one of them
# was the method every other surface reads. Six forms carried a literal that no longer
# matched their own `hint`, one of them with a `←/›` typo that could not be seen from the
# method at all.
#
# The rule that replaced them: a modal states KEYS in `hint` and nowhere else. What a card
# may still say on a band is what the operator cannot infer from the form itself — a match
# preview, a format rule, a refusal.
#
# Two placements are deliberately NOT covered here:
#   · the degraded "needs a larger window · esc to close" line, which draws from `area` when
#     the card cannot be drawn at all. It is the only thing on screen, so it names its escape.
#   · a per-row affordance like a cycler's `‹/›`, which marks the key where the key applies.
describe "Overlay key hints" do
  it "are not painted onto the card by any modal" do
    dir = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    # Vocabulary that only ever appears in a KEY hint. `esc to close` is absent on purpose:
    # it belongs to the degraded line, which draws from `area` and is exempt below.
    keyish = /esc cancel|esc close|esc saves|↵ save|↑\/↓ field|←\/→/
    offenders = [] of String
    glob_files(dir, "*.cr").sort.each do |path|
      src = File.read(path)
      next unless src.includes?("< Overlay")
      src.lines.each_with_index do |line, i|
        # `box.` is what makes it a band on the DRAWN card; the degraded line uses `area.`.
        next unless line.matches?(/screen\.text\(\s*box\./)
        next unless line.matches?(keyish)
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end

  it "spell the ←/→ clause the one way wherever it cycles options" do
    # Six spellings had accumulated for one gesture — `options` / `kind` / `kind·type` /
    # `scope/type` / `adjust` / `cycle` — which is exactly the drift an operator feels when
    # two rule forms sit one keystroke apart.
    #
    # Scoped to hint STRINGS (a hint always names its escape, which is what `esc` selects
    # for) and to forms that cycle: `←/→ edit` in the Fuzzer's advanced panel is NOT drift,
    # because there the arrows step a value rather than walk a list of choices. A rule that
    # forced one verb on both gestures would make the hint lie.
    dir = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    cyclers = %w[
      colormarker_rule_overlay custom_rule_overlay extract_rule_overlay
      mine_config_overlay oast_provider_overlay rewriter_rule_overlay
      scope_rule_overlay sequence_config_overlay
    ]
    offenders = [] of String
    cyclers.each do |name|
      path = File.join(dir, "#{name}.cr")
      File.read(path).lines.each_with_index do |line, i|
        line.scan(/"([^"]*←\/→ ([^ ·"]+)[^"]*)"/) do |m|
          next unless m[1].includes?("esc") # a hint names its escape; prose does not
          next if m[2] == "options"
          offenders << "#{name}.cr:#{i + 1} — ←/→ #{m[2]}"
        end
      end
    end
    offenders.should be_empty
  end
end
