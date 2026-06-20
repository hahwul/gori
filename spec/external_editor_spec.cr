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

# Real Process::Status via trivial shells (true/false), since it has no public ctor.
private def run_ok : Process::Status
  Process.run("true")
end

private def run_fail : Process::Status
  Process.run("false")
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
