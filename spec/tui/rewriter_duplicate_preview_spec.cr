require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# Two things the Rewriter tab did to a rule the operator was looking at.
#
# `c` (duplicate) built the copy through `Rules#add`, whose `enabled` defaults to true because
# "add a rule" means "start rewriting". Duplicating is not adding: the row the key was pressed
# on says `·` or `✓`, and a copy of a DISABLED rule coming back armed is a live traffic rewrite
# nobody asked for — for a `stub` rule, an endpoint that stops reaching the origin at all.
#
# The PREVIEW pair passed `RuleTarget::Request` unconditionally, so every `RES` rule in the list
# — half of what the tab can express — previewed as "nothing happened", with nothing on screen
# saying the pane could not test it. The side is now read off the sample's own first line.

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

# The CA is the one slow part of standing a Session up (a root keypair) and no example asserts
# anything about it, so it is built once.
private REWRITER_DUP_CA = File.tempname("gori-rewriter-dup-ca")
Spec.after_suite { FileUtils.rm_rf(REWRITER_DUP_CA) }

private def with_rewriter_controller(&)
  root = File.tempname("gori-rewriter-dup")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("rewriterdup")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(REWRITER_DUP_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield RewriterController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "Gori::Tui::RewriterController#rewriter_duplicate" do
  it "keeps a disabled rule disabled in the copy" do
    with_rewriter_controller do |ctl, host, session|
      rules = session.rules
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "secret", "x",
        name: "redact", enabled: false)
      ctl.selected_rule.try(&.enabled?).should be_false

      host.statuses.clear
      ctl.rewriter_duplicate

      copies = session.rules.rules
      copies.size.should eq(2)
      # The copy is the operator's rule as they were looking at it: same bytes, same state.
      copy = copies.last
      copy.name.should eq("redact copy")
      copy.pattern.should eq("secret")
      copy.enabled?.should be_false
      # And the toast says so, because an off rule is the one case where "duplicated" alone
      # would leave the operator unsure which of the two answers they got.
      host.statuses.first.should eq("rule duplicated (disabled, like the original)")
    end
  end

  it "keeps an enabled rule enabled, and says nothing extra" do
    with_rewriter_controller do |ctl, host, session|
      session.rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "a", "b")
      host.statuses.clear
      ctl.rewriter_duplicate
      session.rules.rules.map(&.enabled?).should eq([true, true])
      host.statuses.first.should eq("rule duplicated")
    end
  end
end

describe "Gori::Tui::RewriterController#preview_target" do
  it "reads the side off the sample, so a RESPONSE rule can be previewed at all" do
    with_rewriter_controller do |ctl, _host, session|
      # A response-side rule: before this it could not be tried anywhere in the TUI.
      session.rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Head,
        "200 OK", "418 I'm a teapot")
      ctl.preview_target.should eq(Gori::Store::RuleTarget::Request) # the default sample

      ctl.@preview_input.set_text("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nhi")
      ctl.preview_target.should eq(Gori::Store::RuleTarget::Response)
      ctl.@out.source([] of String)
      ctl.render_body(Screen.new(MemoryBackend.new(100, 40)), Rect.new(0, 0, 100, 40), :body)
      ctl.@out.copy_all.should contain("418 I'm a teapot")
    end
  end

  # …and the badge the side goes on has to say the OTHER half of "does this rule fire here".
  # An empty host matches only an UNSCOPED rule, and a response head carries no `Host:` line —
  # so a rule scoped `*.example.com` produces an unchanged pane, which reads exactly like a
  # pattern that missed. The pane names the host it used instead.
  it "names the host it scoped on, and says so when there is none" do
    with_rewriter_controller do |ctl, _host, session|
      session.rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Head,
        "200 OK", "418", host: "example.com")
      screen = Screen.new(MemoryBackend.new(100, 40))

      # A response sample: no Host: line anywhere, so the host-scoped rule cannot fire.
      ctl.@preview_input.set_text("HTTP/1.1 200 OK\r\n\r\nhi")
      ctl.render_body(screen, Rect.new(0, 0, 100, 40), :body)
      ctl.preview_host.should eq("")
      ctl.@out.copy_all.should_not contain("418")

      # `host_from_sample` reads a `Host:` line wherever it appears, which is how an operator
      # previews a host-scoped RESPONSE rule at all.
      ctl.@preview_input.set_text("HTTP/1.1 200 OK\r\nHost: api.example.com\r\n\r\nhi")
      ctl.render_body(screen, Rect.new(0, 0, 100, 40), :body)
      ctl.preview_host.should eq("api.example.com")
      ctl.@out.copy_all.should contain("418")
    end
  end

  it "leaves a request sample on the request side" do
    with_rewriter_controller do |ctl, _host, session|
      session.rules.add(Gori::Store::RuleTarget::Response, Gori::Store::RulePart::Head,
        "200 OK", "418 I'm a teapot")
      ctl.preview_target.should eq(Gori::Store::RuleTarget::Request)
      ctl.render_body(Screen.new(MemoryBackend.new(100, 40)), Rect.new(0, 0, 100, 40), :body)
      # A RES rule must not touch a REQ sample — the preview has to mirror the proxy path.
      ctl.@out.copy_all.should_not contain("418")
    end
  end
end
