require "../spec_helper"

# The sub-tab strip renames on the space menu's Rename letter (#1295). It was `r`, while the
# menu's Rename is `e` on all nine strips and its `r` is Send/Run on four of them, so the same
# card taught two spellings for one action and put the strip's key on another row's letter.
#
# There is no Runner in any spec (see subtab_find_key_spec.cr), so the strip's key table is read
# from source: the letter `rename_chord?` claims must be the lexicon's `:rename`, and the strip
# hint and Help rows must name that letter. Comments are stripped first — a comment explaining
# the rule contains the tokens the rule looks for.
private def code_lines(path : String) : Array(String)
  File.read(path).lines.reject(&.lstrip.starts_with?('#'))
end

private def tui_src(*parts : String) : String
  File.join(__DIR__, "..", "..", "src", "gori", "tui", *parts)
end

describe "the strip's rename key" do
  runner = code_lines(tui_src("runner.cr"))
  start = runner.index(&.includes?("def rename_chord?"))
  guard = start ? runner[start + 1] : ""
  letter = guard.match(/lower_([a-z])\?/).try(&.[1])
  rename = Gori::Verb::Lexicon.letter(:rename).to_s

  it "is the space menu's Rename letter" do
    letter.should eq(rename)
  end

  it "is named by the strip hint" do
    hint = runner.find(&.includes?("renameable_subtabs? ? \" · "))
    hint.should_not be_nil, "the strip hint's rename clause is gone — this scan rotted"
    hint.not_nil!.should contain("\" · #{rename} rename\"")
  end

  # A Help row names the key column first and pairs it with the description by ` · ` position
  # ("^W · e" ↔ "close · rename…"), so the rename clause's key is the key column's last token.
  it "is named by every Help row that documents it" do
    rows = code_lines(tui_src("help_view.cr")).compact_map do |line|
      next unless m = line.match(/Item\.new\("([^"]*)", "([^"]*rename[^"]*)"/)
      next if m[2].includes?("right-click")
      {m[1], m[2]}
    end
    rows.size.should be >= 4
    rows.each { |(keys, what)| keys.split(" · ").last.should eq(rename), "#{keys} — #{what}" }
  end
end
