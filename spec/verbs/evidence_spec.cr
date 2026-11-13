require "../spec_helper"

# src/gori/verbs/evidence.cr — the Evidence archive's verbs.
describe "Gori::Verbs.register_evidence" do
  r = Gori::Verbs.registry

  # The cross-tool send reads the same on every tab; the description still says it copies
  # the frozen request, and the old title's word still finds the row in the palette.
  it "titles the Repeater send as every other tab does, and still answers `duplicate`" do
    v = r["evidence.repeater"]
    v.title.should eq("Send to Repeater")
    v.description.should contain("frozen request")
    Gori::Verb::Registry.score(v, "send to repeater").should_not be_nil
    Gori::Verb::Registry.score(v, "duplicate").should_not be_nil
  end
end
