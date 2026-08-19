require "../spec_helper"
require "file_utils"

include Gori::Tui

# `Store#set_fuzz_session_name` / `#set_miner_session_name` / `#set_sequencer_session_name` were
# each a narrow `UPDATE … SET name` declared `: Nil` and run through `exec_task`, whose Int64
# reply is `last_insert_rowid` — it says nothing about an UPDATE. The three `apply_rename`
# methods therefore had no answer to act on, and the failure was SILENT in the worst way: the
# view's label is set BEFORE the write, so the sub-tab chip immediately reads the new name and
# keeps reading it until the session reloads. Nothing on screen said the project had refused,
# so the operator reasonably concluded the rename worked.
#
# The store's answer is pinned in spec/store/session_rename_commit_spec.cr; these examples pin
# the surface acting on it — and, in the "commits" pair, that the refusal is CONDITIONAL. Losing
# the store's Bool makes `unless store.set_…(…)` read `unless nil`, which fires the refusal on
# every successful rename too; only the silent-on-success example catches that.
#
# Mirrors spec/tui/repeater_refusal_inline_spec.cr, whose `save_current_repeater` examples cover
# the same class on the Repeater side.

# The narrow shell facade a controller is given — its ONLY route to the shell, so stubbing it is
# stubbing the whole shell. Everything is inert except `session`, `jobs`, `notifications` and
# `status`; `status` is the surface under test.
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
    action.call # no modal in a spec: a confirmed action runs straight through
  end

  def overlay : Symbol
    :none
  end

  def active_tab : Symbol
    :fuzzer
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

# The root keypair is the one slow part of standing a Session up and no example asserts anything
# about it, so it is built once.
private RENAME_CA = File.tempname("gori-rename-ca")
Spec.after_suite { FileUtils.rm_rf(RENAME_CA) }

# A real Session with one persisted session row per workbench, seeded through the STORE and read
# back by each controller's constructor — the same path a reopened project takes, so no test-only
# tab-creation seam is needed (and each tab really carries a `db_id`, which `apply_rename`
# requires before it touches the store at all).
#
# `insert_miner_session` / `insert_sequencer_session` bind `request` to a `BLOB NOT NULL` column,
# so an EMPTY slice rolls the insert back and returns 0 → a nil `db_id` → a rename that never
# reaches the store. Real bytes, and the ids asserted below, so a seeding failure can never pass
# for the refusal under test.
private REQUEST = "GET /login?next=%2F HTTP/1.1\r\nHost: shop.test\r\n\r\n"

private def with_seeded_session(&)
  root = File.tempname("gori-rename")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("rename")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(RENAME_CA), Gori::Verbs.registry, project)
    store = session.store
    store.insert_fuzz_session("https://shop.test", REQUEST, false, nil, "{}", nil, 0).should be > 0
    store.insert_miner_session("https://shop.test", REQUEST.to_slice, false, nil, "{}", nil, 0).should be > 0
    store.insert_sequencer_session("https://shop.test", REQUEST.to_slice, false, nil, "{}", nil, 0).should be > 0
    yield FakeHost.new(session)
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "workbench sub-tab rename — a name the store refused" do
  it "FuzzerController#apply_rename says the rename was not saved" do
    with_seeded_session do |host|
      controller = FuzzerController.new(host)
      view = controller.current_view.should_not be_nil
      host.session.store.close # the batch carrying the rename rolls back

      controller.apply_rename(view, "auth sweep")

      view.name.should eq("auth sweep") # the chip already reads it — that is why this must be said
      # Asserted on the LIST, not `statuses.last`: with the guard missing the list is empty and
      # `last` raises IndexError, which reads as a broken spec instead of the absent refusal.
      host.statuses.size.should eq(1)
      host.statuses.first.should contain("rename NOT saved")
      host.statuses.first.should contain("project busy")
    end
  end

  it "MinerController#apply_rename says the rename was not saved" do
    with_seeded_session do |host|
      controller = MinerController.new(host)
      view = controller.current_view.should_not be_nil
      host.session.store.close

      controller.apply_rename(view, "login params")

      view.name.should eq("login params")
      host.statuses.size.should eq(1) # see the fuzzer example: not `last`, which raises when absent
      host.statuses.first.should contain("rename NOT saved")
    end
  end

  it "SequencerController#apply_rename says the rename was not saved" do
    with_seeded_session do |host|
      controller = SequencerController.new(host)
      view = controller.current_view.should_not be_nil
      host.session.store.close

      controller.apply_rename(view, "session token")

      view.name.should eq("session token")
      host.statuses.size.should eq(1) # see the fuzzer example: not `last`, which raises when absent
      host.statuses.first.should contain("rename NOT saved")
    end
  end

  it "stays silent on all three when the rename COMMITS, and persists it" do
    # The complement, and the one that fails if the store's Bool goes away: with the answer
    # gone the guard tests `nil`, so the refusal would fire on every rename — including these,
    # which really did land. Rename is high-frequency; success has always been silent.
    with_seeded_session do |host|
      store = host.session.store
      fuzzer = FuzzerController.new(host)
      miner = MinerController.new(host)
      sequencer = SequencerController.new(host)

      fuzzer.apply_rename(fuzzer.current_view.not_nil!, "auth sweep")
      miner.apply_rename(miner.current_view.not_nil!, "login params")
      sequencer.apply_rename(sequencer.current_view.not_nil!, "session token")

      host.statuses.should be_empty
      store.fuzz_sessions.first.name.should eq("auth sweep")
      store.miner_sessions.first.name.should eq("login params")
      store.sequencer_sessions.first.name.should eq("session token")
    end
  end
end
