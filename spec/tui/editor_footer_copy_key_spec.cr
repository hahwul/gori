require "../spec_helper"

# `^Y` is Copy in every text box (see `spec/verbs/core_spec.cr` for the keymap half). The
# footers were the half that never got told: five INS strips named it, five did not, and the
# operator's only route to the key was reading the commit that added it.
#
# Both rules here are about a footer that describes a mode it is not in.
#
#   A. A strip that says "⇧arrows select" and names no copy key. The Fuzzer template editor
#      was the pure case: it told you a band could be built and then named nothing that
#      copies one, while the bare `y` the READ strip advertises is — in that mode — a literal
#      character that REPLACES the band you just built. One keystroke, no toast, selection
#      gone. That is the bug report `^Y` exists to answer, and the footer is where it lands.
#
#   B. A strip that starts with `type ` and still offers `space cmds`. JWT's HEADER, PAYLOAD
#      and SECRET are always-typing panes (`JwtController#edit_json` / `#edit_secret` insert
#      the character; `#handle_body_key` only defers ctrl/alt chords), so that space typed a
#      space. It cost the one token with room to say which key copies — on the three panes
#      where `^Y` is not the convenient copy but the ONLY one.
#
# Checkable in source and cheap to check, which is the reason to: these are hand-written
# prose strings with no compiler behind them, and the pair of them drifted for ten strips.
describe "editor key-hint strips" do
  # Every double-quoted literal on `line`, with `#{…}` chord interpolations blanked (a hint
  # resolves rebindable chords through `Hotkeys.binding_label`, and the token we are looking
  # for is the prose beside it) and escaped quotes removed first, so ProjectController's
  # `"type \"IP host\" · ↵ save · esc cancel"` reads as one literal rather than three.
  literals = ->(line : String) do
    code = line.gsub("\\\"", "")
    code.scan(/"([^"]*)"/).map(&.[1].gsub(/\#\{[^}]*\}/, ""))
  end

  # A key hint, as opposed to any other string on the line: the strips are ` · `-separated
  # and every one of them has at least two segments.
  hint = ->(text : String) { text.includes?(" · ") }

  hint_sources = Dir.glob(File.join(__DIR__, "..", "..", "src", "gori", "tui", "**", "*.cr")).sort

  it "name a copy key whenever they advertise a selection" do
    offenders = [] of String
    hint_sources.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next if line.lstrip.starts_with?('#') # a comment quoting a strip is not a strip
        literals.call(line).each do |text|
          next unless hint.call(text) && text.includes?("⇧arrows select")
          next if text.matches?(/\bcop(y|ies)\b/) # Help's rows say "copies", the strips say "copy"
          offenders << "#{File.basename(path)}:#{i + 1} — #{text}"
        end
      end
    end
    offenders.should be_empty
  end

  it "do not offer the space menu from a mode where space types a space" do
    offenders = [] of String
    hint_sources.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next if line.lstrip.starts_with?('#')
        literals.call(line).each do |text|
          next unless hint.call(text) && text.starts_with?("type ")
          next unless text.includes?("space cmds")
          offenders << "#{File.basename(path)}:#{i + 1} — #{text}"
        end
      end
    end
    offenders.should be_empty
  end

  # Rule A's blind spot, closed at the file level. A strip that names NEITHER the band nor the
  # key is silent rather than wrong, so a per-string rule cannot see it — and that is exactly
  # how the Intercept held-bytes editor kept a registered `^Y` that nothing on screen mentioned
  # for its whole life. Anchored to the KEYMAP rather than to a hand-kept list: a verb only
  # earns the ctrl chord because its tab has an editor where bare `y` is a literal character,
  # so the tab that registers one owes its operator a strip that says so, somewhere.
  it "every tab whose Copy verb carries ^Y names it somewhere in its own footers" do
    ids = [] of String
    Dir.glob(File.join(__DIR__, "..", "..", "src", "gori", "verbs", "*.cr")).sort.each do |path|
      lines = File.read(path).lines
      lines.each_with_index do |line, i|
        next unless m = line.match(/"([a-z]+)\.copy", "Copy"/)
        # The chord list is the next line or two down (`Verb::Scope::X, [Chord…],`).
        next unless (i + 1..i + 3).any? { |j| lines[j]?.try(&.includes?(%(Chord.new("y", ctrl: true)))) }
        ids << m[1]
      end
    end
    ids.should_not be_empty # the scan itself is the thing most likely to rot

    # `issue` → issues_controller, `fuzzer` → fuzzer_controller; the rest are already the stem.
    controller = ->(id : String) do
      stem = {"issue" => "issues"}.fetch(id, id)
      File.join(__DIR__, "..", "..", "src", "gori", "tui", "controllers", "#{stem}_controller.cr")
    end

    # CODE lines only. A comment explaining why the strip names `^Y` contains the token too,
    # so a whole-file `includes?` passes on a controller whose strips say nothing — which is
    # precisely the state this rule exists to fail on. (Caught by control-running the rule
    # against the reverted Intercept strip: it passed, on the strength of its own comment.)
    offenders = ids.reject do |id|
      path = controller.call(id)
      next false unless File.exists?(path)
      File.read(path).lines.any? do |line|
        !line.lstrip.starts_with?('#') && literals.call(line).any?(&.includes?("^Y copy"))
      end
    end
    offenders.should be_empty
  end
end
