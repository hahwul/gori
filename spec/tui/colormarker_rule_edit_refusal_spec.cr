require "../spec_helper"
require "file_utils"

include Gori::Tui

# The Colormarker rule editor commits through `ColormarkerController#apply_color_rule`, and the
# runner closes the overlay on a TRUE answer (`close_active_overlay(ov) if ov.commit`, twice in
# `Runner#dispatch_overlay_key`/`_click`). So a refused write that answered true printed its
# status AND destroyed the form: the condition, colour, style and name the operator had just
# typed are the only copy there is, and after the close they exist nowhere but a one-line toast.
#
# `Colormarker#add`/`#update` answer the commit question (spec/colormarker_spec.cr pins that
# half); this pins the surface acting on it — the refusal is reported and the card stays up, the
# contract `ProbeController#apply_custom_rule` already carries for the same reason.
#
# The lever is the GLOBAL scope: a settings.json path whose parent is a plain file, so every
# `Settings.save` fails while the project store stays open — which matters, because `add` and
# `update` both `refresh` afterwards, and `refresh` READS the store.

private class FakeHost
  include Gori::Tui::Host

  getter statuses = [] of String
  property active_tab : Symbol = :colormarker

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
private COLORMARKER_EDIT_CA = File.tempname("gori-colormarker-edit-ca")
Spec.after_suite { FileUtils.rm_rf(COLORMARKER_EDIT_CA) }

private def with_colormarker_controller(&)
  root = File.tempname("gori-colormarker-edit")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("colormarkeredit")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(COLORMARKER_EDIT_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield ColormarkerController.new(host), host, session
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The global library is process-wide state, so each example gets an empty one and hands the
# operator's back on the way out.
private def with_globals(&)
  before = Gori::Settings.colormarker_rules
  counter = Gori::Settings.colormarker_next_rule_id
  begin
    Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
    Gori::Settings.colormarker_next_rule_id = 1_i64
    yield
  ensure
    Gori::Settings.colormarker_rules = before
    Gori::Settings.colormarker_next_rule_id = counter
  end
end

# A settings.json under a path that cannot hold one, so every `Settings.save` fails — the same
# lever spec/tui/rewriter_move_refusal_spec.cr uses.
private def with_unwritable_settings(&)
  blocker = File.tempname("gori-colormarker-settings-blocked", "")
  File.write(blocker, "")
  before = Gori::Settings.path_override
  begin
    Gori::Settings.path_override = File.join(blocker, "settings.json")
    Gori::Settings.save.should be_false # a lever that stopped levering passes vacuously
    yield
  ensure
    Gori::Settings.path_override = before
    File.delete?(blocker)
  end
end

# A settings.json of this example's own, for the two cases where the write DOES commit: the
# suite-wide file is read by every later `Settings.load`, and a `colormarker` section left in it
# would arrive in another spec's project as a rule it never created.
private def with_own_settings(&)
  dir = File.tempname("gori-colormarker-edit-home")
  Dir.mkdir_p(dir)
  before = Gori::Settings.path_override
  begin
    Gori::Settings.path_override = File.join(dir, "settings.json")
    yield
  ensure
    Gori::Settings.path_override = before
    FileUtils.rm_rf(dir)
  end
end

# The form as the operator left it: a NEW global rule with a condition typed into the `when`
# field. Built through the initializer rather than by injecting keys, because what is under test
# is the commit, not the editing.
private def typed_add_form : ColormarkerRuleOverlay
  ColormarkerRuleOverlay.new(name: "prod 5xx", match_filter: "status:500",
    color: "red", style: "full", scope: "global")
end

# An EDIT of the seeded global rule, with a widened condition typed in. `edit_scope` and `scope`
# are both global so `from == ov.scope` and the re-home branch never runs — the only write in
# play is the update itself.
private def typed_edit_form : ColormarkerRuleOverlay
  ColormarkerRuleOverlay.new(name: "prod 5xx", match_filter: "status:503",
    color: "red", style: "full", scope: "global",
    edit_id: 1_i64, edit_scope: Gori::Store::RuleScope::Global)
end

private def seed_global_rule : Nil
  Gori::Settings.colormarker_rules = [
    Gori::Settings::ColormarkerRule.new(1_i64, true, "prod 5xx", "status:500", "red", "full"),
  ]
end

describe "Gori::Tui::ColormarkerController#apply_color_rule" do
  it "commits an added global rule and closes the form" do
    with_globals do
      with_colormarker_controller do |ctl, host, _session|
        with_own_settings do
          ctl.apply_color_rule(typed_add_form).should be_true
          host.statuses.should be_empty
          Gori::Settings.colormarker_rules.map(&.match_filter).should eq(["status:500"])
          # …and it reached the FILE. The refusals below act on that answer, so the positive
          # case has to show the answer means what it says.
          JSON.parse(File.read(Gori::Settings.path))["colormarker"]["rules"][0]["when"].as_s
            .should eq("status:500")
        end
      end
    end
  end

  it "keeps the form open when the ADD did not commit" do
    with_globals do
      with_colormarker_controller do |ctl, host, _session|
        with_unwritable_settings do
          # false = keep the card up. The typed condition, colour and style live nowhere else,
          # so closing the overlay here is the edit being deleted by the report of its refusal.
          ctl.apply_color_rule(typed_add_form).should be_false
          host.statuses.last.should eq("rule NOT added (project busy or settings not writable)")
        end
      end
    end
  end

  it "keeps the form open when the EDIT did not commit" do
    with_globals do
      with_colormarker_controller do |ctl, host, _session|
        with_unwritable_settings do
          # Seeded INSIDE the jail and with the id the form carries: an edit to an id the library
          # does not hold would be refused by not-found rather than by the write, on fixed and
          # unfixed source alike.
          seed_global_rule
          ctl.apply_color_rule(typed_edit_form).should be_false
          host.statuses.last.should eq(
            "rule NOT saved (project busy or settings not writable) — it is unchanged")
          # And the rule really is unchanged, which is what the strip just promised.
          Gori::Settings.colormarker_rules.map(&.match_filter).should eq(["status:500"])
        end
      end
    end
  end

  # The other half of the contract: false must mean "refused", not "any of the paths that
  # return", so a committed edit still closes the card.
  it "commits an edited global rule and closes the form" do
    with_globals do
      with_colormarker_controller do |ctl, host, _session|
        with_own_settings do
          seed_global_rule
          ctl.apply_color_rule(typed_edit_form).should be_true
          host.statuses.should be_empty
          Gori::Settings.colormarker_rules.map(&.match_filter).should eq(["status:503"])
        end
      end
    end
  end
end
