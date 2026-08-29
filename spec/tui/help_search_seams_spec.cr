require "../spec_helper"
require "file_utils"
require "../support/memory_backend"

include Gori::Tui

# What the Help/Hotkeys `/` search must NOT do to the surfaces around it.
#
# The search modes were added on top of panes that had never owned a caret and a strip that
# had never had state worth losing, so each of these is a seam between the new mode and
# machinery that predates it:
#
#   * The Help pane's field draws whether or not the BODY holds focus, because Tab is claimed
#     by the runner's focus ring before `handle_body_key` and so cannot cancel the search. An
#     ungated `input_line` then stamps `desired_cursor` every frame, and the shell turns that
#     into a real hardware caret — the anchor a terminal draws its IME composition at — parked
#     in an unfocused pane. The search survives the focus change (that is the nice behaviour);
#     only the caret must not.
#   * `^K`/`^L` reach the controller as LowerK/LowerL with ctrl set — termisu remaps ^H/^I/^J
#     to Backspace/Tab/Enter but not these — so the vi-letter arms had to stop answering to
#     them, or a redraw-reflex ^L silently throws a half-typed query away.
#   * `move_subtab` is called as a PROBE by the strip (`step_left_or_find` asks "am I on the
#     first chip?" by whether the index moved), so cancelling on the call rather than on the
#     change loses a query to a ← that switched nothing.
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

  def apply_project_protos(spec : String) : String
    ""
  end
end

# The CA is the slow part of standing a Session up and nothing here asserts about it.
private HELP_SEARCH_CA = File.tempname("gori-help-search-ca")
Spec.after_suite { FileUtils.rm_rf(HELP_SEARCH_CA) }

private def with_help_controller(&)
  root = File.tempname("gori-help-search")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("helpsearch")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(HELP_SEARCH_CA), Gori::Verbs.registry, project)
    host = FakeHost.new(session)
    yield Gori::Tui::HelpController.new(host), host
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def help_key(char : Char) : Termisu::Event::Key
  Termisu::Event::Key.new(Termisu::Input::Key.from_char(char), char: char)
end

private def help_ctrl(key : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(key, Termisu::Input::Modifier::Ctrl)
end

# `body_badge` is the controller's own public answer to "is a search running" (the shell reads
# it to let bracketed paste type into the field), and nothing but `cancel_search` flips it back.
private def searching?(controller : Gori::Tui::HelpController) : Bool
  controller.body_badge == :editor
end

describe "Help search and the surfaces around it" do
  describe "the Help pane's caret" do
    it "is claimed only while the body is focused, and the query outlives the focus change" do
      view = HelpView.new
      view.handle_search_key(help_key('/'), :shortcuts).should be_true
      "capture".each_char { |char| view.handle_search_key(help_key(char), :shortcuts) }

      # Focused: the field is a real editor, so the shell gets a caret to anchor IME at.
      focused = Screen.new(MemoryBackend.new(100, 20))
      view.render(focused, Rect.new(0, 0, 100, 20), focused: true)
      focused.desired_cursor.should_not be_nil

      # Unfocused (Tab stepped out to the strip): the query is still typed and still filtering,
      # but a caret here would blink inside a pane the operator has left.
      backend = MemoryBackend.new(100, 20)
      unfocused = Screen.new(backend)
      view.render(unfocused, Rect.new(0, 0, 100, 20), focused: false)
      unfocused.desired_cursor.should be_nil
      view.search_query.should eq("capture")
      backend.contains?("capture").should be_true
    end

    it "gates the Query page the same way — it is the other page `/` searches" do
      view = HelpView.new
      view.handle_search_key(help_key('/'), :query).should be_true

      focused = Screen.new(MemoryBackend.new(100, 20))
      view.render_query(focused, Rect.new(0, 0, 100, 20), focused: true)
      focused.desired_cursor.should_not be_nil

      unfocused = Screen.new(MemoryBackend.new(100, 20))
      view.render_query(unfocused, Rect.new(0, 0, 100, 20), focused: false)
      unfocused.desired_cursor.should be_nil
    end
  end

  describe "the vi-letter navigation arms" do
    it "leave a ctrl chord alone mid-search instead of switching pages under it" do
      with_help_controller do |controller, _host|
        controller.handle_body_key(help_key('/')).should be_true
        "capture".each_char { |char| controller.handle_body_key(help_key(char)) }
        searching?(controller).should be_true

        # ^L is a redraw reflex, and it decodes as LowerL+Ctrl. It must fall THROUGH to the
        # global keymap: claiming it would run move_subtab, whose cancel eats the query.
        controller.handle_body_key(help_ctrl(Termisu::Input::Key::LowerL)).should be_false
        controller.subtab_index.should eq(0)
        searching?(controller).should be_true

        # ^K likewise — claiming it popped focus to the strip while the search stayed live.
        controller.handle_body_key(help_ctrl(Termisu::Input::Key::LowerK)).should be_false
        searching?(controller).should be_true
      end
    end

    it "still answer to the bare letters they were added for" do
      with_help_controller do |controller, _host|
        controller.handle_body_key(help_key('l')).should be_true
        controller.subtab_index.should eq(1)
        controller.handle_body_key(help_key('h')).should be_true
        controller.subtab_index.should eq(0)
      end
    end
  end

  describe "the sub-tab strip" do
    it "keeps an active search across a ← that switches nothing" do
      with_help_controller do |controller, _host|
        controller.handle_body_key(help_key('/')).should be_true
        searching?(controller).should be_true

        # `step_left_or_find` calls this purely to find out whether chip 0 is already current.
        controller.move_subtab(-1)
        controller.subtab_index.should eq(0)
        searching?(controller).should be_true

        controller.jump_subtab(0) # ^1 onto the page already showing
        searching?(controller).should be_true
      end
    end

    it "cancels it on a move that does land on another page" do
      with_help_controller do |controller, _host|
        controller.handle_body_key(help_key('/')).should be_true
        controller.move_subtab(1)
        controller.subtab_index.should eq(1)
        searching?(controller).should be_false
      end
    end
  end
end
