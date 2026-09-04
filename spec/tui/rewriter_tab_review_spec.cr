require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# Seven things a review of the Rewriter tab found, each pinned at the controller so the
# surface that acts on the answer is the surface under test.
#
# Three are the highlight not following the rule the operator just acted on: `c` appended
# the copy to the end of its scope block and left the cursor on the original (so the `e` that
# almost always follows re-opened the wrong rule); an edit whose scope row moved the rule to
# the other block left `@sel` on the old index, i.e. on whatever slid into it; and a
# double-click on a rule row read as two selects where every sibling rule list opens the
# editor. Then the extract sub-tab's `a`/`d`, whose strip followed a rebind of `rewriter.add`
# / `rewriter.delete` while the handler kept matching the literal letters; the empty-state
# line, which named the literal too; the preview INPUT keeping the focus after the terminal
# shrank the pane it lives in out of the layout; and PgUp/PgDn/Home/End, which did nothing on
# any of the three lists.

private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  getter opened_rules = [] of Gori::Store::MatchRule?
  getter opened_extracts = [] of Gori::Store::ExtractRule?
  property active_tab : Symbol = :rewriter

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
    @opened_rules << rule
  end

  def open_colormarker_rule_editor(rule : Gori::Store::ColorRule?) : Nil
  end

  def open_colormarker_color_editor(color : Gori::Settings::ColormarkerColor?) : Nil
  end

  def open_extract_rule_editor(rule : Gori::Store::ExtractRule?) : Nil
    @opened_extracts << rule
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

private REWRITER_REVIEW_CA = File.tempname("gori-rewriter-review-ca")
Spec.after_suite { FileUtils.rm_rf(REWRITER_REVIEW_CA) }

private def with_rewriter_controller(&)
  root = File.tempname("gori-rewriter-review")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("rewriterreview")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(REWRITER_REVIEW_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield RewriterController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The global library is process-wide state — see spec/tui/rewriter_move_refusal_spec.cr for
# why it is a file under its own GORI_HOME and not just the in-memory list.
private def with_globals(&)
  before = Gori::Settings.rewriter_rules
  counter = Gori::Settings.rewriter_next_rule_id
  prev_home = ENV["GORI_HOME"]?
  dir = File.tempname("gori-rewriter-review-globals")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    Gori::Settings.rewriter_next_rule_id = 1_i64
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.rewriter_rules = before
    Gori::Settings.rewriter_next_rule_id = counter
    FileUtils.rm_rf(dir)
  end
end

private def with_rebind(overrides : Hash(String, Array(String)), &)
  prev = Gori::Settings.keymap_overrides
  begin
    Gori::Settings.keymap_overrides = overrides
    yield
  ensure
    Gori::Settings.keymap_overrides = prev
  end
end

private def add_project(rules : Gori::Rules, name : String, pattern : String = name) : Nil
  rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, pattern, "x", name: name)
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private def down(ctl : RewriterController) : Nil
  ctl.handle_body_key(key(Termisu::Input::Key::Down))
end

private BODY = Rect.new(0, 0, 100, 40)

private def render(ctl : RewriterController, rect : Rect = BODY) : MemoryBackend
  backend = MemoryBackend.new(rect.w, rect.h)
  ctl.render_body(Screen.new(backend), rect, :body)
  backend
end

# The cell of the rules list's row `i`, in the same geometry the controller hit-tests with.
private def rule_row_cell(ctl : RewriterController, i : Int32) : {Int32, Int32}
  list_r, _, _ = ctl.@view.layout(BodyChrome.frame_inner(BODY))
  {list_r.x + 3, list_r.y + 1 + i}
end

private def sub_row_cell(ctl : RewriterController, i : Int32) : {Int32, Int32}
  _, body = ctl.@view.sub_layout(BodyChrome.frame_inner(BODY))
  {body.x + 3, body.y + 1 + i}
end

describe "Gori::Tui::RewriterController (tab review)" do
  describe "the highlight follows the rule the operator acted on" do
    it "lands on the copy after `c`, not on the original" do
      with_rewriter_controller do |ctl, _, session|
        add_project(session.rules, "one")
        add_project(session.rules, "two")
        add_project(session.rules, "three")
        ctl.selected_rule.try(&.name).should eq("one")
        ctl.rewriter_duplicate
        ctl.selected_rule.try(&.name).should eq("one copy")
        session.rules.rules.map(&.name).should eq(["one", "two", "three", "one copy"])
      end
    end

    it "stays on the original when the copy did not commit" do
      with_rewriter_controller do |ctl, host, session|
        add_project(session.rules, "one")
        add_project(session.rules, "two")
        session.store.close
        ctl.rewriter_duplicate
        host.statuses.last.should eq("rule NOT duplicated (project busy or settings not writable)")
        ctl.selected_rule.try(&.name).should eq("one")
      end
    end

    # The form's scope row is `s` one dialog in: the rule leaves its block for the END of the
    # other one, and the highlight has to go with it — `rewriter_scope_toggle` already did.
    it "follows a rule the editor re-homed to the global library" do
      with_globals do
        with_rewriter_controller do |ctl, _, session|
          add_project(session.rules, "p1")
          add_project(session.rules, "p2")
          down(ctl)
          p2 = ctl.selected_rule.should_not be_nil
          p2.name.should eq("p2")

          ov = RewriterRuleOverlay.editing(p2)
          ov.set_selected(RewriterRuleOverlay::ROW_SCOPE)
          ov.adjust(1) # this project → global
          ov.scope.global?.should be_true
          ctl.apply_rewriter_rule(ov).should be_true

          # Globals render first, so the moved rule is now row 0 and `p1` slid into row 1 —
          # the index the cursor used to be left on.
          session.rules.rules.map(&.name).should eq(["p2", "p1"])
          ctl.selected_rule.try(&.name).should eq("p2")
          ctl.selected_rule.try(&.global?).should be_true
        end
      end
    end
  end

  describe "a double-click on a row opens it" do
    it "edits the rule under the pointer" do
      with_rewriter_controller do |ctl, host, session|
        add_project(session.rules, "one")
        add_project(session.rules, "two")
        render(ctl)
        mx, my = rule_row_cell(ctl, 1)
        ctl.handle_click(BODY, mx, my) # the first press of the pair
        ctl.handle_double_click(BODY, mx, my).should be_true
        host.opened_rules.map { |r| r.try(&.name) }.should eq(["two"])
      end
    end

    it "does nothing in the card's empty space" do
      with_rewriter_controller do |ctl, host, session|
        add_project(session.rules, "one")
        render(ctl)
        mx, my = rule_row_cell(ctl, 5) # well below the one row
        ctl.handle_click(BODY, mx, my)
        ctl.handle_double_click(BODY, mx, my).should be_false
        host.opened_rules.should be_empty
      end
    end

    it "edits an extract rule on its sub-tab" do
      with_rewriter_controller do |ctl, host, session|
        session.bindings.add("TOK", "", Gori::ExtractKind::Cookie, "sid").should be_nil
        ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, :none, ']'))
        render(ctl)
        mx, my = sub_row_cell(ctl, 0)
        ctl.handle_click(BODY, mx, my)
        ctl.handle_double_click(BODY, mx, my).should be_true
        host.opened_extracts.map { |r| r.try(&.name) }.should eq(["TOK"])
      end
    end
  end

  describe "the extract sub-tab's add/delete are the chords its strip names" do
    it "follows a rebind of rewriter.add" do
      with_rebind({"rewriter.add" => ["n"]}) do
        with_rewriter_controller do |ctl, host, _|
          ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, :none, ']'))
          ctl.body_hint(:body).should contain("n add")
          ctl.handle_body_key(key(Termisu::Input::Key::LowerA, :none, 'a')).should be_false
          host.opened_extracts.should be_empty
          ctl.handle_body_key(key(Termisu::Input::Key::LowerN, :none, 'n')).should be_true
          host.opened_extracts.should eq([nil])
        end
      end
    end

    it "keeps the default `a` when nothing is rebound" do
      with_rebind({} of String => Array(String)) do
        with_rewriter_controller do |ctl, host, _|
          ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, :none, ']'))
          ctl.handle_body_key(key(Termisu::Input::Key::LowerA, :none, 'a')).should be_true
          host.opened_extracts.should eq([nil])
        end
      end
    end

    # The sub-tab's modifier guard (`^A` must not read as `a`) sits AFTER the chord arms, so
    # a rebind onto a Ctrl chord is not dead on this sub-tab alone.
    it "reaches a Ctrl chord through the sub-tab's modifier guard" do
      with_rebind({"rewriter.add" => ["ctrl-t"]}) do
        with_rewriter_controller do |ctl, host, _|
          ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, :none, ']'))
          ctl.body_hint(:body).should contain("^T add")
          ctl.handle_body_key(key(Termisu::Input::Key::LowerT, :ctrl, 't')).should be_true
          host.opened_extracts.should eq([nil])
          # …and an unrelated Ctrl letter still falls through to the keymap.
          ctl.handle_body_key(key(Termisu::Input::Key::LowerA, :ctrl, 'a')).should be_false
          host.opened_extracts.size.should eq(1)
        end
      end
    end

    it "follows a rebind of rewriter.delete" do
      with_rebind({"rewriter.delete" => ["shift-d"]}) do
        with_rewriter_controller do |ctl, host, session|
          session.bindings.add("TOK", "", Gori::ExtractKind::Cookie, "sid").should be_nil
          ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, :none, ']'))
          ctl.handle_body_key(key(Termisu::Input::Key::LowerD, :none, 'd')).should be_false
          session.bindings.rules.size.should eq(1)
          ctl.handle_body_key(key(Termisu::Input::Key::UpperD, :none, 'D')).should be_true
          host.statuses.last.should eq("extract rule deleted")
          session.bindings.rules.should be_empty
        end
      end
    end
  end

  describe "the empty-state line names the effective chord" do
    it "on the rules list" do
      with_rebind({"rewriter.add" => ["n"]}) do
        with_rewriter_controller do |ctl, _, _|
          render(ctl).contains?("no rules — press n to add").should be_true
        end
      end
    end

    it "on the extract sub-tab" do
      with_rebind({"rewriter.add" => ["n"]}) do
        with_rewriter_controller do |ctl, _, _|
          ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, :none, ']'))
          render(ctl).contains?("no extract rules — press n to add one").should be_true
        end
      end
    end
  end

  describe "the preview keeps the focus only while it is drawn" do
    it "falls back to the list when the terminal shrinks the pair away" do
      with_rewriter_controller do |ctl, _, _|
        render(ctl)
        down(ctl) # empty rule list → ↓ enters the preview input
        ctl.@focus.should eq(:preview_in)
        ctl.body_badge.should eq(:editor)
        render(ctl, Rect.new(0, 0, 100, 8)) # below LIST_MIN_H + PREVIEW_MIN_H
        ctl.@focus.should eq(:list)
        ctl.body_badge.should eq(:body)
      end
    end
  end

  describe "page keys move the focused list" do
    it "steps and clamps the rules list" do
      with_rewriter_controller do |ctl, _, session|
        4.times { |i| add_project(session.rules, "r#{i}") }
        ctl.body_scroll(2).should be_true
        ctl.selected_rule.try(&.name).should eq("r2")
        ctl.body_scroll(100).should be_true # End: past the end clamps
        ctl.selected_rule.try(&.name).should eq("r3")
        ctl.body_scroll(-100).should be_true
        ctl.selected_rule.try(&.name).should eq("r0")
      end
    end

    it "steps the extract list, and leaves the preview panes to their own keys" do
      with_rewriter_controller do |ctl, _, session|
        session.bindings.add("A", "", Gori::ExtractKind::Cookie, "a").should be_nil
        session.bindings.add("B", "", Gori::ExtractKind::Cookie, "b").should be_nil
        ctl.handle_body_key(key(Termisu::Input::Key::RightBracket, :none, ']'))
        ctl.body_scroll(5).should be_true
        ctl.selected_extract_rule.try(&.name).should eq("B")
        ctl.handle_body_key(key(Termisu::Input::Key::LeftBracket, :none, '['))
        render(ctl)
        down(ctl)
        ctl.@focus.should eq(:preview_in)
        ctl.body_scroll(5).should be_false
      end
    end
  end
end
