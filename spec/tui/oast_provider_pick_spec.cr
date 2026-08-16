require "../spec_helper"
require "../support/memory_backend"
require "../support/overlay_harness"
require "file_utils"

include Gori::Tui

# The OAST provider bar has an "All" position, and three actions that cannot use it: `g` (get
# payload), `^R` (listen) and `^X` (stop) each act on exactly ONE provider. All three answered
# it with a status line — "select a specific provider (use ‹/› to cycle)" — which is a refusal
# that names a second step the operator cannot see from where they pressed the key: the bar is
# two rows above the callbacks table and the pick is cycled, not chosen.
#
# Two thirds of that question is not a question at all. With NO enabled provider the answer is
# "add one", not "pick one"; with exactly ONE, All *is* that provider. Only a real ambiguity —
# two or more enabled, bar on All — is worth asking, and `g`/`^R` now ask it with a card.
#
# These examples pin the decision, not the round trip: `generate_payload` on a provider with no
# listener registers over the network, so everything below stops at "which provider did it
# resolve to", which is the whole of what changed.

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

private PICK_CA_ROOT = File.tempname("gori-oast-pick-ca")
Spec.after_suite { FileUtils.rm_rf(PICK_CA_ROOT) }

# A real Session with `count` enabled project providers. Every host is 127.0.0.1 on a port
# nothing listens on: an example that reaches the register path must fail LOCALLY and at once
# rather than dial a third party from the suite.
#
# `Settings.oast_providers` is process-global and `Oast.provider_configs` merges it in, so a
# sibling spec file that populated the global library would silently change every count here.
# Snapshot and clear it for the duration.
private def with_providers(count : Int32, seed_callbacks : Bool = false, &)
  saved = Gori::Settings.oast_providers
  Gori::Settings.oast_providers = [] of Gori::Settings::OastProvider
  root = File.tempname("gori-oast-pick")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("oastpick")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(PICK_CA_ROOT), Gori::Verbs.registry, project)
  begin
    ids = (0...count).map do |i|
      session.store.insert_oast_provider("prov#{i + 1}", "interactsh", "http://127.0.0.1:#{9 + i}",
        nil, true, i)
    end
    # A lopsided callback history — 3 rows under the first provider, 1 under the second — so an
    # example can move the cursor into a range the OTHER provider's list does not have.
    if seed_callbacks
      ids.each_with_index do |pid, i|
        sid = session.store.insert_oast_session(pid, "interactsh", "http://127.0.0.1:#{9 + i}",
          "corr#{i}", "sec#{i}", nil, nil)
        (i == 0 ? 3 : 1).times do |n|
          session.store.insert_oast_callback(sid, "uid-#{i}-#{n}", "dns", nil, "203.0.113.#{n + 1}",
            "#{n}.oast.test", "query".to_slice, nil, 1_700_000_000_000_000_i64 + n)
        end
      end
    end
    host = FakeHost.new(session)
    yield OastController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
    Gori::Settings.oast_providers = saved
  end
end

private def picker_row(key : String, name : String, live : Bool = false) : OastProviderPicker::Row
  OastProviderPicker::Row.new(key: key, name: name, kind: "interactsh",
    host: "oast.test", scope: "project", live: live)
end

describe Gori::Tui::OastController do
  it "asks for a pick only when All is genuinely ambiguous" do
    with_providers(2) do |c, _|
      c.provider_pick_needed?.should be_true
      c.select_provider(c.provider_pick_rows.last.key).should be_true
      # The bar now names a provider, so the action has its answer without a card.
      c.provider_pick_needed?.should be_false
    end
    # One enabled provider: All IS that provider, so the card would have a single row and a
    # single possible outcome. Nothing to ask.
    with_providers(1) { |c, _| c.provider_pick_needed?.should be_false }
    with_providers(0) { |c, _| c.provider_pick_needed?.should be_false }
  end

  it "offers every enabled provider, keyed by the identity listeners run on" do
    with_providers(2) do |c, _|
      rows = c.provider_pick_rows
      rows.map(&.name).should eq(["prov1", "prov2"])
      rows.map(&.scope).uniq.should eq(["project"])
      rows.map(&.live).should eq([false, false])
      # A project provider's key is scope-qualified ("p_<row id>"), the same string
      # Listener#provider_key holds — not the row's position in the card.
      rows.map(&.key).should eq(rows.map(&.key).uniq)
      rows.each { |r| r.key.starts_with?("p_").should be_true }
    end
  end

  it "refuses a committed key that no longer names an enabled provider" do
    # The enabled list is re-formed on every reload/soft-sync, so a card left open across a
    # peer process disabling a provider can commit a key that is gone. It must not act, and
    # must not silently act on whatever now sits at that row.
    with_providers(2) do |c, host|
      c.select_provider("p_999999").should be_false
      host.statuses.last.should contain("gone or was disabled")
      c.provider_pick_needed?.should be_true
      # …and it says so to the CARD, not just to the status bar. `on_commit` returning false is
      # the shell's "keep the form up" signal (overlay.cr); closing here would leave the operator
      # holding a refusal with nothing left to pick from.
      c.generate_payload_with("p_999999").should be_false
      c.start_listening_with("p_999999").should be_false
    end
  end

  it "keeps the card up when ↵ lands on a row that went stale, and closes it when it doesn't" do
    # The whole round trip through the shell's dispatch: a commit closure that answers false
    # must leave the modal open. Driven through OverlayHarness, which replays that dispatch.
    with_providers(2) do |c, _|
      row = c.provider_pick_rows.first
      stale = OastProviderPicker.new([OastProviderPicker::Row.new(key: "p_999999", name: "ghost",
        kind: "interactsh", host: "oast.test", scope: "project", live: false)], "GET PAYLOAD FROM")
      stale.on_commit = -> { c.generate_payload_with("p_999999") }
      h = OverlayHarness.new(stale)
      h.press(Termisu::Input::Key::Enter).should eq(:open)

      # The same card over a row that IS still there closes — otherwise the example above would
      # pass against a picker that simply never closes.
      live = OastProviderPicker.new(c.provider_pick_rows, "GET PAYLOAD FROM")
      live.on_commit = -> { c.select_provider(row.key) }
      OverlayHarness.new(live).press(Termisu::Input::Key::Enter).should eq(:closed)
    end
  end

  it "re-clamps the callback cursor when the pick narrows the table" do
    # @payload_pick is part of filtered_callbacks' key: picking a provider narrows the list, so a
    # cursor left past the end of the shorter one leaves the table with NO highlighted row and
    # ↵ / ⇧F inert until an arrow key happens to run sync_scroll. cycle_provider has always
    # clamped; the card's commit must too. Three callbacks under prov1, one under prov2.
    with_providers(2, seed_callbacks: true) do |c, _|
      2.times { c.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Down)) }
      c.callback_selected?.should be_true # cursor on the third of prov1's rows
      c.select_provider(c.provider_pick_rows.last.key).should be_true
      # prov2 has ONE callback, so an unclamped cursor at index 2 would select nothing.
      c.callback_selected?.should be_true
    end
  end

  it "collapses All onto the only provider there is, instead of telling the operator to pick" do
    with_providers(1) do |c, host|
      c.generate_payload
      # It got as far as registering — i.e. it RESOLVED a provider — rather than bouncing off
      # the old "select a specific provider" guard.
      host.statuses.last.should contain("registering with prov1")
      host.statuses.none?(&.includes?("pick a provider")).should be_true
      c.provider_pick_needed?.should be_false
    end
  end

  it "tells an operator with no providers to add one, not to pick one" do
    with_providers(0) do |c, host|
      c.generate_payload
      host.statuses.last.should eq("no enabled provider — add one in the Providers tab")
    end
  end
end

describe Gori::Tui::OastProviderPicker do
  it "names itself and takes the title its open-site asked for" do
    p = OastProviderPicker.new([picker_row("p_1", "primary")], "GET PAYLOAD FROM")
    OverlayHarness.new(p).assert_chrome(OverlayKind::OastProviderPick, "GET PAYLOAD FROM")
    OastProviderPicker.new([picker_row("p_1", "primary")], "START LISTENING WITH")
      .title.should eq("START LISTENING WITH")
    p.hint.should eq("↑/↓ select · ↵ use this provider · esc cancel")
  end

  it "commits the SELECTED row's key, not the first one" do
    picked = nil.as(String?)
    p = OastProviderPicker.new([picker_row("p_1", "primary"), picker_row("p_2", "backup")],
      "GET PAYLOAD FROM")
    h = OverlayHarness.new(p)
    h.on_commit { picked = p.selected_row.try(&.key); true }
    h.press(Termisu::Input::Key::Down).should eq(:open)
    h.press(Termisu::Input::Key::Enter).should eq(:closed)
    h.commits.should eq(1)
    picked.should eq("p_2")
  end

  it "navigates with j/k like every sibling picker, and cancels without committing" do
    p = OastProviderPicker.new([picker_row("p_1", "primary"), picker_row("p_2", "backup")],
      "GET PAYLOAD FROM")
    h = OverlayHarness.new(p)
    h.press(Termisu::Input::Key::LowerJ, 'j')
    p.selected.should eq(1)
    h.press(Termisu::Input::Key::LowerK, 'k')
    p.selected.should eq(0)
    h.press(Termisu::Input::Key::Escape).should eq(:closed)
    h.commits.should eq(0)
  end

  it "shows the host and marks a provider already listening" do
    p = OastProviderPicker.new([picker_row("p_1", "primary", live: true)], "GET PAYLOAD FROM")
    h = OverlayHarness.new(p)
    h.rendered?("primary").should be_true
    h.rendered?("oast.test").should be_true
    h.rendered?("● live").should be_true
  end

  it "draws no card for an empty row set, so a click cannot resolve to a row" do
    # The base PickerOverlay calls overlay_box on EVERY click; content_w's max_of raises on an
    # empty array. The open-site never opens an empty card, but the guard is what makes that a
    # policy rather than a crash waiting for a provider list to empty out.
    p = OastProviderPicker.new([] of OastProviderPicker::Row, "GET PAYLOAD FROM")
    p.overlay_box(Rect.new(0, 0, 80, 24)).should be_nil
    p.empty?.should be_true
  end
end
