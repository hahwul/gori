require "../spec_helper"
require "file_utils"

include Gori::Tui

# The Probe Rules sub-tab's custom-rule form saves through `ProbeController#apply_custom_rule`,
# and for a PROJECT-scope edit that is one `Store#update_probe_custom_rule` — a write that used
# to run through `exec_task` and answer nothing (`last_insert_rowid` says nothing about an
# UPDATE). So the status strip said "updated custom rule" whether the batch committed or rolled
# back, and a custom probe rule IS a detection: an operator who widens a pattern, is told it was
# saved, and keeps scanning is scanning with the OLD pattern — a false negative they were told
# not to expect. The store now answers (spec/commit_confirmation_spec.cr pins that half), and
# this pins the surface acting on the answer: the refusal names the rule, and the form stays
# open (`false`) so the edit survives for a retry rather than being silently discarded.
#
# `session.store.close` is the lever: `apply_custom_rule` reaches the write with no store READ
# in between, so nothing refuses earlier.

private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :probe

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
private RULE_EDIT_CA_ROOT = File.tempname("gori-probe-rule-edit-ca")
Spec.after_suite { FileUtils.rm_rf(RULE_EDIT_CA_ROOT) }

private def with_probe_controller(&)
  root = File.tempname("gori-probe-rule-edit")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("ruleedit")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(RULE_EDIT_CA_ROOT), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield ProbeController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The form as the operator left it: the seeded rule with a WIDER pattern typed in. Built through
# `editing` so `edit_id`/`edit_scope` carry the project row, which is what routes the save to the
# project writer rather than to settings.json.
private def widened_form(row_id : Int64) : CustomRuleOverlay
  CustomRuleOverlay.editing(Gori::Probe::CustomRule.new(
    id: row_id.to_s, title: "leaky", description: "finds a debug header", side: "response",
    region: "header", kind: "string", pattern: "X-Debug|X-Trace",
    severity: Gori::Store::Severity::High, scope: "project", enabled: true))
end

# The GLOBAL half of the same form: an edit that lands in settings.json rather than in the
# project DB. `Settings.save` answers the same "did it COMMIT" question the store does — it
# refuses outright after a half-read load — and the branch above used to throw that answer away,
# so the one scope that could not report a refusal was also the one whose rolled-back edit stayed
# live in `Settings.scan_rules` (spec/settings/scan_rules_spec.cr pins that half).
#
# The lever is the partial-read latch: valid JSON that is not an object, so `apply_sections`
# raises at its first section and every later `save` returns false without touching the disk.
private def with_global_scan_rule(*, refused : Bool, &)
  dir = File.tempname("gori-probe-rule-edit-home")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev_rules = Gori::Settings.scan_rules
  prev_theme = Gori::Settings.theme
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.warning_io = nil
    Gori::Settings.reset_load_warning_guard
    File.write(Gori::Settings.path, refused ? %([{"theme":"dracula"}]) : %({"theme":"goridark"}))
    Gori::Settings.load
    Gori::Settings.save.should be_false if refused # a latch that stopped latching passes vacuously
    # Seeded AFTER the load, which resets every section: an edit to an id the library does not
    # hold would be refused by not-found rather than by the write, on fixed and unfixed source
    # alike.
    Gori::Settings.scan_rules = [Gori::Settings::ScanRule.new("s1", "leaky",
      "finds a debug header", "response", "header", "string", "X-Debug", "info", true)]
    yield "s1"
  ensure
    # Clear the latch BEFORE restoring the properties: this load resets them.
    File.write(Gori::Settings.path, %({"theme":"goridark"}))
    Gori::Settings.load
    Gori::Settings.scan_rules = prev_rules
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(dir)
    Gori::Settings.theme = prev_theme
    Gori::Settings.bind_port = 8070
  end
end

# The same widened pattern, scoped GLOBAL so `edit_scope` routes the save to settings.json.
private def widened_global_form(id : String) : CustomRuleOverlay
  CustomRuleOverlay.editing(Gori::Probe::CustomRule.new(
    id: id, title: "leaky", description: "finds a debug header", side: "response",
    region: "header", kind: "string", pattern: "X-Debug|X-Trace",
    severity: Gori::Store::Severity::High, scope: "global", enabled: true))
end

describe "Gori::Tui::ProbeController#apply_custom_rule" do
  it "saves a project-scope edit and reports it" do
    with_probe_controller do |controller, host, session|
      id = session.store.insert_probe_custom_rule("leaky", "finds a debug header", "response",
        "header", "string", "X-Debug", Gori::Store::Severity::Info)

      controller.apply_custom_rule(widened_form(id)).should be_true
      host.statuses.last.should eq("updated custom rule")
      row = session.store.probe_custom_rules.first
      row.pattern.should eq("X-Debug|X-Trace")
      row.severity.should eq(Gori::Store::Severity::High)
    end
  end

  it "refuses, names the rule, and keeps the form open when the edit does not commit" do
    with_probe_controller do |controller, host, session|
      id = session.store.insert_probe_custom_rule("leaky", "finds a debug header", "response",
        "header", "string", "X-Debug", Gori::Store::Severity::Info)

      session.store.close # every write from here answers false

      # false = keep the card up, which is also what an INVALID form returns — the operator's
      # widened pattern is still in the fields to save again.
      controller.apply_custom_rule(widened_form(id)).should be_false
      # `<noun> NOT <verbed> (<cause>) — <consequence>`, the strip's refusal template
      # (spec/tui/toast_wording_spec.cr), and NAMED like the toggle refusals beside it.
      host.statuses.last.should eq(
        %(rule "leaky" NOT updated (project busy) — it still matches on the old pattern))
      host.statuses.should_not contain("updated custom rule")
    end
  end

  it "saves a global-scope edit to settings.json and reports it" do
    with_probe_controller do |controller, host, _session|
      with_global_scan_rule(refused: false) do |id|
        controller.apply_custom_rule(widened_global_form(id)).should be_true
        host.statuses.last.should eq("updated custom rule")
        r = Gori::Settings.scan_rules.first
        {r.pattern, r.severity}.should eq({"X-Debug|X-Trace", "high"})
        # …and it reached the FILE. That is the answer the branch below acts on, so the
        # positive case has to show the answer means what it says.
        JSON.parse(File.read(Gori::Settings.path))["scan_rules"][0]["pattern"].as_s
          .should eq("X-Debug|X-Trace")
      end
    end
  end

  it "refuses a global-scope edit settings.json did not take, wording it like the project one" do
    with_probe_controller do |controller, host, _session|
      with_global_scan_rule(refused: true) do |id|
        controller.apply_custom_rule(widened_global_form(id)).should be_false
        # Same template as the project branch, with the cause this file has: `(settings not
        # writable)`, the label every other settings.json refusal uses.
        host.statuses.last.should eq(
          %(rule "leaky" NOT updated (settings not writable) — it still matches on the old pattern))
        host.statuses.should_not contain("updated custom rule")
        # And the library still matches on the old pattern, exactly as the strip says.
        Gori::Settings.scan_rules.first.pattern.should eq("X-Debug")
      end
    end
  end
end
