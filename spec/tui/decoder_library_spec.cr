require "../spec_helper"
require "file_utils"

include Gori::Tui

# The Decoder's named-chain LIBRARY is global (settings.json `decoder.chains`) and every saved
# name is callable as a chain step — so one ^S or one ^X in the picker changes what a spec
# means in every open conversion at once, not just the one on screen. These pin the two things
# that used to be left behind by that: the other sub-tabs' cached results, and a saved name
# that no spec could ever reach.

private class DecoderLibHost
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
    :jwt
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

private DECODER_LIB_CA = File.tempname("gori-decoder-lib-ca")
Spec.after_suite { FileUtils.rm_rf(DECODER_LIB_CA) }

private def with_decoder_host(&)
  root = File.tempname("gori-decoder-lib")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("decoderlib")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(DECODER_LIB_CA), Gori::Verbs.registry, project)
    yield DecoderLibHost.new(session)
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe Gori::Tui::DecoderController do
  describe "#save_chain" do
    it "stores the name STRIPPED, so the library row matches the token that resolves it" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.load_chain("seed", "base64-encode")
        dc.save_chain("  peel  ")
        Gori::Settings.decoder_chains.map(&.[0]).should eq ["peel"]
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end

    # `Registry.normalize` folds a whitespace-only name to "", which `Library.register_all`
    # skips — so this used to report "saved chain" and leave an entry nothing could call.
    it "refuses a name that is only whitespace" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.load_chain("seed", "base64-encode")
        dc.save_chain("   ")
        Gori::Settings.decoder_chains.should be_empty
        host.statuses.last.should contain("chain name required")
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end
  end

  describe "#library_changed" do
    # The sub-tab that is NOT on screen holds a cached ChainResult. Saving the very name it
    # calls used to leave it reading "✗ myenc: unknown converter" until some unrelated
    # keystroke in it happened to re-run the chain.
    it "re-derives every open conversion when a name starts resolving" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.decoder_from_text("hi")     # sub-tab that calls the not-yet-saved name
        dc.load_chain("call", "myenc") # → "✗ myenc: unknown converter"
        first = dc.subtab_index

        dc.decoder_new # a second conversion, where the save happens
        dc.load_chain("def", "base64-encode")
        dc.save_chain("myenc")

        dc.jump_subtab(first)
        dc.output_search_lines("unknown converter").should be_empty
        dc.output_search_lines("aGk=").should eq [0]
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end
  end
end
