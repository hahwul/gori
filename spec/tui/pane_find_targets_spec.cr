require "../spec_helper"
require "file_utils"

include Gori::Tui

# ^G/^F reach a pane only when its controller NAMES it: the shell asks `goto_symbol` for the
# focused pane's symbol and dispatches on that (`runner/search.cr`). Two tabs used to answer
# nil for every pane — the Decoder, whose OUTPUT is the longest derived text in the app, and
# the Fuzzer, whose TEMPLATE is the same captured request the Repeater lets you search.
#
# These pin WHICH pane answers, because that is the whole gate; the find itself is `ReadPane`'s
# and `TextArea`'s, covered by their own specs. The Decoder's replace arm gets an example of
# its own: a write to INPUT that skips `touch` leaves OUTPUT showing the chain's answer for the
# text that was there BEFORE the replace, which reads as a real decode.
private class PaneFindHost
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

private PANE_FIND_CA = File.tempname("gori-pane-find-ca")
Spec.after_suite { FileUtils.rm_rf(PANE_FIND_CA) }

private def with_pane_find_host(&)
  root = File.tempname("gori-pane-find")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("panefind")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(PANE_FIND_CA), Gori::Verbs.registry, project)
    yield PaneFindHost.new(session)
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "Gori::Tui::DecoderController ^G/^F targets" do
  describe "#goto_symbol" do
    it "names the INPUT editor while INPUT has focus" do
      with_pane_find_host do |host|
        dc = DecoderController.new(host)
        dc.focus_first
        dc.goto_symbol.should eq(:decoder_input)
      end
    end

    it "names the OUTPUT pane while OUTPUT has focus" do
      with_pane_find_host do |host|
        dc = DecoderController.new(host)
        dc.focus_last
        dc.goto_symbol.should eq(:decoder_output)
      end
    end

    # The CHAIN is one line ("base64 > sha256"), so go-to-line has nothing to reach and a
    # find prompt would cover more of the screen than the text it searches.
    it "names nothing while the CHAIN field has focus" do
      with_pane_find_host do |host|
        dc = DecoderController.new(host)
        dc.focus_first
        dc.pane_advance(1).should be_true # input -> chain
        dc.goto_symbol.should be_nil
      end
    end
  end

  describe "#output_search_lines" do
    it "searches the OUTPUT as displayed" do
      with_pane_find_host do |host|
        dc = DecoderController.new(host)
        dc.decoder_from_text("aGVsbG8gc2VjcmV0IHdvcmxk") # "hello secret world"
        dc.load_chain("b64", "base64-decode")
        dc.output_search_lines("secret").should eq([0])
        dc.output_search_lines("absent").should be_empty
      end
    end
  end

  describe "#input_replace_matches" do
    # The guard this method exists for: every other INPUT write goes through `touch`
    # (dirty + re-run the chain), so a replace that skipped it would leave OUTPUT showing
    # the decode of the PRE-replace text — a stale answer that looks like a real one.
    it "re-runs the chain, so OUTPUT reflects the replaced INPUT" do
      with_pane_find_host do |host|
        dc = DecoderController.new(host)
        dc.decoder_from_text("hello secret world")
        dc.load_chain("up", "upper")
        dc.output_search_lines("SECRET").should eq([0])

        dc.input_replace_matches("secret", "public").should eq(1)
        dc.input_area.text.should eq("hello public world")
        dc.output_search_lines("PUBLIC").should eq([0])
        dc.output_search_lines("SECRET").should be_empty
      end
    end

    it "reports 0 and leaves the buffer alone when nothing matches" do
      with_pane_find_host do |host|
        dc = DecoderController.new(host)
        dc.decoder_from_text("hello world")
        dc.input_replace_matches("nope", "x").should eq(0)
        dc.input_area.text.should eq("hello world")
      end
    end
  end
end

describe "Gori::Tui::FuzzerController ^G/^F targets" do
  describe "#goto_symbol" do
    it "names nothing with no session open" do
      with_pane_find_host do |host|
        FuzzerController.new(host).goto_symbol.should be_nil
      end
    end

    it "names the TEMPLATE editor while TEMPLATE has focus" do
      with_pane_find_host do |host|
        fc = FuzzerController.new(host)
        fc.fuzz_new
        v = fc.current_view.not_nil!
        v.focus_pane(:template)
        fc.goto_symbol.should eq(:fuzz_template)
      end
    end

    # TARGET is one line, CONFIG is a form and RESULTS is a table the tab narrows with its
    # own sort + matched-only rather than a text find.
    it "names nothing on TARGET, CONFIG or RESULTS" do
      with_pane_find_host do |host|
        fc = FuzzerController.new(host)
        fc.fuzz_new
        v = fc.current_view.not_nil!
        {:target, :config, :results}.each do |pane|
          v.focus_pane(pane)
          fc.goto_symbol.should be_nil
        end
      end
    end
  end
end
