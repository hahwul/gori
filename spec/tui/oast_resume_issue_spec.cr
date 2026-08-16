require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# Two holes in the OAST tab, both of them in the path from "a callback landed" back to
# "therefore this is a finding".
#
# RESUME. `oast_sessions` has always stored the correlation id, the poll secret and the
# interactsh RSA private key — everything needed to keep a registration alive across a
# restart — and the controller read those rows for exactly ONE thing: the provider label to
# print in the table. `^R` always registered afresh, and `^X` (and `stop_all`, which runs on
# quit and on leaving a project) deregistered. So every payload the operator had planted died
# with the process, in the one workbench whose findings arrive hours after the request that
# caused them. These examples pin the new contract: stopping keeps the session, resuming
# reuses its row, and a resumed session never forks its callback history into a second one.
#
# ISSUES. The guide has linked "promote a confirmed callback into an Issue" since the tab
# shipped; nothing implemented it. `issue.create` resolves through History's selected FLOW ids
# and a callback is not a flow, so the only way to record the strongest evidence gori produces
# was to retype it. `callback_issue_draft` is that link.

private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String

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

  def active_tab : Symbol
    :oast
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

# A Provider that never touches a socket. `poll` returns nothing, so the Poller the resume
# path starts spins harmlessly instead of dialling a host that does not exist.
private class SilentProvider < Gori::Oast::Provider
  def initialize(host : String = "https://oast.test")
    super(Gori::Oast::ProviderKind::Interactsh, host, nil)
  end

  def register(http : Gori::Oast::Http) : Gori::Oast::Session
    raise "not used"
  end

  def generate_payload(session : Gori::Oast::Session) : String
    "#{session.correlation_id}abcdefghijklm.oast.test"
  end

  def poll(http : Gori::Oast::Http, session : Gori::Oast::Session) : Array(Gori::Oast::Interaction)
    [] of Gori::Oast::Interaction
  end
end

private RESUME_CA_ROOT = File.tempname("gori-oast-resume-ca")
Spec.after_suite { FileUtils.rm_rf(RESUME_CA_ROOT) }

# A real Session with ONE project-scoped provider and ONE persisted OAST session against it —
# the state a reopened project is actually in, which is the state resume exists to serve.
private def with_oast_controller(&)
  root = File.tempname("gori-oast-resume")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("oastresume")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(RESUME_CA_ROOT), Gori::Verbs.registry, project)
  begin
    pid = session.store.insert_oast_provider("House interactsh", "interactsh",
      "https://oast.test", nil, true, 0)
    sid = session.store.insert_oast_session(pid, "interactsh", "https://oast.test",
      "c0rr3lat10n", "s3cret", nil, nil)
    host = FakeHost.new(session)
    yield OastController.new(host), host, session, sid, pid
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def interaction(n : Int32, raw : String? = nil) : Gori::Oast::Interaction
  Gori::Oast::Interaction.new(
    unique_id: "uid-#{n}",
    protocol: "dns",
    method: "A",
    source_ip: "203.0.113.#{n}",
    full_id: "c0rr3lat10n#{n}.oast.test",
    raw_request: raw || ";; QUESTION SECTION:\n;c0rr3lat10n#{n}.oast.test. IN A",
    raw_response: ";; ANSWER SECTION:\nc0rr3lat10n#{n}.oast.test. 60 IN A 203.0.113.1",
    at: Time.utc(2026, 8, 6, 12, 0, n))
end

private def deliver(controller : OastController, sid : Int64, i : Gori::Oast::Interaction) : Nil
  controller.@oast_events.send(Gori::Oast::CallbackEvent.new(sid, i))
  controller.drain_events
end

# The registration result a resume produces, pushed through the SAME channel a fresh register
# uses — `apply_registration` is the only place that decides whether a row is inserted, and
# reaching it this way is reaching it the way the resume fiber does.
private def resumed_reg(controller : OastController, session : Gori::Oast::Session,
                        key : String) : OastController::RegOk
  OastController::RegOk.new(session, SilentProvider.new, key, nil, "House interactsh", false,
    resumed: true)
end

describe "Gori::Tui::OastController — resuming a persisted listener" do
  it "reuses the session's own row instead of forking a second one" do
    with_oast_controller do |controller, host, session, sid, pid|
      # A callback already on file against this session — the history a resume must land back
      # on top of, rather than beside.
      deliver(controller, sid, interaction(1))
      session.store.oast_callbacks_since(0_i64).size.should eq(1)

      engine_session = Gori::Oast::Session.new(sid, Gori::Oast::ProviderKind::Interactsh,
        "https://oast.test", "c0rr3lat10n", "s3cret", registered: true)
      controller.@reg_events.send(resumed_reg(controller, engine_session, "p_#{pid}"))
      controller.drain_events

      # The defect this guards: an insert here would file every future interaction under a new
      # session id, leaving the row that owns the PLANTED payloads frozen at its old count.
      session.store.oast_sessions.size.should eq(1)
      session.store.oast_sessions.first.id.should eq(sid)
      controller.@listeners.map(&.session.id).should eq([sid])
      host.statuses.last.should contain("resumed")
      # It names the history, because that history is the reason to resume this one and not
      # start a fresh listener.
      host.statuses.last.should contain("1 callbacks so far")

      controller.stop_all
    end
  end

  it "still inserts a row for a genuinely fresh registration" do
    with_oast_controller do |controller, _host, session, _sid, pid|
      engine_session = Gori::Oast::Session.new(0_i64, Gori::Oast::ProviderKind::Interactsh,
        "https://oast.test", "fresh-corr", "fresh-sec", registered: true)
      controller.@reg_events.send(OastController::RegOk.new(engine_session, SilentProvider.new,
        "p_#{pid}", pid, "House interactsh", false))
      controller.drain_events

      session.store.oast_sessions.size.should eq(2)
      session.store.oast_sessions.map(&.correlation_id).should contain("fresh-corr")

      controller.stop_all
    end
  end

  it "refuses a second listener on a provider that is already listening" do
    with_oast_controller do |controller, host, session, sid, pid|
      engine_session = Gori::Oast::Session.new(sid, Gori::Oast::ProviderKind::Interactsh,
        "https://oast.test", "c0rr3lat10n", "s3cret", registered: true)
      controller.@reg_events.send(resumed_reg(controller, engine_session, "p_#{pid}"))
      controller.drain_events

      # A second session of the SAME provider. `listener_for` keys on the provider, so two
      # listeners under one key would make ^X, `g` and the job note each pick one at random.
      other = session.store.insert_oast_session(pid, "interactsh", "https://oast.test",
        "0th3rc0rr", "0th3rsec", nil, nil)
      controller.resume_session(other)
      host.statuses.last.should contain("already listening")
      controller.@listeners.size.should eq(1)

      controller.stop_all
    end
  end

  it "refuses to resume a session that is gone, or one naming an unknown provider type" do
    with_oast_controller do |controller, host, session, _sid, pid|
      controller.resume_session(9999_i64)
      host.statuses.last.should contain("gone")

      bogus = session.store.insert_oast_session(pid, "not-a-provider", "https://oast.test",
        "x", "y", nil, nil)
      controller.resume_session(bogus)
      host.statuses.last.should contain("unknown provider type")
      controller.@listeners.should be_empty
    end
  end

  # A GLOBAL provider has no row in the project DB, so its sessions were written with a NULL
  # provider_id — by design. Giving up on nil would leave every session of anyone who
  # configured interactsh once and reuses it across projects permanently unresumable, which is
  # the ordinary setup, not the edge case.
  it "re-resolves a global provider's session by kind and endpoint, not by row id" do
    Gori::Settings.oast_providers = [] of Gori::Settings::OastProvider
    Gori::Settings.add_oast_provider("Shared interactsh", "interactsh", "oast.global", nil)
    begin
      with_oast_controller do |controller, host, session, _sid, _pid|
        # provider_id NULL, and the server_url in its normalised form — what register wrote.
        global = session.store.insert_oast_session(nil, "interactsh", "https://oast.global",
          "gl0balc0rr", "s3c", nil, nil)
        controller.reload

        controller.resume_session(global)
        # It got as far as the network round trip (which the status names), rather than
        # bouncing off "provider is gone".
        host.statuses.last.should contain("resuming Shared interactsh")

        # …and the row is offered under that provider's NAME, not a bare kind label.
        controller.session_rows.find(&.session_id.==(global)).not_nil!
          .provider.should eq("Shared interactsh")
      end
    ensure
      Gori::Settings.oast_providers = [] of Gori::Settings::OastProvider
    end
  end

  # The discard path deregisters, which for interactsh tells the server to forget the
  # correlation id. Doing that to a RESUMED session — one with a row, callbacks and payloads
  # planted right now — would throw away exactly what the operator asked to get back.
  it "drops a resume whose provider vanished mid-flight without releasing its server state" do
    with_oast_controller do |controller, host, session, sid, pid|
      session.store.delete_oast_provider(pid)
      controller.reload

      engine_session = Gori::Oast::Session.new(sid, Gori::Oast::ProviderKind::Interactsh,
        "https://oast.test", "c0rr3lat10n", "s3cret", registered: true)
      controller.@reg_events.send(resumed_reg(controller, engine_session, "p_#{pid}"))
      controller.drain_events

      host.statuses.last.should contain("resume")
      host.statuses.last.should contain("discarded")
      controller.@listeners.should be_empty
      # The row survives, so re-adding the provider makes it resumable again.
      session.store.oast_sessions.map(&.id).should contain(sid)
    end
  end

  it "says what to do when the session's provider really is gone" do
    with_oast_controller do |controller, host, session, _sid, _pid|
      orphan = session.store.insert_oast_session(nil, "interactsh", "https://nowhere.test",
        "0rphan", "s3c", nil, nil)
      controller.reload

      controller.resume_session(orphan)
      # A listener is addressed BY ITS PROVIDER everywhere else in this tab, so resuming one
      # without a provider would make a poller the operator can see and never stop with ^X.
      host.statuses.last.should contain("provider is gone")
      host.statuses.last.should contain("https://nowhere.test")
      controller.@listeners.should be_empty
    end
  end

  it "lists persisted sessions newest first, with their hit counts and payload host" do
    with_oast_controller do |controller, _host, session, sid, pid|
      deliver(controller, sid, interaction(1))
      deliver(controller, sid, interaction(2))
      newer = session.store.insert_oast_session(pid, "interactsh", "https://oast.live",
        "n3wer", "s3c", nil, nil)
      controller.reload

      rows = controller.session_rows
      rows.map(&.session_id).should eq([newer, sid]) # a session list reads as a stack
      rows.last.hits.should eq(2)
      rows.last.provider.should eq("House interactsh")
      rows.last.payload_host.should eq("oast.test")
      rows.first.payload_host.should eq("oast.live")
      rows.each(&.live.should(be_false))
    end
  end

  it "marks the session that is already polling, rather than hiding it" do
    with_oast_controller do |controller, _host, _session, sid, pid|
      engine_session = Gori::Oast::Session.new(sid, Gori::Oast::ProviderKind::Interactsh,
        "https://oast.test", "c0rr3lat10n", "s3cret", registered: true)
      controller.@reg_events.send(resumed_reg(controller, engine_session, "p_#{pid}"))
      controller.drain_events

      # Omitting it would read as "that session is gone" on the one card whose job is to say
      # which sessions still exist.
      row = controller.session_rows.find(&.session_id.==(sid)).not_nil!
      row.live.should be_true

      controller.stop_all
    end
  end

  it "releases the server state without touching the callbacks it collected" do
    with_oast_controller do |controller, host, session, sid, _pid|
      deliver(controller, sid, interaction(1))
      deliver(controller, sid, interaction(2))

      controller.release_session(sid)

      # Release ends the LISTENER, not the evidence. The row and every callback under it stay:
      # a finished engagement is exactly when the findings matter most.
      session.store.oast_sessions.map(&.id).should contain(sid)
      session.store.oast_callbacks_since(0_i64).size.should eq(2)
      host.statuses.last.should contain("callbacks stay")
    end
  end
end

describe "Gori::Tui::OastSessionPicker" do
  rows = [
    OastSessionPicker::Row.new(2_i64, "House interactsh", "oast.test",
      Time.local - 3.hours, 4, true),
    OastSessionPicker::Row.new(1_i64, "Public webhook.site", "webhook.site",
      Time.local - 2.days, 1, false),
  ]

  it "shows each session by provider, payload host, hit count, age and live state" do
    backend = MemoryBackend.new(100, 12)
    OastSessionPicker.new(rows).render(Screen.new(backend), Rect.new(0, 0, 100, 12))
    pane = (0...12).map { |y| backend.row(y) }.join("\n")

    pane.should contain("RESUME LISTENER")
    pane.should contain("House interactsh")
    pane.should contain("oast.test")
    pane.should contain("4 hits · 3h · ● live") # the row that needs no resume says so
    pane.should contain("1 hit · 2d")           # singular, because "1 hits" reads as a bug
    pane.should_not contain("1 hit · 2d · ● live")
  end

  it "releases without closing, so a housekeeping pass is one visit" do
    released = [] of Int64
    picker = OastSessionPicker.new(rows.dup)
    picker.on_release = ->(id : Int64) { released << id; nil }

    picker.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::LowerX, char: 'x')).should eq(:stay)
    released.should eq([2_i64])
    # The row stays listed — a released session is still resumable (interactsh rebuilds it from
    # the same key), so dropping it would overstate what releasing does.
    picker.entry_count.should eq(2)
    picker.selected_row.not_nil!.live.should be_false
  end

  it "resumes on ↵ and cancels on esc" do
    picker = OastSessionPicker.new(rows.dup)
    picker.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Down)).should eq(:stay)
    picker.selected_row.not_nil!.session_id.should eq(1_i64)
    picker.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Enter)).should eq(:commit)
    picker.handle_key(Termisu::Event::Key.new(Termisu::Input::Key::Escape)).should eq(:cancel)
  end

  # PickerOverlay#handle_click calls overlay_box for EVERY click, and content_w's max_of raises
  # on an empty list — the difference between "a click outside dismisses" and an exception out
  # of the event loop.
  it "has no box when there is nothing to resume" do
    OastSessionPicker.new([] of OastSessionPicker::Row).overlay_box(Rect.new(0, 0, 100, 12)).should be_nil
  end
end

describe "Gori::Tui::OastController — promoting a callback to an Issue" do
  it "prefills the title and carries the raw interaction in as evidence" do
    with_oast_controller do |controller, _host, _session, sid, _pid|
      deliver(controller, sid, interaction(7))

      controller.callback_selected?.should be_true
      draft = controller.callback_issue_draft.not_nil!
      draft.title.should eq("OAST DNS callback from 203.0.113.7")
      # NIL on purpose: an OAST interaction's source and destination are neither of them the
      # target host every other issue's `host` column means, and filing one there would give
      # the Issues tab's `host:` filter a second meaning.
      draft.host.should be_nil

      draft.notes.should contain("protocol:    dns (A)")
      draft.notes.should contain("source:      203.0.113.7")
      draft.notes.should contain("destination: c0rr3lat10n7.oast.test")
      draft.notes.should contain("provider:    House interactsh")
      draft.notes.should contain("--- raw request ---")
      draft.notes.should contain(";; QUESTION SECTION:")
      draft.notes.should contain("--- raw response ---")
    end
  end

  it "falls back to the destination when the provider reports no source IP" do
    with_oast_controller do |controller, _host, _session, sid, _pid|
      anon = Gori::Oast::Interaction.new("uid-anon", "http", "GET", nil,
        "https://webhook.site/abc/def", "GET /def HTTP/1.1", nil, Time.utc)
      deliver(controller, sid, anon)

      # webhook.site and postbin both can omit it; "OAST HTTP callback from " would be worse
      # than useless as an issue title.
      controller.callback_issue_draft.not_nil!.title
        .should eq("OAST HTTP callback on https://webhook.site/abc/def")
    end
  end

  it "truncates oversized evidence and says that it did" do
    with_oast_controller do |controller, _host, _session, sid, _pid|
      huge = "A" * (OastController::EVIDENCE_CAP * 2)
      deliver(controller, sid, interaction(3, raw: huge))

      notes = controller.callback_issue_draft.not_nil!.notes
      # Evidence silently cut is evidence you can draw the wrong conclusion from.
      notes.should contain("truncated at #{OastController::EVIDENCE_CAP} bytes")
      notes.should contain("full callback kept in the OAST tab")
      notes.bytesize.should be < (OastController::EVIDENCE_CAP * 2)
    end
  end

  it "has nothing to file when no callback is selected" do
    with_oast_controller do |controller, _host, _session, _sid, _pid|
      controller.callback_selected?.should be_false
      controller.callback_issue_draft.should be_nil
    end
  end
end
