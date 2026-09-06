require "../spec_helper"

# A minimal `Gori::Tui::Host` for specs that need to drive a CONTROLLER rather than a view.
#
# Shared because the distinction matters and has already cost a bug: a controller's wiring —
# which key reaches which reload, which sub-tab transition refreshes what — is invisible to a
# spec that calls the view's methods directly. Two live defects in the Activity pane (a filter
# release that never re-queried, and a sub-tab entry that never refreshed) shipped green under
# view-level specs for exactly that reason.
#
# Records `status` so a spec can assert on the toast a controller path produced.
class FakeHost
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

  getter sitemap_opens = 0

  def sitemap_open_flow : Nil
    @sitemap_opens += 1
  end

  # The three cross-tab ↵ bodies a row's double-click reaches through the Host (see
  # `Host#activity_open`) — counted, like `sitemap_open_flow`, so a spec can tell the gesture
  # reached the seam without a Runner.
  getter activity_opens = 0
  getter discover_opens = 0
  getter diff_comparer_sends = 0

  def activity_open : Nil
    @activity_opens += 1
  end

  def discover_open_flow : Nil
    @discover_opens += 1
  end

  def diff_to_comparer : Nil
    @diff_comparer_sends += 1
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

  # The rule EDITORS a row's ↵ / double-click asks the shell to raise — recorded, so a spec can
  # tell the gesture reached the request without a Runner to build the form.
  getter scope_rule_edits = [] of Int64?
  getter custom_rule_edits = [] of Gori::Probe::CustomRule?

  def open_scope_rule_editor(edit_id : Int64?, kind : String, match_type : String, pattern : String) : Nil
    @scope_rule_edits << edit_id
  end

  def open_custom_rule_editor(rule : Gori::Probe::CustomRule?) : Nil
    @custom_rule_edits << rule
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

  # Recorded BEFORE the action runs, so a spec can ask whether a destructive path went through
  # a prompt at all and what that prompt SAID — the two halves of a wipe's contract that a
  # "did the rows go" assertion cannot see. `action.call` keeps every existing caller's
  # behaviour: the dialog is not what those examples are about.
  getter confirms = [] of {String, String}

  def confirm(title : String, message : String, *, confirm_label : String, danger : Bool,
              return_to : Symbol = :none, &action : -> Nil) : Nil
    @confirms << {title, message}
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
