require "../spec_helper"
require "file_utils"

include Gori::Tui

# ⇧J/⇧K on the Rewriter's rule list reorder the rule in the APPLIED order, and `Rules#move`
# answers whether that reorder reached disk (spec/rules_spec.cr pins that half). This pins the
# surface acting on the answer.
#
# The controller acted on the answer only by NOT walking the cursor, which is the same thing it
# does when the rule already sits at the edge of its own scope block — so a refused reorder and
# a legitimate no-op looked identical, both of them silent. Precedence is what decides which of
# two rules touching the same header wins (and, for a `short_circuit` rule, which one answers
# for the request at all), so an operator told nothing reads it as "already last", stops trying,
# and keeps testing against an order that reverts at next start.
#
# The lever is the GLOBAL half: a settings.json path whose parent is a plain file, so
# `Settings.save` fails and `Settings.move_rewriter_rule` answers false — same blocker
# spec/rules_spec.cr uses, and it leaves the rule list readable, which closing the store would
# not (`move_rule` reads the positions before it writes them).

private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
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

# The CA is the one slow part of standing a Session up (a root keypair) and no example asserts
# anything about it, so it is built once.
private REWRITER_MOVE_CA = File.tempname("gori-rewriter-move-ca")
Spec.after_suite { FileUtils.rm_rf(REWRITER_MOVE_CA) }

private def with_rewriter_controller(&)
  root = File.tempname("gori-rewriter-move")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("rewritermove")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(REWRITER_MOVE_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield RewriterController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The global library is process-wide state, so each example gets an empty one and hands the
# operator's back on the way out.
private def with_globals(&)
  before = Gori::Settings.rewriter_rules
  counter = Gori::Settings.rewriter_next_rule_id
  begin
    Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    Gori::Settings.rewriter_next_rule_id = 1_i64
    yield
  ensure
    Gori::Settings.rewriter_rules = before
    Gori::Settings.rewriter_next_rule_id = counter
  end
end

# A settings.json under a path that cannot hold one, so every `Settings.save` fails.
private def with_unwritable_settings(&)
  blocker = File.tempname("gori-settings-blocked", "")
  File.write(blocker, "")
  before = Gori::Settings.path_override
  begin
    Gori::Settings.path_override = File.join(blocker, "settings.json")
    yield
  ensure
    Gori::Settings.path_override = before
    File.delete?(blocker)
  end
end

private def add_global(rules : Gori::Rules, pattern : String) : Nil
  rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, pattern, "x",
    scope: Gori::Store::RuleScope::Global)
end

private def down(ctl : RewriterController) : Nil
  ctl.handle_body_key(Termisu::Event::Key.new(Termisu::Input::Key::Down, :none, nil))
end

describe "Gori::Tui::RewriterController#rewriter_move" do
  it "reports a reorder the backing store refused" do
    with_globals do
      with_rewriter_controller do |ctl, host, session|
        rules = session.rules
        add_global(rules, "A")
        add_global(rules, "B")
        add_global(rules, "C")
        down(ctl) # onto B — neither edge of the global block, so only a write can refuse it
        middle = ctl.selected_rule.should_not be_nil
        middle.pattern.should eq("B")

        host.statuses.clear
        with_unwritable_settings { ctl.rewriter_move(1) }

        host.statuses.size.should eq(1)
        host.statuses.first.should eq("precedence NOT changed (project busy or settings not writable)")
        # The cursor stays on the rule, and the order the proxy reads is the old one.
        ctl.selected_rule.try(&.pattern).should eq("B")
        session.rules.rules.map(&.pattern).should eq(["A", "B", "C"])
      end
    end
  end

  it "stays silent at the edge of the rule's own scope block" do
    with_globals do
      with_rewriter_controller do |ctl, host, session|
        rules = session.rules
        add_global(rules, "A")
        add_global(rules, "B")
        # A project rule renders BELOW the globals in the one merged list, and ⇧J on the last
        # global cannot push it into that block — becoming a project rule is `s`, a different
        # decision. Nothing was attempted, so nothing is reported: the edge question has to be
        # asked of the rule's own scope slice, not of the merged list the row index comes from.
        rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "P", "x")
        down(ctl) # onto B, the last GLOBAL rule
        ctl.selected_rule.try(&.pattern).should eq("B")

        host.statuses.clear
        ctl.rewriter_move(1)

        host.statuses.should be_empty
        ctl.selected_rule.try(&.pattern).should eq("B")
        session.rules.rules.map(&.pattern).should eq(["A", "B", "P"])
      end
    end
  end
end
