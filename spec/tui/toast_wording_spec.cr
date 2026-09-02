require "../spec_helper"

include Gori::Tui

# What gori SAYS back, held to the same standard as what it draws.
#
# `Runner#status`, `@toast = …` and an overlay's `on_toast` all land on one strip, so they are
# one vocabulary — and it had drifted into three shapes for a delete, two for a refusal, two
# quoting styles, and `cannot`/`can't` split by module rather than by meaning.
describe "status-strip wording" do
  root = File.join(__DIR__, "..", "..", "src", "gori", "tui")

  it "reports a delete as `<noun> deleted: <name>`" do
    # Noun-first, so the success line reads in parallel with the failure template it shares a
    # keypress with (`colour rule NOT deleted (project busy) — …`), and NAMED, so a fast
    # sequence of deletes can be checked afterwards. The `removed <noun>:` and
    # `deleted <noun> "<name>"` variants are the two this replaced.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/(status|toast)\(.*"removed /)
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end

  it "refuses with `<noun> NOT <verbed> (<cause>) — <consequence>`" do
    # The template says what is STILL TRUE, which is the part an operator acts on. Two sites
    # abandoned it for `delete failed — project busy, marks kept; try again` — the corpus's
    # only `<verb> failed` refusal, its only semicolon, and `—` introducing the cause where
    # every peer puts the consequence.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/(status|toast)\(.*"[a-z ]*delete failed/)
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end

  it "quotes a user value in confirm bodies only, and curly" do
    # Two tiers, one rule each: a confirm body is a SENTENCE and quotes the name; a toast is a
    # one-line report where `deleted: <name>` already marks what follows. The straight-quoted
    # `\"…\"` form was in both, including two confirms — so DELETE FLOW and DELETE ISSUE wore
    # a different quote from every other dialog.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.includes?("confirm(")
        next unless line.matches?(/\\"#\{/)
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end

  it "says can't, not cannot" do
    # Near-even (13 vs 15) and split by MODULE, not by meaning: engine controllers said
    # `cannot`, the shell and pickers `can't`. Confirms have always said "This can't be undone."
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/(status|toast|@toast =)\(?.*"[^"]*\bcannot\b/)
        offenders << "#{File.basename(path)}:#{i + 1}"
      end
    end
    offenders.should be_empty
  end

  it "tells a new session to EDIT, not to type — its fields open in READ" do
    # `^N` lands on a field in READ mode on every tab that has one, so a line telling the
    # operator to `type` names a gesture that does nothing — and on the Fuzzer, whose field
    # holds a URL, the digits fired the global `nav.posN` tab jump and walked the operator off
    # the session they had just made. `repeater_new` had it right ("edit the request &
    # target"); the fuzzer's line promised the mode it does not open in.
    offenders = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/(status|toast)\(.*"new [^"]*\btype\b/)
        offenders << "#{File.basename(path)}:#{i + 1} — #{line.strip}"
      end
    end
    offenders.should be_empty
  end
end

# The strip's spinner / ✓ / ✗ used to come from MATCHING THE MESSAGE TEXT against English
# prefixes, which made `format_status_message` the one place where renaming a toast silently
# changed how it looked — and it did: `fuzz error:` became `fuzzer error:` for the sake of one
# noun per engine, and the ✗ simply stopped appearing. The glyph now rides a KIND passed with
# the toast (`status(message, :error)`), so the wording — or the language it is drawn in — is
# free to change. What this guards is the other direction: an engine error toast that forgot
# to say it is one.
describe "status glyph kinds" do
  it "mark every engine's error toast as :error" do
    root = File.join(__DIR__, "..", "..", "src", "gori", "tui")
    # Only what reaches the STRIP. The same `<x> error:` shape is also used for text drawn
    # INTO a pane — `config error:` in the Fuzzer/Miner config bodies, `upstream error:` in a
    # History detail line, `wordlist error:` as a returned string — and those are not status
    # messages, so no glyph applies to them.
    emitted = [] of String
    unmarked = [] of String
    Dir.glob(File.join(root, "**", "*.cr")).sort.each do |path|
      File.read(path).lines.each_with_index do |line, i|
        next unless line.matches?(/(status\(|@toast =|toast\()/)
        next unless line.matches?(/"([a-z]+ error): #\{/)
        line.scan(/"([a-z]+ error): #\{/) { |m| emitted << m[1] }
        unmarked << "#{File.basename(path)}:#{i + 1}" unless line.includes?(", :error)")
      end
    end
    emitted.uniq.sort.should eq(["discover error", "fuzzer error", "miner error",
                                 "probe error", "repeater error", "sequencer error"])
    unmarked.should be_empty
    # …and the text-matching table is gone for good, not merely bypassed.
    File.read(File.join(root, "runner.cr")).should_not contain("ERROR_PREFIXES")
  end
end
