require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/import.cr — the palette-only import entries. Each maps to ONE ExecContext
# method; the CLI mirror of the same sources is covered in spec/cli/run/import_spec.cr.
describe "Gori::Verbs.register_import" do
  r = Gori::Verbs.registry
  verbs = {
    "import.har"      => :import_har,
    "import.urls"     => :import_urls,
    "import.oas"      => :import_oas,
    "import.postman"  => :import_postman,
    "import.insomnia" => :import_insomnia,
    "import.burp"     => :import_burp,
  }

  it "registers one Global, chordless verb per import source" do
    verbs.each do |id, intent|
      verb = r[id]
      verb.scope.should eq(Gori::Verb::Scope::Global)
      verb.category.should eq(Gori::Verb::Category::Action)
      verb.chords.should be_empty # palette-only — importing is deliberate, never a keypress
      verb.available?(FakeExecContext.new).should be_true
      verb_intents(r, id).should eq([intent])
    end
  end

  it "keeps every source on its own handler (no shared 'import' dispatcher)" do
    # A single handler taking a kind would be one closure-capture slip away from importing
    # a HAR as a URL list; one id → one intent is the invariant, however many sources exist.
    ctx = FakeExecContext.new
    verbs.each_key { |id| r[id].call(ctx) }
    ctx.call_names.should eq(verbs.values)
  end

  it "gives every import kind a way in" do
    # The palette and the parser table live in different files; this is what catches a
    # format that was implemented but never registered (or vice versa).
    Gori::Import::LABELS.each_key { |kind| verbs.has_key?("import.#{kind}").should be_true }
    verbs.size.should eq(Gori::Import::LABELS.size)
  end
end
