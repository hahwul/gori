require "./spec_helper"

# Builds a fake editor block that overwrites the temp file with `new_content`
# (when given) and returns `status`. nil status simulates "did not run".
private def fake_editor(new_content : String?, success : Bool = true)
  ->(_program : String, args : Array(String)) do
    path = args.last
    File.write(path, new_content) if new_content
    success ? run_ok : run_fail
  end
end

private def run_ok : Process::Status
  Process::Status[0]
end

private def run_fail : Process::Status
  Process::Status[1]
end

describe Gori::ExternalEditor do
  it "returns Changed with the edited text on a successful edit" do
    r = Gori::ExternalEditor.edit("hello", :notes, &fake_editor("hello world"))
    r.outcome.should eq(Gori::ExternalEditor::Outcome::Changed)
    r.text.should eq("hello world")
  end

  it "strips exactly one trailing newline the editor adds" do
    r = Gori::ExternalEditor.edit("body", :request, &fake_editor("edited\n"))
    r.outcome.should eq(Gori::ExternalEditor::Outcome::Changed)
    r.text.should eq("edited") # not "edited\n" (which would add a spurious empty line)
  end

  # The unconditional strip silently deleted two bytes off a request body that genuinely ends
  # in CRLF — observed as `Content-Length: 34` shipped over 32 bytes, which is the desync a
  # smuggling test is trying to cause deliberately, arriving by accident. Byte-exactness on
  # operator input is a P0 invariant, so the strip is conditional on a WIRE kind.
  it "keeps a request body's own trailing CRLF" do
    body = "POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\nab\r\n"
    r = Gori::ExternalEditor.edit(body, :request, &fake_editor(body))
    r.outcome.should eq(Gori::ExternalEditor::Outcome::Unchanged)

    edited = "POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\ncd\r\n"
    r2 = Gori::ExternalEditor.edit(body, :request, &fake_editor(edited))
    r2.text.should eq(edited) # all 4 body bytes survive, CRLF included
  end

  it "keeps an intercepted message's own trailing newline too" do
    text = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi\n"
    r = Gori::ExternalEditor.edit(text, :intercept, &fake_editor(text))
    r.outcome.should eq(Gori::ExternalEditor::Outcome::Unchanged)
  end

  # The mirror-image defect the conditional guards against: with no trailing newline of its
  # own, the editor's ensure-newline-at-EOF must still be undone or the request GAINS a byte.
  it "still removes the editor's added newline when the request had none" do
    r = Gori::ExternalEditor.edit("GET / HTTP/1.1\r\n\r\n---", :request,
      &fake_editor("GET / HTTP/1.1\r\n\r\n===\n"))
    r.text.should eq("GET / HTTP/1.1\r\n\r\n===")
  end

  # Prose is the other half of the split: a note's trailing newline is the editor's
  # convention, and keeping it would show a spurious empty last line in the TextArea.
  it "keeps stripping unconditionally for notes and the project description" do
    Gori::ExternalEditor.edit("a\n", :notes, &fake_editor("b\n")).text.should eq("b")
    Gori::ExternalEditor.edit("a\n", :desc, &fake_editor("b\n")).text.should eq("b")
  end

  it "treats identical content as Unchanged (no spurious dirty)" do
    r = Gori::ExternalEditor.edit("same", :desc, &fake_editor("same"))
    r.outcome.should eq(Gori::ExternalEditor::Outcome::Unchanged)
    r.text.should be_nil
  end

  it "reports Failed on a nonzero editor exit (and does not return text)" do
    r = Gori::ExternalEditor.edit("orig", :notes, &fake_editor("ignored", success: false))
    r.outcome.should eq(Gori::ExternalEditor::Outcome::Failed)
    r.text.should be_nil
  end

  it "reports Failed when the editor never ran (nil status)" do
    r = Gori::ExternalEditor.edit("orig", :notes) { |_p, _a| nil }
    r.outcome.should eq(Gori::ExternalEditor::Outcome::Failed)
  end

  it "cleans up the temp file" do
    seen = nil.as(String?)
    Gori::ExternalEditor.edit("x", :notes) do |_p, args|
      seen = args.last
      run_ok
    end
    File.exists?(seen.not_nil!).should be_false
  end

  it "uses a syntax-hint suffix per field kind" do
    Gori::ExternalEditor.suffix_for(:request).should eq(".http")
    Gori::ExternalEditor.suffix_for(:notes).should eq(".md")
    Gori::ExternalEditor.suffix_for(:desc).should eq(".md")
    Gori::ExternalEditor.suffix_for(:intercept).should eq(".http")
  end
end
