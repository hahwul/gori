require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/import.cr — the three palette-only import entries. Each maps to ONE
# ExecContext method; the CLI mirror of the same three sources is covered in
# spec/cli/run/import_spec.cr.
describe "Gori::Verbs.register_import" do
  r = Gori::Verbs.registry

  it "registers one Global, chordless verb per import source" do
    {"import.har" => :import_har, "import.urls" => :import_urls, "import.oas" => :import_oas}
      .each do |id, intent|
        verb = r[id]
        verb.scope.should eq(Gori::Verb::Scope::Global)
        verb.category.should eq(Gori::Verb::Category::Action)
        verb.chords.should be_empty # palette-only — importing is deliberate, never a keypress
        verb.available?(FakeExecContext.new).should be_true
        verb_intents(r, id).should eq([intent])
      end
  end

  it "keeps the three sources on separate handlers (no shared 'import' dispatcher)" do
    # A single handler taking a kind would be one closure-capture slip away from importing
    # a HAR as a URL list; three ids → three intents is the invariant.
    ctx = FakeExecContext.new
    %w[import.har import.urls import.oas].each { |id| r[id].call(ctx) }
    ctx.call_names.should eq([:import_har, :import_urls, :import_oas])
  end
end
