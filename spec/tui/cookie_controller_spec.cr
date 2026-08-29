require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# The Cookie tab is the JWT tab's sibling for framework signed session cookies. These exercise
# the controller end to end — decode, live verify, crack over the SECRET field, the FORGE lens,
# and the session lifecycle — driving it through key events and reading the result back off a
# rendered screen, the way jwt_lens_chip_spec does.
private W = 100
private H =  40

# A golden Flask cookie minted by the real library under this secret (the same vector
# cookie_spec.cr verifies against). {"user_id":42,"admin":true,"name":"alice"}
private SECRET = "s3cr3t-key"
private FLASK  = "eyJ1c2VyX2lkIjo0MiwiYWRtaW4iOnRydWUsIm5hbWUiOiJhbGljZSJ9.am71Yg.gd2MWkbBsGdhg4rScrYWBdGoj-Q"

# The narrow shell facade a controller is given, inert except `session` + `status` — copied from
# jwt_copy_selection_spec (Host is ~35 abstract methods; a shared double is one more file to keep
# in sync with it).
private class FakeHost
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
    :cookie
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

private COOKIE_CA = File.tempname("gori-cookie-ca")
Spec.after_suite { FileUtils.rm_rf(COOKIE_CA) }

private def with_cookie_controller(&)
  root = File.tempname("gori-cookie")
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("cookie")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(COOKIE_CA), Gori::Verbs.registry, project)
    host = FakeHost.new(session)
    yield CookieController.new(host), host
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

# Type a literal string into whatever pane currently has focus, one printable key at a time.
# The controller reads `ev.char` first (a non-special key value is only a fallback), so the
# LowerA carrier here is inert — every printable char is delivered through `char:`.
private def type(ctl : CookieController, text : String) : Nil
  text.each_char { |c| ctl.handle_body_key(key(Termisu::Input::Key::LowerA, char: c)) }
end

private def render(ctl : CookieController) : MemoryBackend
  b = MemoryBackend.new(W, H)
  ctl.render_body(Screen.new(b), Rect.new(0, 0, W, H), :body)
  b
end

private def screen_has?(b : MemoryBackend, text : String) : Bool
  (0...H).any? { |y| b.row(y).includes?(text) }
end

describe "Gori::Tui::CookieController" do
  describe "decode" do
    it "parses a cookie seeded via cookie_from_text and labels the chip by format" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        # The strip chip is derived from the detected format.
        ctl.subtab_labels.last.should contain("flask")
        # The DECODED pane shows the parsed parts.
        b = render(ctl)
        screen_has?(b, "format: flask").should be_true
      end
    end
  end

  describe "verify" do
    it "reports the live verdict for the SECRET candidate against the cookie" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        ctl.focus_last # DECODE panes end on :secret
        type(ctl, SECRET)
        screen_has?(render(ctl), "✓ verified").should be_true
      end
    end

    it "reports a bad key when the candidate does not sign the cookie" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        ctl.focus_last
        type(ctl, "wrong-key")
        screen_has?(render(ctl), "✗ bad key").should be_true
      end
    end
  end

  describe "crack" do
    it "finds the planted secret in a comma-separated candidate list and fills the field" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        ctl.focus_last # :secret
        type(ctl, "foo,#{SECRET},bar")
        ctl.crack
        b = render(ctl)
        # On a hit the SECRET card announces the crack and the field holds the winning secret.
        screen_has?(b, "cracked").should be_true
        screen_has?(b, SECRET).should be_true
      end
    end

    it "leaves a not-found status when no candidate verifies" do
      with_cookie_controller do |ctl, host|
        ctl.cookie_from_text(FLASK)
        ctl.focus_last
        type(ctl, "nope1,nope2")
        ctl.crack
        (host.statuses.last? || "").should contain("no candidate")
      end
    end

    # `c` reaches crack from the FORGE OUTPUT pane too (both are read panes); cracking there
    # would silently crack the hidden DECODE input and swap out the OUTPUT's signing secret.
    it "refuses to crack from the FORGE lens" do
      with_cookie_controller do |ctl, host|
        ctl.cookie_from_text(FLASK)
        ctl.toggle_mode # → FORGE
        ctl.crack
        (host.statuses.last? || "").should contain("DECODE lens")
      end
    end

    # The green "cracked" verdict must not outlive a failing verify: change the salt after a
    # crack and the Flask signature no longer verifies, so the card flips to ✗ bad key.
    it "drops the cracked verdict when a later salt change stops the key verifying" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        ctl.focus_last # :secret
        type(ctl, "x,#{SECRET}")
        ctl.crack
        screen_has?(render(ctl), "cracked").should be_true
        ctl.focus_first     # :input
        ctl.pane_advance(1) # :decoded
        ctl.pane_advance(1) # :opts (salt field)
        type(ctl, "wrong-salt")
        b = render(ctl)
        screen_has?(b, "cracked").should be_false
        screen_has?(b, "bad key").should be_true
      end
    end
  end

  describe "forge lens" do
    it "shows a concrete format in FORGE but keeps auto for a later DECODE paste" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        screen_has?(render(ctl), "^A:auto").should be_true
        ctl.toggle_mode
        ctl.command_section.should eq(:payload) # FORGE panes start on :payload
        # The OPTIONS badge resolves to a concrete format (FORGE can't mint under `auto`)…
        screen_has?(render(ctl), "^A:flask").should be_true
        ctl.toggle_mode
        # …but the pinned format is untouched, so a later paste of another framework's cookie
        # still auto-detects instead of being decoded under a format FORGE silently pinned.
        screen_has?(render(ctl), "^A:auto").should be_true
      end
    end

    it "re-signs an edited payload into a cookie that verifies under the same secret" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        ctl.toggle_mode # → FORGE, format flask, pane :payload
        type(ctl, %({"admin":true}))
        ctl.focus_last       # FORGE panes end on :output; step back to :secret
        ctl.pane_advance(-1) # :output → :secret
        type(ctl, SECRET)
        # Read the forged cookie straight from the controller's copy path and verify it: an
        # edited payload re-signed under a known secret must produce a cookie the engine accepts.
        forged = forge_output(ctl)
        forged.should_not be_empty
        Gori::Cookie.verify(forged, SECRET, "flask").should be_true
      end
    end
  end

  describe "format cycling" do
    it "steps auto → flask → rack → django in the DECODE lens" do
      with_cookie_controller do |ctl|
        ctl.cookie_from_text(FLASK)
        screen_has?(render(ctl), "^A:auto").should be_true
        ctl.cycle_format
        screen_has?(render(ctl), "^A:flask").should be_true
        ctl.cycle_format
        screen_has?(render(ctl), "^A:rack").should be_true
        ctl.cycle_format
        screen_has?(render(ctl), "^A:django").should be_true
      end
    end
  end

  describe "session lifecycle" do
    it "opens and closes sub-tab sessions, keeping at least one" do
      with_cookie_controller do |ctl|
        ctl.subtab_labels.size.should eq(1)
        ctl.cookie_new
        ctl.subtab_labels.size.should eq(2)
        ctl.cookie_close
        ctl.subtab_labels.size.should eq(1)
        ctl.cookie_close # never drops below one
        ctl.subtab_labels.size.should eq(1)
      end
    end
  end
end

# Read the forged OUTPUT cookie out of the controller without touching the clipboard: move focus
# to the OUTPUT pane and ask the unified copy for that pane's text.
private def forge_output(ctl : CookieController) : String
  ctl.focus_last # FORGE → :output
  ctl.cookie_copy_text
end
