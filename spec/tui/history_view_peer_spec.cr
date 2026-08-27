require "../spec_helper"
require "file_utils"
require "socket"
require "../../src/gori/tui/controllers/history_controller"

include Gori::Tui

# What History does when the VIEW it is showing through disappears underneath it (#776).
#
# The chip alone is not the answer: a peer deleting the active view widens the list, and a list
# that silently got wider on a security proxy is the direction that matters. Pinned at the
# controller because that is where the before/after comparison lives — `SavedViews.active`
# cannot see it, since both `gori run views rm` and MCP `delete_view` clear the project's
# `history_view` pointer on their way out, leaving no dangling key to notice.

private class HistoryViewFakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :history

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

  def apply_project_protos(spec : String) : String
    ""
  end
end

# The CA is the slow part of standing a Session up and no example asserts anything about it.
private HISTORY_VIEW_CTRL_CA_ROOT = File.tempname("gori-history-view-ctrl-ca")
Spec.after_suite { FileUtils.rm_rf(HISTORY_VIEW_CTRL_CA_ROOT) }

private def with_history_controller(&)
  root = File.tempname("gori-history-view-ctrl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("historyviewctrl")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(HISTORY_VIEW_CTRL_CA_ROOT), Gori::Verbs.registry, project)
  begin
    host = HistoryViewFakeHost.new(session)
    yield Gori::Tui::HistoryController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "HistoryController — the active view under a peer" do
  it "picks up a view a peer created, without a restart" do
    with_history_controller do |ctrl, _host, session|
      session.store.insert_saved_view("peer view", "status:404").should_not eq(0)
      Gori::SavedViews.set_active(session.store,
        Gori::SavedViews.merged(session.store).find(&.project?))
      ctrl.on_external_change
      ctrl.view.active_view.not_nil!.name.should eq("peer view")
    end
  end

  it "says which view is gone when a peer deletes the one being shown" do
    with_history_controller do |ctrl, host, session|
      session.store.insert_saved_view("doomed", "status:404")
      view = Gori::SavedViews.merged(session.store).find(&.project?).not_nil!
      Gori::SavedViews.set_active(session.store, view)
      ctrl.on_external_change
      ctrl.view.active_view.should_not be_nil

      # What `gori run views rm` and MCP `delete_view` do: remove the row AND clear this
      # project's pointer. So there is no dangling key left — only a wider list.
      Gori::SavedViews.remove(session.store, view).should be_true
      Gori::SavedViews.set_active(session.store, nil)

      host.statuses.clear
      ctrl.on_external_change
      ctrl.view.active_view.should be_nil
      host.statuses.last.should eq("the doomed view is gone — showing All")
    end
  end

  it "says nothing when nothing was being shown through" do
    # No view active, a peer deletes some OTHER view: the list did not change, so a sentence
    # here would be noise on every unrelated tick.
    with_history_controller do |ctrl, host, session|
      session.store.insert_saved_view("unrelated", "status:404")
      ctrl.on_external_change
      host.statuses.clear
      Gori::SavedViews.remove(session.store,
        Gori::SavedViews.merged(session.store).find(&.project?).not_nil!)
      ctrl.on_external_change
      host.statuses.should be_empty
    end
  end

  it "says nothing when the view merely changed its query" do
    # An edit is not a disappearance: the chip still names the view the operator picked, and
    # the list narrowed for a reason they can read.
    with_history_controller do |ctrl, host, session|
      session.store.insert_saved_view("edited", "status:404")
      view = Gori::SavedViews.merged(session.store).find(&.project?).not_nil!
      Gori::SavedViews.set_active(session.store, view)
      ctrl.on_external_change

      host.statuses.clear
      Gori::SavedViews.update(session.store, view, "edited", "status:500").should be_true
      ctrl.on_external_change
      ctrl.view.active_view.not_nil!.query.should eq("status:500")
      host.statuses.should be_empty
    end
  end

  it "falls back to All for a pointer left dangling, and clears it" do
    # The other half: a key naming a view that is simply not there (a project switched away
    # from, a hand-edited DB). Nothing to compare against, so the pointer itself is the signal.
    with_history_controller do |ctrl, _host, session|
      session.store.set_setting(Gori::SavedViews::ACTIVE_KEY, "p_9999")
      ctrl.resolve_active_view.should eq("p_9999")
      ctrl.view.active_view.should be_nil
      # Cleared, not left to resurrect if a later view lands on the same id.
      session.store.setting(Gori::SavedViews::ACTIVE_KEY).should eq("b_all")
    end
  end
end
