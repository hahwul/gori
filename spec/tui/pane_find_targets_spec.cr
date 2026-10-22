require "../spec_helper"
require "../support/fake_host"
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
    yield FakeHost.new(session, :jwt)
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
