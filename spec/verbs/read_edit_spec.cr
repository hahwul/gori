require "../spec_helper"
require "../support/fake_context"

# src/gori/verbs/read_edit.cr — the READ-mode select-line / clear-selection / send-to
# triple, registered once per scope. Two invariants carry the whole file:
#   1. select-line is gated on THAT tab's read mode, so 'x' never fires as an action
#      while the same pane is in edit mode (where 'x' is literal text).
#   2. send-to must live in :common on every multi-section tab. It is menu-only (no
#      keybinding fallback), and the space menu shows COMMON ∪ ONE section — tagging it
#      to a section would hide it while another pane has focus, leaving no way to invoke it.
describe "Gori::Verbs.register_read_edit" do
  r = Gori::Verbs.registry

  # {verb prefix, scope, the section select-line/clear-selection are tagged into}
  per_scope = [
    {"notes", Gori::Verb::Scope::Notes, :common},
    {"repeater", Gori::Verb::Scope::Repeater, :response},
    {"decoder", Gori::Verb::Scope::Decoder, :input},
    {"fuzzer", Gori::Verb::Scope::Fuzzer, :template},
    {"jwt", Gori::Verb::Scope::Jwt, :input},
    {"issue", Gori::Verb::Scope::IssuesDetail, :common},
    {"project", Gori::Verb::Scope::Body, :common},
    {"detail", Gori::Verb::Scope::HistoryDetail, :common},
  ]

  it "registers the triple in every read-mode scope, on the same keys" do
    per_scope.each do |(prefix, scope, section)|
      select_line = r["#{prefix}.select-line"]
      select_line.scope.should eq(scope)
      select_line.chords.should eq([Gori::Verb::Chord.new("x")])
      select_line.menu_key.should eq('x')
      select_line.section.should eq(section)

      clear = r["#{prefix}.clear-selection"]
      clear.scope.should eq(scope)
      clear.chords.should be_empty # menu-only; 'v' is the mnemonic, not a chord
      clear.menu_key.should eq('v')
      clear.section.should eq(section)

      send_to = r["#{prefix}.send-to"]
      send_to.scope.should eq(scope)
      send_to.menu_key.should eq('S') # capital dodges lowercase 's' elsewhere in the scope
      send_to.section.should eq(:common)
    end
  end

  it "dispatches select-line / clear-selection / send-to to the shared read intents" do
    per_scope.each do |(prefix, _, _)|
      verb_intents(r, "#{prefix}.select-line").should eq([:read_select_line])
      verb_intents(r, "#{prefix}.clear-selection").should eq([:read_clear_selection])
      verb_intents(r, "#{prefix}.send-to").should eq([:send_to_open])
    end
  end

  it "gates clear-selection and send-to on an ACTIVE selection, in every scope" do
    idle = FakeExecContext.new
    selecting = FakeExecContext.new
    selecting.selection_active = true

    per_scope.each do |(prefix, _, _)|
      r["#{prefix}.clear-selection"].available?(idle).should be_false
      r["#{prefix}.clear-selection"].available?(selecting).should be_true
      r["#{prefix}.send-to"].available?(idle).should be_false
      r["#{prefix}.send-to"].available?(selecting).should be_true
    end
  end

  it "gates select-line on the tab AND that tab's read mode" do
    # Notes' fake read mode is always true, so the tab alone decides there; the other
    # workbench tabs need both. A gate that dropped the read-mode half would make 'x'
    # select a line while the user is typing an 'x' into the same pane.
    notes = FakeExecContext.new
    notes.current_tab = :notes
    r["notes.select-line"].available?(notes).should be_true
    notes.current_tab = :decoder
    r["notes.select-line"].available?(notes).should be_false

    {"repeater" => :repeater, "decoder" => :decoder, "jwt" => :jwt, "fuzzer" => :fuzzer}.each do |prefix, tab|
      ctx = FakeExecContext.new
      ctx.current_tab = tab
      r["#{prefix}.select-line"].available?(ctx).should be_false # right tab, edit mode
      case prefix
      when "repeater" then ctx.repeater_read_mode = true
      when "decoder"  then ctx.decoder_read_mode = true
      when "jwt"      then ctx.jwt_read_mode = true
      when "fuzzer"   then ctx.fuzzer_read_mode = true
      end
      r["#{prefix}.select-line"].available?(ctx).should be_true
      ctx.current_tab = :issues
      r["#{prefix}.select-line"].available?(ctx).should be_false # read mode, wrong tab
    end
  end

  it "gates the issue detail's select-line on the notes pane being in read mode" do
    ctx = FakeExecContext.new
    r["issue.select-line"].available?(ctx).should be_false
    ctx.issues_notes_read_mode = true
    r["issue.select-line"].available?(ctx).should be_true
  end

  it "gates the History detail's select-line on the pane being navigable" do
    ctx = FakeExecContext.new
    r["detail.select-line"].available?(ctx).should be_false
    ctx.detail_navigable = true
    r["detail.select-line"].available?(ctx).should be_true
  end

  it "gates the Project description's select-line on its read pane, not on a tab symbol" do
    # Project shares Verb::Scope::Body with the History list, so the gate is the pane's own
    # read-mode flag — current_tab would not distinguish them.
    ctx = FakeExecContext.new
    ctx.current_tab = :history
    r["project.select-line"].available?(ctx).should be_false
    ctx.project_desc_read_mode = true
    r["project.select-line"].available?(ctx).should be_true # still :history — the pane decides
  end
end
