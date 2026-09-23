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

  it "scrubs invalid UTF-8 out of the title and body so the document stays valid" do
    # `gori run notes create` takes its body from STDIN — piping a gzip/binary response body
    # (or a file $EDITOR wrote) stores raw bytes the settings KV round-trips verbatim. JSON
    # escapes control characters but passes an invalid BYTE straight through, so `--format
    # json` was writing a document whose own valid_encoding? was false.
    entry = Gori::Notes::NoteEntry.new(1_i64, String.new(Bytes[0x68, 0x69, 0x80, 0x0a, 0x78]))
    doc = Gori::CLI::Output.note_object_json(0, entry, current: true, with_text: true)
    doc.valid_encoding?.should be_true
    parsed = JSON.parse(doc)
    parsed["title"].as_s.should eq("hi\u{FFFD}")
    parsed["text"].as_s.should contain('\n') # a note is multi-line BY DESIGN — not collapsed
    parsed["bytes"].as_i.should eq(5)        # the STORED size, not the scrubbed one

    arr = Gori::CLI::Output.notes_array_json(
      Gori::Notes::Doc.new(0, [entry], 2_i64), with_text: true)
    arr.valid_encoding?.should be_true
    JSON.parse(arr)
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

# --- `notes delete --yes` (issue #1120) ------------------------------------------------
#
# The gate the rest of the delete family has had all along. The refusal helper is reached the
# same whitebox way `history delete`'s pins are: a bare call from inside the module, which
# Crystal permits where an explicit-receiver call from outside would not.

private def note(text : String) : Gori::Notes::NoteEntry
  Gori::Notes::NoteEntry.new(1_i64, text)
end

# `cmd_notes_delete`'s own lines — from its `def` to the NEXT one, the way
# `unknown_args_sweep_spec`'s `method_body` windows a method. Anchored on the following
# `def self.` rather than on a comment, so reordering the file cannot silently widen the
# window until a neighbour's code satisfies the assertions below.
private def notes_delete_body : String
  lines = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "notes.cr")).split("\n")
  starts = [] of Int32
  lines.each_with_index { |l, i| starts << i if l.matches?(/^      (private )?def self\./) }
  at = starts.index { |i| lines[i].matches?(/^      (private )?def self\.cmd_notes_delete\b/) }
  raise "cmd_notes_delete not found" unless at
  lines[starts[at]...(starts[at + 1]? || lines.size)].join("\n")
end

describe "gori run notes delete" do
  it "refuses without --yes and names the note that would go" do
    err = Gori::CLI::Run.note_delete_confirmation_error_for_spec(2, note("SSRF candidate on /fetch"), false).not_nil!
    err.should contain("note #2")
    err.should contain(%("SSRF candidate on /fetch")) # the first line, so a wrong index is visible
    err.should contain("--yes")
  end

  it "passes once --yes is given" do
    Gori::CLI::Run.note_delete_confirmation_error_for_spec(2, note("SSRF candidate"), true).should be_nil
  end

  it "says nothing extra for a blank note rather than echoing the index back as a name" do
    # `CLI::Output.note_label` would hand back "note 3" here; repeating the number the
    # operator just typed, in quotes, reads like a title they can check it against.
    err = Gori::CLI::Run.note_delete_confirmation_error_for_spec(3, note("   \n\t"), false).not_nil!
    err.should contain("note #3")
    err.should_not contain("\"")
  end

  it "still refuses a blank note, unlike the TUI's close-confirm" do
    # `notes.close` skips its modal for a blank note because the TUI judges the BUFFER on
    # screen. Headless reads the last committed text, so "blank" here can just mean a peer
    # has not saved yet — and the sentence must stay true of that note.
    err = Gori::CLI::Run.note_delete_confirmation_error_for_spec(3, note(""), false).not_nil!
    err.should contain("cannot be recovered")
    err.should_not contain("exists nowhere else")
  end

  it "neutralizes the control bytes a terminal would act on, INCLUDING the Cf class" do
    # A note is free text taken from $EDITOR, a paste or a pipe, so its "title" can carry
    # ANSI — this sentence goes straight to a terminal. `should_not contain('\e')` alone
    # would be vacuous (inspect escapes ESC by itself), so the escape TEXT is refused too.
    err = Gori::CLI::Run.note_delete_confirmation_error_for_spec(1, note("a\e[31mred"), false).not_nil!
    err.should_not contain('\e')
    err.should_not contain("\\u001B") # what inspect alone, without term_safe, would leave
    err.should contain("a·[31mred")

    # U+202E (RIGHT-TO-LEFT OVERRIDE) reverses everything after it without changing a byte —
    # the one input class that can defeat "is this the note I meant". Crystal's `Char#control?`
    # is Cc AND Cf, so `term_safe` catches it where `Issues::Export.one_line`'s `[[:cntrl:]]`
    # (Cc only) would not; this is why the helper does not reuse that one.
    bidi = Gori::CLI::Run.note_delete_confirmation_error_for_spec(1, note("a\u{202E}gnitset"), false).not_nil!
    bidi.should_not contain('\u{202E}')
    bidi.should contain("a·gnitset")
  end

  it "clamps a long first line, and clamps before scrubbing so the work fits the message" do
    long = Gori::CLI::Run.note_delete_confirmation_error_for_spec(1, note("x" * 200), false).not_nil!
    long.should contain("…")
    long.should_not contain("x" * 41)
  end
end

# The wiring itself, asserted over the SOURCE for the two reasons `unknown_args_sweep_spec`
# gives: `abort` calls `exit`, so the refusal is not catchable in-process, and the defect is an
# ABSENCE — the pre-#1120 bug was exactly a missing flag and a missing gate, and every example
# above stays green if the flag is dropped or the gate is moved below the write.
describe "gori run notes delete — the gate is actually wired" do
  body = notes_delete_body

  it "registers -y/--yes on the delete parser and lets it reach the gate" do
    body.should match(/p\.on\("-y", "--yes"/)
    body.should match(/\{ yes = true \}/)
    body.should contain("note_delete_confirmation_error(n, target, yes)")
  end

  it "runs the gate BEFORE the write, not after it" do
    gate = body.index("note_delete_confirmation_error").not_nil!
    save = body.index("Notes.save").not_nil!
    gate.should be < save
  end
end

module Gori::CLI::Run
  def self.note_delete_confirmation_error_for_spec(n : Int32, entry : Notes::NoteEntry,
                                                   yes : Bool) : String?
    note_delete_confirmation_error(n, entry, yes)
  end

  def self.note_created_output_for_spec(doc : Notes::Doc, new_id : Int64, format : Symbol) : String
    note_created_output(doc, new_id, format)
  end
end

# --- `notes create --format json` (#1117) ----------------------------------------------
#
# The object is the note's row from `gori run notes --format json`, built from the set read
# back after the commit, so `id` is the stable id and `index` the position the text names.
describe "gori run notes create --format json" do
  it "prints the new note's listing row, id included" do
    with_store do |store|
      Gori::Notes.create(store, "first")
      new_id = Gori::Notes.create(store, "# Login bypass\nsteps").should_not be_nil
      doc = Gori::Notes.load(store)
      created = JSON.parse(Gori::CLI::Run.note_created_output_for_spec(doc, new_id, :json))
      created["id"].as_i64.should eq(new_id)
      created["index"].as_i.should eq(2)
      created["title"].as_s.should eq("Login bypass")
      created["current"].as_bool.should be_true # `create` makes the new note the active one

      listed = JSON.parse(Gori::CLI::Output.notes_array_json(doc, with_text: false)).as_a
        .find! { |o| o["id"].as_i64 == new_id }
      created.as_h.keys.should eq(listed.as_h.keys)
      created.should eq(listed)
    end
  end

  it "keeps both text sentences unchanged" do
    doc = Gori::Notes::Doc.new(0, [Gori::Notes::NoteEntry.new(4_i64, "x")], 5_i64)
    Gori::CLI::Run.note_created_output_for_spec(doc, 4_i64, :text).should eq("Note #1 created.")
    # A peer deleted it in that instant: text falls back to the id, as it always has.
    Gori::CLI::Run.note_created_output_for_spec(doc, 9_i64, :text).should eq("Note created (id 9).")
  end
end
