require "../spec_helper"
require "file_utils"

# `y` with NOTHING selected copies the WHOLE focused pane. That is the rule `Runner#read_copy`
# states for every read pane in the tree ("selection if active, else the whole focused pane"),
# and the two panes here are the ones where the operator's `y` never reached it: both are
# raw-dispatched by their controller AHEAD of the keymap, and both fell back to the caret's own
# LINE instead. So the pane's two copy keys disagreed — `^Y` (project.copy / issue.copy → the
# verb → read_copy) copied the whole description/notes, `y` copied one line of it.
#
# The assertions are on WHICH branch ran, read off the toast, because the two branches word
# their status differently ("copied Nb to clipboard" for a selection, "copied description/notes
# to clipboard (Nb)" for the whole pane). `Settings.clipboard_osc52` is off for the duration:
# `Clipboard.copy` then returns 0 without touching the tty, which is what keeps a spec run from
# writing OSC 52 at the developer's terminal and taking their clipboard with it.

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
    :project
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

# The CA is the slow part of standing a Session up and nothing here asserts about it.
private READ_COPY_CA = File.tempname("gori-read-copy-ca")
Spec.after_suite { FileUtils.rm_rf(READ_COPY_CA) }

private def with_session(&)
  root = File.tempname("gori-read-copy")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("readcopy")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(READ_COPY_CA), Gori::Verbs.registry, project)
    host = FakeHost.new(session)
    prev = Gori::Settings.clipboard_osc52?
    Gori::Settings.clipboard_osc52 = false
    begin
      yield host, session
    ensure
      Gori::Settings.clipboard_osc52 = prev
    end
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private Y = -> { key(Termisu::Input::Key::LowerY, :none, 'y') }

private TEXT = "alpha\nbravo\ncharlie"

describe "bare `y` in a raw-dispatched read pane" do
  describe "the Project description" do
    it "copies the WHOLE description when nothing is selected" do
      with_session do |host, _session|
        ctl = Gori::Tui::ProjectController.new(host)
        ctl.view.replace_desc(TEXT)
        ctl.view.pane.should eq(:desc)
        ctl.view.desc_selection?.should be_false
        # What the pane's own getter answers with no band — the caret's line, and the old
        # payload of this keypress.
        ctl.view.desc_copy_text.should eq("alpha")
        ctl.view.desc_copy_all.should eq(TEXT)

        ctl.handle_body_key(Y.call).should be_true
        host.statuses.last.should start_with("copied description to clipboard")
      end
    end

    it "still copies just the selection when one is held" do
      with_session do |host, _session|
        ctl = Gori::Tui::ProjectController.new(host)
        ctl.view.replace_desc(TEXT)
        ctl.view.desc_select_line
        ctl.view.desc_selection?.should be_true

        ctl.handle_body_key(Y.call).should be_true
        host.statuses.last.should start_with("copied 0b to clipboard") # 0b: the clipboard is off
      end
    end
  end

  describe "an Issue's notes" do
    it "copies the WHOLE notes when nothing is selected" do
      with_session do |host, session|
        store = session.store
        id = store.insert_issue("reflected param", Gori::Store::Severity::Medium, "acme.test", nil)
        store.update_issue(id, notes: TEXT).should be_true
        ctl = Gori::Tui::IssuesController.new(host)
        ctl.view.reload(store)
        ctl.view.open_detail(store).should be_true
        ctl.view.notes_select_line     # the one public route into the notes pane…
        ctl.view.notes_clear_selection # …minus the selection it plants
        ctl.view.notes_focused?.should be_true
        ctl.view.notes_selection?.should be_false
        ctl.view.notes_copy_text.should eq("alpha")
        ctl.view.notes_copy_all.should eq(TEXT)

        ctl.handle_detail_key(Y.call).should be_true
        host.statuses.last.should start_with("copied notes to clipboard")
      end
    end

    it "still copies just the selection when one is held" do
      with_session do |host, session|
        store = session.store
        id = store.insert_issue("reflected param", Gori::Store::Severity::Medium, "acme.test", nil)
        store.update_issue(id, notes: TEXT).should be_true
        ctl = Gori::Tui::IssuesController.new(host)
        ctl.view.reload(store)
        ctl.view.open_detail(store).should be_true
        ctl.view.notes_select_line
        ctl.view.notes_selection?.should be_true

        ctl.handle_detail_key(Y.call).should be_true
        host.statuses.last.should start_with("copied 0b to clipboard")
      end
    end
  end
end
