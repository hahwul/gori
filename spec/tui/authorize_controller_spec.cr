require "../spec_helper"
require "file_utils"
require "../../src/gori/tui/controllers/authorize_controller"

include Gori::Tui

# `AuthorizeController#run` is where the tab decides what actually leaves the machine, and it
# is the surface with no `Plan` in front of it — `gori run authorize` and MCP `authorize_start`
# both go through `Authorize::Plan.build`, which refuses a set that cannot compare and names
# every flow it declines. The queue had neither check, so it would send.
#
# Nothing here dials: every example is one the controller refuses BEFORE spawning its run
# fiber, which is the property being pinned.

private class AuthorizeFakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :authorize

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

  def request_focus(pane : Symbol) : Nil
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
end

# The CA is the slow part of standing a Session up and no example asserts anything about it.
private AUTHORIZE_CTRL_CA_ROOT = File.tempname("gori-authorize-ctrl-ca")
Spec.after_suite { FileUtils.rm_rf(AUTHORIZE_CTRL_CA_ROOT) }

private def with_authorize_controller(&)
  root = File.tempname("gori-authorize-ctrl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("authorizectrl")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(AUTHORIZE_CTRL_CA_ROOT), Gori::Verbs.registry, project)
  begin
    host = AuthorizeFakeHost.new(session)
    yield Gori::Tui::AuthorizeController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# A captured GET. `cookie` nil = a request with no session on it at all — the public page an
# "anonymous" identity cannot change.
private def seed_capture(store : Gori::Store, target : String, cookie : String? = nil) : Int64
  head = String.build do |io|
    io << "GET " << target << " HTTP/1.1\r\nHost: acme.test\r\n"
    io << "Cookie: " << cookie << "\r\n" if cookie
    io << "\r\n"
  end
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "acme.test", port: 443,
    method: "GET", target: target, http_version: "HTTP/1.1", head: head.to_slice, body: nil))
  store.update_response(Gori::Store::CapturedResponse.new(
    flow_id: id, status: 200, head: "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n".to_slice,
    body: "ok".to_slice, reason: "OK", content_type: "text/plain", duration_us: 1_i64))
  id
end

describe Gori::Tui::AuthorizeController do
  # An identity IS a session slot, and a slot carries the extract rules whose bound values
  # belong to it. The form edits the OVERLAY half and knows nothing about the rule half, so
  # the controller has to carry it across — `gori run session edit` and MCP
  # `update_session_slot` both do. Dropping it silently re-points that slot's `$NAME` at the
  # global binding table at every send seam, with the card still showing the same identity.
  it "keeps a slot's extract-rule membership when the identity form saves an edit" do
    with_authorize_controller do |ctrl, _host, session|
      session.slots.save([
        Gori::SessionSlot.new("admin", set_headers: [{"Cookie", "session=A"}],
          baseline: true, rules: ["SESSION", "CSRF"]),
      ]).should be_true
      ctrl.identities.map(&.name).should eq(["admin"])

      # What the form builds: name + headers, no baseline flag and no rules.
      edited = Gori::Authorize::Identity.new("admin", set_headers: [{"Cookie", "session=B"}])
      ctrl.apply_identity(0, edited).should be_true

      saved = session.slots.slots
      saved.size.should eq(1)
      saved[0].set_headers.should eq([{"Cookie", "session=B"}]) # the edit landed
      saved[0].rules.should eq(["SESSION", "CSRF"])             # …and the membership survived
      saved[0].baseline?.should be_true
      # Through the LIVE registry, so the send seams see both halves.
      Gori::SessionSlots.load(session.store).slots[0].rules.should eq(["SESSION", "CSRF"])
    end
  end

  # One identity is the baseline judged against itself. `Plan` raises `NoIdentities` for it on
  # the other two surfaces; the tab used to run it and report "no identity matched the
  # baseline" — a clean bill of health for a test that compared nothing.
  it "refuses to run a set with nothing to compare against" do
    with_authorize_controller do |ctrl, host, session|
      session.slots.save([Gori::SessionSlot.new("admin",
        set_headers: [{"Cookie", "session=A"}], baseline: true)]).should be_true
      ctrl.seed_flows([seed_capture(session.store, "/admin", "session=A")]).should eq({1, 0})

      ctrl.run(:all)

      ctrl.running?.should be_false
      host.statuses.last.should contain("compares nothing")
      ctrl.view.entries.first.state.should eq(:pending)
    end
  end

  # The identity form refuses a duplicate as you type one; a set that arrived already holding
  # two reached the results table as two rows under one label. `Plan` refuses it headlessly.
  it "refuses to run a set with two identities under one name" do
    with_authorize_controller do |ctrl, host, session|
      session.slots.save([
        Gori::SessionSlot.new("admin", set_headers: [{"Cookie", "a=1"}], baseline: true),
        Gori::SessionSlot.new("Admin", set_headers: [{"Cookie", "b=2"}]),
      ]).should be_true
      ctrl.seed_flows([seed_capture(session.store, "/admin", "session=A")]).should eq({1, 0})

      ctrl.run(:all)

      ctrl.running?.should be_false
      host.statuses.last.should contain("two identities are called")
      ctrl.view.entries.first.state.should eq(:pending)
    end
  end

  # A public page and the built-in "anonymous" identity: removing headers that are not there
  # changes nothing, so every trial would ship byte-identical bytes, every response would match
  # by construction, and the row would read `⚠ 1 same` — a finding manufactured out of nothing.
  it "declines a request no identity would change, and names the reason" do
    with_authorize_controller do |ctrl, host, session|
      ctrl.seed_flows([seed_capture(session.store, "/public")]).should eq({1, 0})
      ctrl.identities.size.should eq(2) # the built-in as-captured + anonymous pair

      ctrl.run(:all)

      ctrl.running?.should be_false
      entry = ctrl.view.entries.first
      entry.state.should eq(:skipped)
      entry.skip_reason.should eq(:no_effect)
      entry.target.should be_nil
      host.statuses.last.should contain("nothing to send")
      host.statuses.last.should contain("no identity changes them")
    end
  end

  # A pre-flight refusal marks nothing — the rows stay unanswered — so an unattended replay
  # that only looks at "is there pending work?" found them again on the very next drain tick,
  # called `run`, was refused, and rewrote the status line for as long as passive stayed on.
  # The set is a property of the SET, so the autorun has to ask about it before it calls `run`.
  it "does not re-fire a refused run on every passive tick" do
    with_authorize_controller do |ctrl, host, session|
      session.slots.save([
        Gori::SessionSlot.new("admin", set_headers: [{"Cookie", "a=1"}], baseline: true),
        Gori::SessionSlot.new("Admin", set_headers: [{"Cookie", "b=2"}]),
      ]).should be_true
      ctrl.seed_flows([seed_capture(session.store, "/admin", "session=A")])
      # A scope include rule, so the readout is past the gate it names first — passive with no
      # scope replays nothing at all, and that is the answer it should give there.
      session.scope.add("include", "host", "acme.test").should be_true
      ctrl.toggle_passive # ON
      before = host.statuses.size

      5.times { ctrl.drain_events }

      ctrl.running?.should be_false
      host.statuses.size.should eq(before) # not one line per tick
      # …and the tab SAYS why, where an operator looking at it can read it.
      ctrl.view.passive_note.not_nil!.should contain("two identities are called")
    end
  end

  # …and the refusal is scoped to the identity set that produced it. Adding an identity that
  # sets a session is exactly what makes the row worth trying again, so it must come back as
  # pending rather than staying declined for the session.
  it "re-offers a declined request once the identity set can change it" do
    with_authorize_controller do |ctrl, _host, session|
      ctrl.seed_flows([seed_capture(session.store, "/public")])
      ctrl.run(:all)
      ctrl.view.auto_pending_entries.should be_empty # passive must not re-dispatch it

      ctrl.replace_identities([
        Gori::Authorize::Identity.as_captured,
        Gori::Authorize::Identity.new("low-priv", set_headers: [{"Cookie", "session=USER"}]),
      ]).should be_true

      ctrl.view.auto_pending_entries.size.should eq(1)
      ctrl.view.pending_entries.size.should eq(1)
    end
  end
end
