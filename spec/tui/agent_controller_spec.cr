require "../spec_helper"
require "../support/memory_backend"
require "../../src/gori/tui/controllers/agent_controller"
require "file_utils"

include Gori::Tui

# The Agent tab's controller (#1093). No `claude` on the machine: `session_factory` hands the
# controller a `Session` over a backend whose spawn is `/bin/cat` — it starts, it reads its
# stdin forever, and it says nothing back, which is every state these examples need.

private class AgentFakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active : Symbol = :agent

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

  def resolve_subtab_focus : Nil
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

  def active_tab : Symbol
    @active
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

private class CatBackend < Gori::Agent::Backend
  def name : String
    "fake"
  end

  def argv(config : Gori::Agent::Config, session_uuid : String, resume_uuid : String?,
           mcp_config_path : String) : Array(String)
    ["/bin/cat"]
  end

  def parse(line : String) : Array(Gori::Agent::Event::Any)
    [] of Gori::Agent::Event::Any
  end

  def user_turn(text : String) : String
    text
  end

  def permission_response(request_id : String, allow : Bool, input_json : String?,
                          message : String?) : String
    ""
  end

  def interrupt(request_id : String) : String
    ""
  end
end

# The CA is the slow part of standing a Session up and no example asserts anything about it.
private AGENT_CA_ROOT = File.tempname("gori-agent-ca")
Spec.after_suite { FileUtils.rm_rf(AGENT_CA_ROOT) }

private def with_agent_controller(&)
  root = File.tempname("gori-agent")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("agent")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(AGENT_CA_ROOT), Gori::Verbs.registry, project)
  host = AgentFakeHost.new(session)
  controller = AgentController.new(host)
  config = Gori::Agent::Config.new(db_path: project.db_path)
  controller.session_factory = -> { Gori::Agent::Session.new(CatBackend.new, config, session.store) }
  begin
    yield controller, host
  ensure
    controller.stop_all
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private def type(controller : AgentController, text : String) : Nil
  text.each_char { |c| controller.handle_body_key(key(Termisu::Input::Key::LowerA, char: c)) }
end

private def held(tool : String, id : String) : Gori::Agent::Event::PermissionAsked
  Gori::Agent::Event::PermissionAsked.new(id, tool, tool, "{}", "", "", "tu-#{id}")
end

describe Gori::Tui::AgentController do
  it "identifies itself as the Agent tab and names the focused pane as its section" do
    with_agent_controller do |controller, _host|
      controller.tab.should eq(:agent)
      controller.command_scope.should eq(Gori::Verb::Scope::Agent)
      controller.command_section.should eq(:input) # the pane the tab opens on
      controller.pane_advance(1)
      controller.command_section.should eq(:transcript)
    end
  end

  it "lands typed characters in the input pane while INS is on" do
    with_agent_controller do |controller, _host|
      controller.body_takes_text?.should be_false # READ: the digits still belong to the tab bar
      controller.editor_enter_insert.should be_true
      controller.body_takes_text?.should be_true
      controller.body_badge.should eq(:editor)

      type(controller, "list the hosts")
      controller.view.input_text.should eq("list the hosts")

      controller.handle_body_key(key(Termisu::Input::Key::Escape)).should be_true
      controller.view.insert_mode?.should be_false
      controller.body_takes_text?.should be_false
      controller.view.input_text.should eq("list the hosts") # esc leaves the draft alone
    end
  end

  it "sends the draft on READ-mode ↵, starting the session on the way" do
    with_agent_controller do |controller, _host|
      controller.editor_enter_insert
      type(controller, "hello")
      controller.editor_exit_insert

      controller.session.should be_nil # nothing spawned until there is something to say
      controller.handle_body_key(key(Termisu::Input::Key::Enter)).should be_true

      s = controller.session
      s.should_not be_nil
      s.not_nil!.running?.should be_true       # the turn is in flight
      controller.turn_running?.should be_true  # …which is what Runner#background_work? reads
      controller.view.input_text.should eq("") # the draft is spent, not left to be sent twice
      s.not_nil!.transcript.lines.first.should eq("› hello")
    end
  end

  it "refuses a second turn while one is running, and says why" do
    with_agent_controller do |controller, host|
      controller.submit("first").should be_true
      controller.submit("second").should be_false
      host.statuses.last.should contain("a turn is running")
    end
  end

  it "wraps the pane ring and refuses `i` on the read-only transcript" do
    with_agent_controller do |controller, _host|
      controller.editor_pane?.should be_true
      controller.insert_key_refusal.should be_nil

      controller.pane_advance(1).should be_true
      controller.view.focus.should eq(:transcript)
      controller.editor_pane?.should be_false
      controller.insert_key_refusal.should_not be_nil

      controller.pane_advance(1).should be_true
      controller.view.focus.should eq(:input) # wraps rather than leaving the tab
    end
  end

  it "notifies once per held permission, and once for a death" do
    with_agent_controller do |controller, host|
      host.active = :history # the operator is elsewhere — that is what a notification is for
      s = controller.ensure_session
      s.pending << held("Bash", "req-1")

      controller.drain_events
      controller.drain_events
      controller.drain_events
      notes = host.notifications.all.select(&.message.includes?("wants to run"))
      notes.size.should eq(1) # `pending` holds the request every tick; the id set is the gate
      notes.first.level.should eq(:warn)
      notes.first.source.should eq("agent")

      s.pending << held("Write", "req-2")
      controller.drain_events
      host.notifications.all.count(&.message.includes?("wants to run")).should eq(2)

      s.stop
      controller.drain_events
      controller.drain_events
      # `stop` is the operator's own doing, so it is not an exit worth a notification.
      host.notifications.all.count(&.message.starts_with?("agent exited")).should eq(0)
    end
  end

  it "shows a past conversation read-only and returns to the live one on esc" do
    with_agent_controller do |controller, host|
      store = host.session.store
      id = store.insert_agent_session("uuid-past", "claude", nil, "an older run")
      id.should be > 0
      store.insert_agent_message(id, 0, "user", "text", "what changed?")
      store.insert_agent_message(id, 1, "assistant", "text", "the login flow did")

      controller.submit("live turn").should be_true
      controller.load_history(id)
      controller.viewing_history.should eq(id)
      controller.view.transcript.not_nil!.lines.should contain("› what changed?")

      controller.handle_body_key(key(Termisu::Input::Key::Escape)).should be_true
      controller.viewing_history.should be_nil
      controller.view.transcript.not_nil!.lines.should contain("› live turn")
    end
  end
end
