require "../spec_helper"
require "file_utils"
require "../support/fake_context"
require "../../src/gori/tui/controllers/diff_controller"

include Gori::Tui

# The retest diff's EXIT (#845). The report finds the right things; until this, the only way
# out of the tab was the Comparer, so the deliverable a retest exists to produce had to be
# retyped somewhere else.
#
# The two facts these examples pin are the ones a pure `Diff::Record` spec cannot reach,
# because both are decisions about a STORE:
#
#   * which side's capture can be linked. `entity_links.ref_id` is a bare rowid with no
#     project column, so only the slot naming the OPEN project has a flow id that means
#     anything here — and after `s` that is A, not B.
#   * that a capture pruned between the run and the keystroke is dropped rather than filed
#     as a link row pointing at a rowid SQLite will later hand to an unrelated flow.

private class DiffFakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :target

  def initialize(@session : Gori::Session)
    @jobs = Gori::Tui::Jobs.new
    @notifications = Gori::Tui::Notifications.new
  end

  def session : Gori::Session
    @session
  end

  def jobs : Gori::Tui::Jobs
    @jobs
  end

  def notifications : Gori::Tui::Notifications
    @notifications
  end

  def status(message : String) : Nil
    @statuses << message
  end

  def request_overlay(kind : Symbol) : Nil
  end

  getter focus_requests = [] of Symbol

  def request_focus(pane : Symbol) : Nil
    @focus_requests << pane
  end

  def focus_body : Nil
  end

  def switch_tab(tab : Symbol) : Nil
  end

  def goto_tab(tab : Symbol) : Nil
  end

  def open_palette : Nil
  end

  def open_help_query(surface : Symbol) : Nil
  end

  def open_space_menu : Nil
  end

  def open_fuzz_set_editor(edit_index : Int32?) : Nil
  end

  def open_fuzz_advanced_editor : Nil
  end

  def open_authorize_identities : Nil
  end

  def reconfigure_sequence : Nil
  end

  def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
  end

  def open_custom_rule_editor(rule : Gori::Probe::CustomRule?) : Nil
  end

  def open_rewriter_preset_picker : Nil
  end

  def open_rewriter_rule_editor(rule : Gori::Store::MatchRule?) : Nil
  end

  def open_colormarker_rule_editor(rule : Gori::Store::ColorRule?) : Nil
  end

  def open_colormarker_color_editor(color : Gori::Settings::ColormarkerColor?) : Nil
  end

  def open_extract_rule_editor(rule : Gori::Store::ExtractRule?) : Nil
  end

  def open_chain_save : Nil
  end

  def open_chain_load : Nil
  end

  def open_oast_provider_editor(provider : Gori::Oast::ProviderConfig?) : Nil
  end

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    action.call
  end

  def overlay : Symbol
    :none
  end

  def focus : Symbol
    :body
  end

  def reveal? : Bool
    false
  end

  def toggle_reveal : Nil
  end

  def pretty? : Bool
    false
  end

  def toggle_pretty : Nil
  end

  def toggle_scope_lens : Nil
  end

  def toggle_sandbox : Nil
  end

  def apply_project_network(bind_host : String, bind_port : Int32, upstream : String,
                            connect_secs : Int32, io_secs : Int32, capture_mib : Int32) : String
    ""
  end

  def apply_project_protos(spec : String) : String
    ""
  end
end

# The CA is the slow part of standing a Session up and no example asserts anything about it.
private DIFF_CTRL_CA_ROOT = File.tempname("gori-diff-ctrl-ca")
Spec.after_suite { FileUtils.rm_rf(DIFF_CTRL_CA_ROOT) }

private def diff_ctrl_flow(store : Gori::Store, target : String, *, status : Int32 = 200) : Int64
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_000_000_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1",
    head: "GET #{target} HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice,
    source: Gori::FlowSource::Kind::Proxy))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: status, content_type: "application/json",
    head: "HTTP/1.1 #{status} OK\r\n\r\n".to_slice, body: "xxxx".to_slice, body_size: 4_i64))
  id
end

# An open session on project "now", plus a SECOND project on disk playing the baseline. The
# controller is handed both, exactly as `a`/`b` would.
private def with_diff_controller(&)
  root = File.tempname("gori-diff-ctrl")
  Dir.mkdir_p(root)
  registry = Gori::ProjectRegistry.new(root)
  now = registry.create("now")
  before = registry.create("before")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(DIFF_CTRL_CA_ROOT), Gori::Verbs.registry, now)
  begin
    host = DiffFakeHost.new(session)
    yield Gori::Tui::DiffController.new(host), host, session, before
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# Seed the baseline project's own database and close it again — the controller reopens it
# read-only for the length of one comparison, exactly as it does for a real project.
private def seed_baseline(project : Gori::Project, &) : Nil
  store = Gori::Store.open(project.db_path, background_index: false)
  begin
    yield store
  ensure
    store.close
  end
end

describe "Gori::Tui::DiffController record exit" do
  it "links the capture on the side that IS the open project, and names the other" do
    with_diff_controller do |ctrl, _host, session, before|
      seed_baseline(before) { |s| diff_ctrl_flow(s, "/orders") }
      live = diff_ctrl_flow(session.store, "/orders", status: 403)
      ctrl.set_slot(:a, before)
      ctrl.set_slot(:b, session.project)
      ctrl.view.rows.should_not be_empty

      recorded = ctrl.selected_record.should_not be_nil
      draft, flow_id = recorded
      flow_id.should eq(live) # B is the open project — its flow is the linkable one
      draft.body.should contain("now flow ##{live} — linked to this record")
      # The baseline's capture is NOT dropped and NOT linked: it is named, with the target
      # it was captured on, so the reader can still reach it by opening that project.
      draft.body.should contain("entity links do not cross projects")
      # …and WHICH "before": two engagements against one target are routinely named alike,
      # so the record names both databases as well as both projects.
      draft.body.should contain(before.db_path)
      draft.body.should contain(session.project.db_path)
    end
  end

  it "follows the open project to slot A after a swap" do
    with_diff_controller do |ctrl, _host, session, before|
      seed_baseline(before) { |s| diff_ctrl_flow(s, "/orders") }
      live = diff_ctrl_flow(session.store, "/orders", status: 403)
      ctrl.set_slot(:a, before)
      ctrl.set_slot(:b, session.project)
      ctrl.swap
      recorded = ctrl.selected_record.should_not be_nil
      _, flow_id = recorded
      flow_id.should eq(live)
    end
  end

  it "refuses to link a capture that was pruned between the run and the keystroke" do
    # The report is a SNAPSHOT taken at `r`. A link row filed against a deleted rowid is
    # worse than no link: SQLite hands that id to some later flow, and the issue silently
    # starts pointing at evidence nobody attached.
    with_diff_controller do |ctrl, _host, session, before|
      seed_baseline(before) { |s| diff_ctrl_flow(s, "/orders") }
      live = diff_ctrl_flow(session.store, "/orders", status: 403)
      ctrl.set_slot(:a, before)
      ctrl.set_slot(:b, session.project)
      session.store.delete_flow(live)

      recorded = ctrl.selected_record.should_not be_nil
      draft, flow_id = recorded
      flow_id.should be_nil
      draft.body.should contain("no longer captured in this project")
    end
  end

  it "answers nil rather than an unanchored record when no row is selected" do
    with_diff_controller do |ctrl, _host, _session, _before|
      ctrl.selected_record.should be_nil
    end
  end

  it "carries the coverage-gap wording into a record built from a real read" do
    # End to end: an endpoint the baseline captured and the open project never requested.
    with_diff_controller do |ctrl, _host, session, before|
      seed_baseline(before) { |s| diff_ctrl_flow(s, "/legacy") }
      diff_ctrl_flow(session.store, "/other")
      ctrl.set_slot(:a, before)
      ctrl.set_slot(:b, session.project)
      row = ctrl.view.rows.find { |r| r.key.path == "/legacy" }.should_not be_nil
      row.verdict.removed?.should be_true
      ctrl.view.select_index(ctrl.view.rows.index!(row))

      draft, flow_id = ctrl.selected_record.should_not be_nil
      flow_id.should be_nil # nothing on the open project's side to link
      draft.severity.should eq(Gori::Store::Severity::Info)
      draft.title.should contain("coverage gap, not a removal")
      draft.body.should contain("not evidence the endpoint was removed")
    end
  end
end

describe "Gori::Verbs diff record verbs" do
  it "binds the app-wide file gesture, gated on a row being under the cursor" do
    r = Gori::Verbs.registry
    issue = r["diff.issue"]
    issue.scope.should eq(Gori::Verb::Scope::Diff)
    issue.chords.map(&.label).should eq(r["issue.create"].chords.map(&.label))
    ctx = FakeExecContext.new
    ctx.diff_rows_shown = false
    issue.available?(ctx).should be_false
    ctx.diff_rows_shown = true
    issue.available?(ctx).should be_true
    issue.call(ctx)
    ctx.call_names.should eq([:diff_issue])
  end

  it "gives the note a bare key — the lighter exit is the one a retest leans on" do
    r = Gori::Verbs.registry
    note = r["diff.note"]
    note.chords.map(&.key).should eq(["n"])
    ctx = FakeExecContext.new
    ctx.diff_rows_shown = true
    note.call(ctx)
    ctx.call_names.should eq([:diff_note])
  end

  it "keeps every Diff space-menu key distinct — 'a' is already the baseline picker" do
    # `Registry#validate_menu_keys!` raises at BOOT on a collision; this names the pair that
    # forced `diff.issue` off the 'a' its siblings on other tabs use.
    Gori::Verbs.registry.validate_menu_keys!
    r = Gori::Verbs.registry
    r["diff.issue"].menu_key.should eq('i')
    r["diff.pick-a"].menu_key.should eq('a')
  end
end
