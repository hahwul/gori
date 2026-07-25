require "../../spec_helper"
require "json"

# `gori run notes` — the listing row, the single-note object, and the whole-set array.
# The JSON shapes here are the documented contract scripts read; the MCP list_notes /
# get_note tools mirror the same fields.

describe "gori run notes — listing rows" do
  it "formats a row: 1-based index, title, '*' for the active note" do
    row = Gori::CLI::Output.note_row_text(1, "scope\nmore", current: true)
    row.should contain("* 2")                                                           # 0-based 1 → shown as #2
    row.should contain("scope")                                                         # title = first non-blank line
    row.should contain("(2 lines, ")                                                    # plural
    Gori::CLI::Output.note_row_text(0, "x", current: false).should contain(" 1")        # no '*'
    Gori::CLI::Output.note_row_text(0, "x", current: false).should contain("(1 line, ") # singular
  end

  it "falls back to 'note N' for a blank note" do
    Gori::CLI::Output.note_row_text(2, "   \n\t", current: false).should contain("note 3")
    Gori::CLI::Output.note_label(2, "   \n\t").should eq("note 3")
    Gori::CLI::Output.note_label(0, "Title\nbody").should eq("Title")
  end

  it "counts BYTES, not characters, in the row size" do
    # The size is a storage figure; a multi-byte note reported in characters would
    # under-report by 2-3× on any non-ASCII corpus.
    text = "데이터" # 3 chars, 9 bytes
    Gori::CLI::Output.note_row_text(0, text, current: false).should contain("9B")
  end
end

describe "gori run notes show --format json" do
  it "emits the documented fields, with the body only when asked" do
    entry = Gori::Notes::NoteEntry.new(42_i64, "Title\nbody")
    full = JSON.parse(Gori::CLI::Output.note_object_json(0, entry, current: true, with_text: true))
    full["id"].as_i64.should eq(42_i64)
    full["index"].as_i.should eq(1)
    full["title"].as_s.should eq("Title")
    full["lines"].as_i.should eq(2)
    full["bytes"].as_i.should eq("Title\nbody".bytesize)
    full["current"].as_bool.should be_true
    full["text"].as_s.should eq("Title\nbody")

    summary = JSON.parse(Gori::CLI::Output.note_object_json(0, entry, current: false, with_text: false))
    summary["text"]?.should be_nil # summary omits the body
    summary["title"].as_s.should eq("Title")
  end

  it "emits a null title for a blank note rather than the positional fallback" do
    # The listing's "note 3" is a DISPLAY fallback; JSON must report the absence so a
    # script can tell "untitled" from a note literally titled "note 3".
    entry = Gori::Notes::NoteEntry.new(1_i64, "   \n\t")
    JSON.parse(Gori::CLI::Output.note_object_json(2, entry, current: false, with_text: false))["title"].raw.should be_nil
  end
end

describe "gori run notes --format json (whole set)" do
  it "emits an array marking the active note" do
    doc = Gori::Notes::Doc.new(1, [
      Gori::Notes::NoteEntry.new(1_i64, "one"),
      Gori::Notes::NoteEntry.new(2_i64, "two"),
    ], 3_i64)
    arr = JSON.parse(Gori::CLI::Output.notes_array_json(doc, with_text: false)).as_a
    arr.size.should eq(2)
    arr[0]["id"].as_i64.should eq(1_i64)
    arr[0]["index"].as_i.should eq(1)
    arr[0]["current"].as_bool.should be_false
    arr[1]["current"].as_bool.should be_true # cur == 1
    arr[0]["text"]?.should be_nil            # summary array

    with_text = JSON.parse(Gori::CLI::Output.notes_array_json(doc, with_text: true)).as_a
    with_text[1]["text"].as_s.should eq("two")
  end

  it "emits a valid empty array for a project with no notes" do
    # A script parsing `gori run notes --format json` must always get valid JSON, even in
    # the empty state (the text view prints its note to STDERR instead).
    empty = Gori::Notes::Doc.new(0, [] of Gori::Notes::NoteEntry, 1_i64)
    Gori::CLI::Output.notes_array_json(empty, with_text: false).should eq("[]")
  end

  it "carries a note body VERBATIM into JSON, escapes and all" do
    # JSON output is the byte-exact path for scripts (unlike the text view, which scrubs
    # control bytes before the terminal sees them) — the escaping must be JSON's, not ours.
    entry = Gori::Notes::NoteEntry.new(1_i64, "a\e[31m\tb")
    doc = Gori::Notes::Doc.new(0, [entry], 2_i64)
    parsed = JSON.parse(Gori::CLI::Output.notes_array_json(doc, with_text: true)).as_a
    parsed[0]["text"].as_s.should eq("a\e[31m\tb")
  end
end
