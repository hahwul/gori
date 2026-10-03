require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/import.cr — the palette-only import entries. Each maps to ONE ExecContext
# method; the CLI mirror of the same sources is covered in spec/cli/run/import_spec.cr.
describe "Gori::Verbs.register_import" do
  r = Gori::Verbs.registry
  # id → the dispatch it must make: the path-prompt kinds share `open_import`, each with its
  # own literal kind; cURL is a paste box with its own intent.
  verbs = {
    "import.har"      => {:open_import, ["har"]},
    "import.urls"     => {:open_import, ["urls"]},
    "import.oas"      => {:open_import, ["oas"]},
    "import.postman"  => {:open_import, ["postman"]},
    "import.insomnia" => {:open_import, ["insomnia"]},
    "import.burp"     => {:open_import, ["burp"]},
    "import.wsdl"     => {:open_import, ["wsdl"]},
    "import.curl"     => {:import_curl, [] of String},
  }

  it "registers one Global, chordless verb per import source" do
    verbs.each do |id, (intent, _)|
      verb = r[id]
      verb.scope.should eq(Gori::Verb::Scope::Global)
      verb.category.should eq(Gori::Verb::Category::Action)
      verb.chords.should be_empty # palette-only — importing is deliberate, never a keypress
      verb.available?(FakeExecContext.new).should be_true
      verb_intents(r, id).should eq([intent])
    end
  end

  it "keeps every source on its own handler, each naming its own kind" do
    # One handler per id, each with a LITERAL kind: a single handler fed the kind from a loop
    # would be one closure-capture slip away from importing a HAR as a URL list.
    ctx = FakeExecContext.new
    verbs.each_key { |id| r[id].call(ctx) }
    ctx.calls.map { |c| {c.name, c.args} }.should eq(verbs.values)
  end

  it "gives every import kind a way in" do
    # The palette and the parser table live in different files; this is what catches a
    # format that was implemented but never registered (or vice versa).
    Gori::Import::LABELS.each_key { |kind| verbs.has_key?("import.#{kind}").should be_true }
    verbs.size.should eq(Gori::Import::LABELS.size)
  end
end
