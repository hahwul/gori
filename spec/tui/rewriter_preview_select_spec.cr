require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# The Rewriter's PREVIEW INPUT was the last `TextArea` editor still hand-rolling its own
# arrow keys, and the hand-rolled set passed no `selecting:` anywhere.
#
# That left it inverted against every sibling: `RewriterController#handle_drag` and
# `#handle_double_click` gave this exact pane a mouse selection (drag to extend, double-click
# to take a word), and `handle_preview_in_key` gave it no way to make one from the keyboard —
# no ⇧arrows, no Page keys, no ⇧Home/⇧End, no ⌥←/→ by word, no ⌥⌫. The OUTPUT pane one column
# to its right had ⇧arrows the whole time (`handle_preview_out_key`), so the two halves of the
# same preview disagreed about what shift meant.
#
# The fix routes everything below the three pane-crossing arms through
# `TextArea#handle_motion_key` — the one keymap #583 gave the other eight surfaces. These
# examples pin both halves of that: the motions now arrive, AND the crossing arms still
# fire on a bare press while refusing to fire on a modified one (⇧↑ at the top must not
# abandon a selection mid-build, ⌥← at column 0 is a word step this pane owns).

# The narrow shell facade a controller is given. Everything here is inert except `session` —
# the only member the Rewriter touches on construction and on every preview keystroke.
# File-local rather than shared, matching `oast_callback_cap_spec` / `repeater_refusal_inline_spec`:
# `Host` is ~35 abstract methods and a shared support double would be one more file to keep in
# sync with the module every time it grows.
private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  getter space_menus = 0

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
    @space_menus += 1
  end

  def open_fuzz_set_editor(edit_index : Int32?) : Nil
  end

  def open_fuzz_advanced_editor : Nil
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
    :rewriter
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

# The CA is the one slow part of standing a Session up (a root keypair) and no example here
# asserts anything about it, so it is built once for the file.
private REWRITER_SEL_CA = File.tempname("gori-rewriter-sel-ca")
Spec.after_suite { FileUtils.rm_rf(REWRITER_SEL_CA) }

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

# A Rewriter controller already FOCUSED on the preview input, with the caret at (0, 0) of the
# default sample. Focus gets there the way an operator does — a render (which is what fills
# `@last_body`, the rect `preview_available?` measures) then ↓ off the empty rule list — rather
# than by poking `@focus`, so the geometry gate is part of what these examples exercise.
private def with_preview_focus(&)
  root = File.tempname("gori-rewriter-sel")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("rewritersel")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(REWRITER_SEL_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    ctl = RewriterController.new(host)
    backend = MemoryBackend.new(100, 40)
    ctl.render_body(Screen.new(backend), Rect.new(0, 0, 100, 40), :body)
    ctl.handle_body_key(key(Termisu::Input::Key::Down)) # empty rule list → ↓ enters the preview
    ctl.@focus.should eq(:preview_in)
    yield ctl
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "Gori::Tui::RewriterController preview-input selection" do
  describe "the keyboard half it never had" do
    it "⇧→ selects forward from the caret" do
      with_preview_focus do |ctl|
        ed = ctl.@preview_input
        ed.selection?.should be_false
        ctl.handle_body_key(key(Termisu::Input::Key::Right, :shift))
        ed.selection_text.should eq("G")
        ctl.handle_body_key(key(Termisu::Input::Key::Right, :shift))
        ed.selection_text.should eq("GE")
      end
    end

    it "an unmodified → collapses the selection instead of extending it" do
      with_preview_focus do |ctl|
        ed = ctl.@preview_input
        ctl.handle_body_key(key(Termisu::Input::Key::Right, :shift))
        ctl.handle_body_key(key(Termisu::Input::Key::Right))
        ed.selection?.should be_false
      end
    end

    it "⇧End selects to the end of the line" do
      with_preview_focus do |ctl|
        ctl.handle_body_key(key(Termisu::Input::Key::End, :shift))
        ctl.@preview_input.selection_text.should eq("GET /index.html HTTP/1.1")
      end
    end

    # `word_right` lands on the START of the next word, not the end of the current one —
    # so from column 0 of "GET /index.html …" the caret settles at 4, past the space.
    it "⌥→ steps by word" do
      with_preview_focus do |ctl|
        ctl.handle_body_key(key(Termisu::Input::Key::Right, :alt))
        ctl.@preview_input.cursor_offset.should eq("GET ".size)
      end
    end

    it "⌥⌫ deletes the word behind the caret" do
      with_preview_focus do |ctl|
        ed = ctl.@preview_input
        ctl.handle_body_key(key(Termisu::Input::Key::Right, :alt))
        ctl.handle_body_key(key(Termisu::Input::Key::Backspace, :alt))
        ed.lines_snapshot.first.should eq("/index.html HTTP/1.1")
      end
    end

    it "PageDown moves the caret a screenful down" do
      with_preview_focus do |ctl|
        ed = ctl.@preview_input
        ctl.handle_body_key(key(Termisu::Input::Key::PageDown))
        ed.cursor_offset.should_not eq(0)
      end
    end
  end

  describe "the pane-crossing arms still claim a BARE press only" do
    it "↑ at the top leaves for the rule list" do
      with_preview_focus do |ctl|
        ctl.handle_body_key(key(Termisu::Input::Key::Up))
        ctl.@focus.should eq(:list)
      end
    end

    it "⇧↑ at the top stays in the pane — leaving would abandon a selection mid-build" do
      with_preview_focus do |ctl|
        ctl.handle_body_key(key(Termisu::Input::Key::Up, :shift))
        ctl.@focus.should eq(:preview_in)
      end
    end

    it "← at the buffer start leaves for the rule list" do
      with_preview_focus do |ctl|
        ctl.handle_body_key(key(Termisu::Input::Key::Left))
        ctl.@focus.should eq(:list)
      end
    end

    it "⌥← at column 0 stays in the pane — it is a word step, not an exit" do
      with_preview_focus do |ctl|
        ctl.handle_body_key(key(Termisu::Input::Key::Left, :alt))
        ctl.@focus.should eq(:preview_in)
      end
    end

    it "⇧← at column 0 stays in the pane" do
      with_preview_focus do |ctl|
        ctl.handle_body_key(key(Termisu::Input::Key::Left, :shift))
        ctl.@focus.should eq(:preview_in)
      end
    end
  end

  describe "editing still works around the new routing" do
    it "a printable char inserts and ⌫ takes exactly one character back" do
      with_preview_focus do |ctl|
        ed = ctl.@preview_input
        ctl.handle_body_key(key(Termisu::Input::Key::LowerX, :none, 'x'))
        ed.lines_snapshot.first.should eq("xGET /index.html HTTP/1.1")
        ctl.handle_body_key(key(Termisu::Input::Key::Backspace))
        ed.lines_snapshot.first.should eq("GET /index.html HTTP/1.1")
      end
    end
  end

  # The band the examples above build is copyable — `rewriter_copy` has always taken it — but
  # the footer named neither the ⇧arrows nor the key. This pane never leaves INSERT, so the
  # `y` its OUTPUT twin one column right advertises is, here, a literal character that
  # REPLACES the band; `^Y` is the only copy it has, and now the only copy it names.
  describe "the footer names the copy this pane actually has" do
    it "advertises ⇧arrows select and ^Y, not the bare y of a READ pane" do
      with_preview_focus do |ctl|
        hint = ctl.body_hint(:body)
        hint.should contain("⇧arrows select")
        hint.should contain("^Y copy")
      end
    end

    # Through `rewriter_copy_target` — the decision `rewriter_copy` actually makes — and NOT
    # `rewriter_selection_text`, which is the "Send selection to" payload and derives the same
    # answer separately. Asserting the send-selection getter here would have left the copy path
    # free to drift on the one pane whose ^Y is its only copy.
    it "copies the band it advertises" do
      with_preview_focus do |ctl|
        3.times { ctl.handle_body_key(key(Termisu::Input::Key::Right, :shift)) }
        sel, text = ctl.rewriter_copy_target
        sel.should be_true
        text.should eq("GET")
      end
    end

    it "falls back to the whole sample when no band is live" do
      with_preview_focus do |ctl|
        sel, text = ctl.rewriter_copy_target
        sel.should be_false
        text.should eq(ctl.@preview_input.text)
      end
    end

    # The chord the footer names has to answer even with nothing to take, or it reads as
    # unbound on a pane where it is the ONLY copy.
    it "says so instead of going silent on an empty sample" do
      with_preview_focus do |ctl|
        ctl.@preview_input.set_text("")
        ctl.rewriter_copy
        ctl.@host.as(FakeHost).statuses.last.should eq("nothing to copy")
      end
    end
  end
end
