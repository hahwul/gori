require "../spec_helper"
require "file_utils"
require "../support/memory_backend"
require "../support/memory_backend"

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

  def apply_project_protos(spec : String) : String
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

# ---- defects a review of the controller found ----------------------------------------

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private def shift(k : Termisu::Input::Key) : Termisu::Event::Key
  Termisu::Event::Key.new(k, Termisu::Input::Modifier::Shift)
end

# The body rect a click is hit-tested against (protected on the controller).
class Gori::Tui::DecoderController
  def body_rect_for_spec(rect : Gori::Tui::Rect) : Gori::Tui::Rect
    body_rect_below_filter(rect)
  end
end

describe Gori::Tui::DecoderController do
  describe "#on_enter" do
    # `on_enter` used to recompute with hooks ON and reset the OUTPUT pane: a persisted
    # `exec:` conversion the project open had held then ran its command the moment the tab
    # was pressed, and a selection left in OUTPUT was thrown away by a round trip elsewhere.
    it "neither runs a held exec: step nor disturbs the OUTPUT caret" do
      with_decoder_host do |host|
        seed = DecoderController.new(host)
        seed.input_area.set_text("hi")
        seed.load_chain("cat", "exec:/bin/cat") # the keystroke recompute ran it: OUTPUT "hi"
        seed.decoder_new
        seed.commit
        dc = DecoderController.new(host) # a project open: sub-tab 0 is restored HELD
        dc.output_search_lines("held").should eq [0]
        dc.on_enter
        dc.output_search_lines("held").should eq [0] # entering the tab did not run it

        dc.jump_subtab(1)
        dc.input_area.set_text("l1\nl2\nl3")
        dc.load_chain("id", "lower") # recomputes over the new text: a 3-line OUTPUT
        dc.focus_last                # OUTPUT
        dc.handle_body_key(key(Termisu::Input::Key::Down))
        dc.handle_body_key(shift(Termisu::Input::Key::Down))
        dc.decoder_selection_active?.should be_true
        dc.on_enter
        dc.decoder_selection_active?.should be_true
      end
    end
  end

  describe "INPUT ⇧↑ / ⇧↓" do
    it "select in INS instead of moving, and never leave the pane" do
      with_decoder_host do |host|
        dc = DecoderController.new(host)
        dc.input_area.set_text("one\ntwo")
        dc.handle_body_key(key(Termisu::Input::Key::LowerI, char: 'i')) # INS
        dc.handle_body_key(shift(Termisu::Input::Key::Down))
        dc.input_area.selection?.should be_true
        dc.goto_symbol.should eq :decoder_input # ⇧↓ on the last line stayed put
        dc.handle_body_key(shift(Termisu::Input::Key::Down))
        dc.goto_symbol.should eq :decoder_input
      end
    end

    it "extend a READ selection to the buffer edge rather than leaving the pane" do
      with_decoder_host do |host|
        dc = DecoderController.new(host)
        dc.input_area.set_text("one\ntwo")
        dc.handle_body_key(shift(Termisu::Input::Key::Down))
        dc.decoder_selection_active?.should be_true
        dc.handle_body_key(shift(Termisu::Input::Key::Down)) # already on the last line
        dc.goto_symbol.should eq :decoder_input
        dc.handle_body_key(shift(Termisu::Input::Key::Up))
        dc.handle_body_key(shift(Termisu::Input::Key::Up)) # first line: no jump to the strip
        dc.goto_symbol.should eq :decoder_input
      end
    end
  end

  describe "#save_chain" do
    it "refuses an exec:-prefixed name, which the chain grammar would run as a command" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.load_chain("seed", "upper")
        dc.save_chain("exec:mytool")
        Gori::Settings.decoder_chains.should be_empty
        host.statuses.last.should contain("exec:")
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end

    it "refuses to save an empty chain (a step that would be the identity)" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.save_chain("blank")
        Gori::Settings.decoder_chains.should be_empty
        host.statuses.last.should contain("empty")
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end
  end

  describe "#library_changed" do
    # The re-derive withheld hooks for EVERY session, the one on screen included — so the
    # ^S that saved a chain replaced the decode the operator was reading with "chain held".
    it "keeps running the ACTIVE conversion's exec: step" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.input_area.set_text("hi")
        dc.load_chain("cat", "exec:/bin/cat")
        dc.output_search_lines("hi").should eq [0]
        dc.save_chain("catchain")
        dc.output_search_lines("hi").should eq [0]
        dc.output_search_lines("held").should be_empty
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end

    # A restored, HELD exec: conversation stays held through a library edit — the hold a
    # project open put on it is lifted by an edit in that conversation, not by a ^S elsewhere.
    it "does not lift a held conversation's exec: step when it becomes the active sub-tab" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.input_area.set_text("hi")
        dc.load_chain("cat", "myenc > exec:/bin/cat") # myenc unknown → stops before the exec
        dc.decoder_new                                # sub-tab 1 active
        dc.load_chain("def", "lower")
        dc.save_chain("myenc") # sub-tab 0 re-derived hooks-off: myenc resolves, exec held
        dc.jump_subtab(0)
        dc.output_search_lines("held").should eq [0]
        # A picker ^X on an unrelated entry with sub-tab 0 ACTIVE re-derives it (it names a
        # saved chain) — but the hold stands: still held, no fork.
        Gori::Settings.decoder_chains = Gori::Settings.decoder_chains + [{"other", "upper"}]
        dc.library_changed
        dc.output_search_lines("held").should eq [0]
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end

    it "does not run the active conversation's exec: step for a gesture made elsewhere" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.input_area.set_text("hi")
        dc.load_chain("def", "upper")
        dc.save_chain("myenc")
        dc.load_chain("call", "myenc > exec:/bin/cat") # ran: OUTPUT "HI"
        dc.output_search_lines("HI").should eq [0]
        Gori::Settings.decoder_chains = [] of {String, String} # a factory reset empties the library…
        dc.library_changed(run_active_hooks: false)            # …from another tab: no fork
        dc.output_search_lines("unknown converter").should eq [0]
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end

    it "leaves a conversation no library edit can affect exactly as it is" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.input_area.set_text("hi")
        dc.load_chain("cat", "exec:/bin/cat") # ran: OUTPUT "hi"
        dc.decoder_new
        dc.load_chain("def", "lower")
        dc.save_chain("other")
        dc.jump_subtab(0)
        dc.output_search_lines("hi").should eq [0] # not re-derived, so not held either
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end

    # A recipe change that moves an INTERMEDIATE while the final answer stays the same still
    # refreshes the PIPELINE previews (they are cached now).
    it "refreshes the PIPELINE previews when only an intermediate moved" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.input_area.set_text("hi")
        dc.load_chain("def", "upper")
        dc.save_chain("myenc")
        dc.load_chain("call", "myenc > zzz") # step 1 HI, step 2 unknown
        backend = MemoryBackend.new(80, 30)
        dc.render_body(Screen.new(backend), Rect.new(0, 0, 80, 30), :body)
        backend.contains?("myenc › HI").should be_true
        dc.decoder_new
        dc.load_chain("def", "lower")
        dc.save_chain("myenc")
        dc.jump_subtab(0)
        backend = MemoryBackend.new(80, 30)
        dc.render_body(Screen.new(backend), Rect.new(0, 0, 80, 30), :body)
        backend.contains?("myenc › hi").should be_true
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end

    # nil → nil: a failure that became a DIFFERENT failure kept the OUTPUT card on the old
    # error text while the PIPELINE beside it showed the new one.
    it "redraws an OUTPUT whose failure changed even though its bytes (none) did not" do
      with_decoder_host do |host|
        Gori::Settings.decoder_chains = [] of {String, String}
        dc = DecoderController.new(host)
        dc.load_chain("call", "myenc > zzz")
        dc.output_search_lines("myenc: unknown").should eq [0]
        dc.decoder_new
        dc.load_chain("def", "base64-encode")
        dc.save_chain("myenc")
        dc.jump_subtab(0)
        dc.output_search_lines("myenc: unknown").should be_empty
        dc.output_search_lines("zzz: unknown").should eq [0]
      ensure
        Gori::Settings.decoder_chains = [] of {String, String}
      end
    end
  end

  describe "#apply_rename" do
    it "persists the new name at once, not at the next leave" do
      with_decoder_host do |host|
        dc = DecoderController.new(host)
        dc.apply_rename(dc.view_at(0).not_nil!, "peel")
        raw = host.session.store.setting(Gori::Store::DECODER_SESSIONS_KEY).not_nil!
        DecoderSessions.parse(raw).first[2].should eq "peel"
      end
    end
  end

  describe "sub-tab filter" do
    it "is dropped by ^N, which would otherwise land on a chip the strip does not draw" do
      with_decoder_host do |host|
        dc = DecoderController.new(host)
        dc.apply_rename(dc.view_at(0).not_nil!, "alpha")
        dc.decoder_new
        dc.apply_rename(dc.view_at(1).not_nil!, "beta")
        dc.start_subtab_filter
        "alpha".each_char { |c| dc.handle_subtab_filter_key(key(Termisu::Input::Key::LowerA, char: c)) }
        dc.subtab_hidden.not_nil!.should contain(1)
        dc.decoder_new
        dc.subtab_hidden.should be_nil
        dc.subtab_index.should eq 2
      end
    end
  end

  describe "copy from the CHAIN pane" do
    it "copies the OUTPUT, as the chain footer's ^Y has always promised" do
      with_decoder_host do |host|
        dc = DecoderController.new(host)
        dc.input_area.set_text("hi")
        dc.load_chain("b", "base64-encode")
        dc.pane_advance(1) # CHAIN
        dc.goto_symbol.should be_nil
        dc.decoder_copy_all
        host.statuses.last.should contain("copied all (4b)") # "aGk=", not the 13-char spec
      end
    end
  end

  describe "a click into a scrolled CHAIN field" do
    it "lands the caret on the character under the pointer, rebased by the window" do
      with_decoder_host do |host|
        dc = DecoderController.new(host)
        chain = "base64-decode > url-decode > json-unescape > sha256 > hex-encode > upper > reverse > lower"
        dc.load_chain("long", chain) # caret at the end → the field is scrolled
        dc.pane_advance(1)
        rect = Rect.new(0, 0, 80, 30)
        regions = dc.view_at(0).not_nil!.layout(dc.body_rect_for_spec(rect))
        field = regions.chain.inset(1, 1)
        off, _ = dc.view_at(0).not_nil!.chain_window(regions.chain, chain, chain.size, "")
        off.should be > 0
        # Click the 5th visible column: caret = off + 5, not 5.
        dc.handle_click(rect, field.x + 2 + 5, field.y)
        dc.handle_body_key(key(Termisu::Input::Key::LowerA, char: '#'))
        dc.chain_spec.should eq chain[0, off + 5] + "#" + chain[(off + 5)..]
      end
    end
  end
end
