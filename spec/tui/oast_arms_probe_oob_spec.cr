require "../spec_helper"
require "file_utils"

include Gori::Tui

# Starting an OAST listener has to ARM the live probe analyzer's out-of-band minter.
#
# `Probe::Analyzer#@oob` — the minter the blind SSRF/XXE/command-injection rules plant against —
# is resolved once at construction and otherwise ONLY by `reload_rule_config` (a Rules-tab edit
# / factory reset). The OAST tab was the surface that creates the session those rules mint
# against, and it never touched the analyzer: a project opened with no session left `@oob` nil,
# so a listener could be live in the OAST tab while an active probe scan planted nothing and its
# empty result read as "no blind vulnerability" when it meant "never looked". `apply_registration`
# now calls `Analyzer#rearm_out_of_band`, so both a fresh register and a resume arm the rules
# without a restart.
#
# The assertion reads `session.probe.@oob` directly, the same ivar seam the sibling OAST specs
# use for `@reg_events` / `@oast_events` — a StoreMinter is non-nil exactly when the analyzer can
# mint, which is the whole of what the wiring changed.

# The narrow shell facade a controller reaches the world through. Inert except `session`, `jobs`
# and `notifications` — the members `apply_registration` and its drain touch.
private class FakeHost
  include Gori::Tui::Host

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
    :oast
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

# A Provider that never dials a socket: register would be a network call the fixture must not
# make, and apply_registration only ever calls generate_payload/deregister on a fresh RegOk.
private class ArmStubProvider < Gori::Oast::Provider
  def initialize
    super(Gori::Oast::ProviderKind::Interactsh, "https://oast.test", nil)
  end

  def register(http : Gori::Oast::Http) : Gori::Oast::Session
    raise "not used"
  end

  def generate_payload(session : Gori::Oast::Session) : String
    "#{session.correlation_id}.oast.test"
  end

  def poll(http : Gori::Oast::Http, session : Gori::Oast::Session) : Array(Gori::Oast::Interaction)
    [] of Gori::Oast::Interaction
  end
end

private ARM_CA_ROOT = File.tempname("gori-oast-arm-ca")
Spec.after_suite { FileUtils.rm_rf(ARM_CA_ROOT) }

# A real Session with one enabled project provider and NO oast_sessions row, so the analyzer is
# built with a nil out-of-band minter (the project-opened-with-no-session case).
private def with_arm_controller(&)
  saved = Gori::Settings.oast_providers
  Gori::Settings.oast_providers = [] of Gori::Settings::OastProvider
  root = File.tempname("gori-oast-arm")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("oastarm")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(ARM_CA_ROOT), Gori::Verbs.registry, project)
  begin
    pid = session.store.insert_oast_provider("prov", "interactsh", "https://oast.test", nil, true, 0)
    host = FakeHost.new(session)
    yield OastController.new(host), session, "p_#{pid}"
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
    Gori::Settings.oast_providers = saved
  end
end

private def reg_ok(key : String, corr : String) : OastController::RegOk
  engine = Gori::Oast::Session.new(0_i64, Gori::Oast::ProviderKind::Interactsh,
    "https://oast.test", corr, "sec", registered: true)
  OastController::RegOk.new(engine, ArmStubProvider.new, key, nil, key, false)
end

describe Gori::Tui::OastController do
  it "arms the probe analyzer's out-of-band minter when a listener registers" do
    with_arm_controller do |c, session, key|
      # A project opened with no session: the analyzer has nothing to mint against, so every
      # out-of-band rule plans nothing.
      session.probe.@oob.should be_nil
      # A flow the passive pass already scanned. rearm must not re-run passive analysis over it
      # (that path bumps hit_count for existing findings), so the id has to survive the register.
      session.probe.@analyzed << 4242_i64

      c.@reg_events.send(reg_ok(key, "c0rrelati0nid00001"))
      c.drain_events

      # The register inserted a session row AND re-resolved the minter, so the OOB rules can now
      # plant against the live listener without a restart or a Rules-tab edit.
      session.probe.@oob.should_not be_nil
      # It re-armed the ACTIVE pipeline only — @analyzed is untouched, so no passive re-scan and
      # no hit_count inflation on existing findings (that is why it is not `@analyzed.clear`).
      session.probe.@analyzed.includes?(4242_i64).should be_true
    end
  end

  it "does NOT arm when the provider vanished mid-flight (the discard path)" do
    with_arm_controller do |c, session, _key|
      session.probe.@oob.should be_nil
      # A RegOk whose key names no current provider is discarded before any session row is
      # written, so the minter stays nil — the rearm call sits past that early return.
      c.@reg_events.send(reg_ok("p_999999", "c0rrelati0nid00002"))
      c.drain_events
      session.probe.@oob.should be_nil
    end
  end
end
