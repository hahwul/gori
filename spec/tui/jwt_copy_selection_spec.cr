require "../spec_helper"
require "file_utils"

include Gori::Tui

# `JwtController#jwt_copy` is the whole of `^Y` on this tab: `Runner#read_copy` routes `:jwt`
# straight here, with none of the `read_selection_active? ? copy : copy_all` branch its six
# siblings get. So the selection-vs-whole-pane decision is this one method's — and it used to
# make it for exactly one of the four editors.
#
#   * INPUT in INS copied `s.input.text`, the WHOLE token, while `jwt_selection_active?` was
#     reporting the ⇧arrow band as live. That is the split `RepeaterView#pane_selection?`
#     documents in its own comment: claim a selection, copy something else.
#   * HEADER and PAYLOAD are always-typing `TextArea`s that grow a band through the same
#     `handle_motion_key` and were never asked about one at all — and they are the panes where
#     `^Y` is not the convenient copy but the ONLY one, since a bare `y` types a `y` there.
#
# The footers now name `⇧arrows select · ^Y copy` on all three (see
# `editor_footer_copy_key_spec`), which is what makes the old behaviour a lie rather than
# merely a gap.

# The narrow shell facade a controller is given, inert except `session` + `status`. File-local
# rather than shared, matching `jwt_lens_chip_spec` / `rewriter_preview_select_spec`: `Host`
# is ~35 abstract methods and a shared double would be one more file to keep in sync with it.
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

# The CA is the one slow part of standing a Session up (a root keypair), and nothing here
# asserts on it, so it is built once for the file.
private JWT_COPY_CA = File.tempname("gori-jwt-copy-ca")
Spec.after_suite { FileUtils.rm_rf(JWT_COPY_CA) }

private def with_jwt_copy_controller(&)
  root = File.tempname("gori-jwt-copy")
  # `begin` opens BEFORE the tree exists, not after `Session.open`: a raise from the store
  # migration, the CA load or the bind would otherwise leave the project directory behind,
  # since the `after_suite` hook above covers only the shared CA. `session` is nilable for
  # the same reason — the ensure runs on a failure that happened before it was assigned.
  session = nil
  begin
    Dir.mkdir_p(root)
    project = Gori::ProjectRegistry.new(root).temp("jwtcopy")
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(JWT_COPY_CA), Gori::Verbs.registry, project)
    yield JwtController.new(FakeHost.new(session))
  ensure
    session.try(&.close)
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

private def key(k : Termisu::Input::Key, mods : Termisu::Input::Modifier = :none,
                char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(k, mods, char)
end

private TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhIn0.sig"

describe "Gori::Tui::JwtController#jwt_copy_text" do
  describe "INPUT in INSERT" do
    it "takes the ⇧arrow band, not the whole token" do
      with_jwt_copy_controller do |ctl|
        ctl.jwt_from_text(TOKEN)
        s = ctl.@sessions[ctl.@idx]
        ctl.handle_body_key(key(Termisu::Input::Key::LowerI, :none, 'i')) # READ → INS
        s.input_mode.should eq(InputMode::Insert)
        5.times { ctl.handle_body_key(key(Termisu::Input::Key::Right, :shift)) }

        s.input.selection_text.should eq("eyJhb")
        ctl.jwt_selection_active?.should be_true # what the space menu is told…
        ctl.jwt_copy_text.should eq("eyJhb")     # …and what the copy now agrees with
      end
    end

    # The other half of "smart copy": with no band there is nothing to narrow to, so the
    # whole pane is the answer — `read_copy` has no `*_copy_all` branch to fall back to here.
    it "takes the whole token when no band is live" do
      with_jwt_copy_controller do |ctl|
        ctl.jwt_from_text(TOKEN)
        ctl.handle_body_key(key(Termisu::Input::Key::LowerI, :none, 'i'))
        ctl.@sessions[ctl.@idx].input.selection?.should be_false
        ctl.jwt_copy_text.should eq(TOKEN)
      end
    end
  end

  # The ENCODE lens has no READ mode: these panes always capture keys, so a bare `y` types a
  # `y` and `^Y` is the only copy they have. They were also the two the case never asked.
  describe "HEADER / PAYLOAD (always typing)" do
    it "takes the band in HEADER" do
      with_jwt_copy_controller do |ctl|
        ctl.jwt_from_text(TOKEN)
        ctl.load_decoded # the operator's route onto this lens: seeds the editors + focuses HEADER
        s = ctl.@sessions[ctl.@idx]
        s.pane.should eq(:header)
        s.header.text.should eq(%({\n  "alg": "HS256"\n}))  # pretty-printed by load_decoded
        ctl.handle_body_key(key(Termisu::Input::Key::Down)) # onto the claim line
        ctl.handle_body_key(key(Termisu::Input::Key::End, :shift))

        s.header.selection_text.should eq(%(  "alg": "HS256"))
        ctl.jwt_copy_text.should eq(%(  "alg": "HS256"))
      end
    end

    it "takes the band in PAYLOAD" do
      with_jwt_copy_controller do |ctl|
        ctl.jwt_from_text(TOKEN)
        ctl.load_decoded
        s = ctl.@sessions[ctl.@idx]
        s.pane = :payload
        3.times { ctl.handle_body_key(key(Termisu::Input::Key::Right, :shift)) }

        band = s.payload.selection_text
        band.should_not be_nil
        ctl.jwt_copy_text.should eq(band)
      end
    end

    it "falls back to the whole editor with no band" do
      with_jwt_copy_controller do |ctl|
        ctl.jwt_from_text(TOKEN)
        ctl.load_decoded
        s = ctl.@sessions[ctl.@idx]
        s.header.selection?.should be_false
        ctl.jwt_copy_text.should eq(s.header.text)
      end
    end
  end
end
