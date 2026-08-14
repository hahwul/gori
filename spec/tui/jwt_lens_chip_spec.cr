require "../spec_helper"
require "../support/memory_backend"
require "file_utils"

include Gori::Tui

# The JWT tab's two lenses are complete workbenches, so neither one showed that the other
# existed: `^T` was named in Help and in the status footer and nowhere on the panes. The chip
# rides the TOP card of each lens — INPUT in DECODE, HEADER in ENCODE — and is clickable, so
# the draw and `JwtView#lens_chip_hit` must agree cell for cell.
private W     = 100
private H     =  34
private TOKEN = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhIn0.sig"

private def render_lens(mode : Symbol, *, insert : Bool = false, chord : String = "^T",
                        w : Int32 = W, h : Int32 = H) : {JwtView, MemoryBackend, Rect}
  view = JwtView.new
  b = MemoryBackend.new(w, h)
  rect = Rect.new(0, 0, w, h)
  if mode == :decode
    view.render_decode(Screen.new(b), rect,
      input: TextArea.new(TOKEN),
      input_mode: insert ? InputMode::Insert : InputMode::Read,
      input_read: TextReadState.new, decoded: "", attacks: [] of Gori::Jwt::Attack,
      pane: :input, focused: true, lens_chord: chord)
  else
    view.render_encode(Screen.new(b), rect,
      header: TextArea.new(%({"alg":"HS256"})), payload: TextArea.new("{}"),
      secret: "", secret_cx: 0, secret_pre: "", alg: "HS256",
      output: "", output_ok: true, pane: :header, focused: true, lens_chord: chord)
  end
  {view, b, rect}
end

# The narrow shell facade a controller is given, inert except `session` + `status`. File-local
# rather than shared, matching `oast_resume_issue_spec` / `rewriter_preview_select_spec`: `Host`
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
private JWT_CHIP_CA = File.tempname("gori-jwt-chip-ca")
Spec.after_suite { FileUtils.rm_rf(JWT_CHIP_CA) }

# A JWT controller rendered once into a 100x40 screen, so the chip's real screen position —
# frame, sub-tab strip and all — is what the click is aimed at.
private def with_jwt_controller(&)
  root = File.tempname("gori-jwt-chip")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("jwtchip")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(JWT_CHIP_CA), Gori::Verbs.registry, project)
  begin
    ctl = JwtController.new(FakeHost.new(session))
    ctl.jwt_from_text(TOKEN) # a seeded sub-tab, so the panes hold text a gesture can reach
    yield ctl, ->(b : MemoryBackend) do
      ctl.render_body(Screen.new(b), Rect.new(0, 0, W, 40), :body)
    end
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe "JWT lens chip" do
  it "names where ^T GOES on the DECODE lens' top card" do
    _, b, rect = render_lens(:decode)
    card, _, _ = JwtView.new.decode_layout(rect)
    row = b.row(card.y)
    row.should contain("^T:→ENCODE")
    row.should contain("INPUT")
  end

  it "names the way back on the ENCODE lens' top card" do
    _, b, rect = render_lens(:encode)
    card, _, _, _ = JwtView.new.encode_layout(rect)
    row = b.row(card.y)
    row.should contain("^T:→DECODE")
    row.should contain("HEADER")
  end

  it "keeps it off the panes below the top card" do
    # PAYLOAD is the sibling of HEADER through the same `render_json_editor`, and DECODED is
    # the card directly under INPUT: one chip per lens, on the card the eye starts at.
    _, b, rect = render_lens(:encode)
    _, pay_c, _, _ = JwtView.new.encode_layout(rect)
    b.row(pay_c.y).should_not contain("^T:")

    _, b2, rect2 = render_lens(:decode)
    _, dec_c, atk_c = JwtView.new.decode_layout(rect2)
    b2.row(dec_c.y).should_not contain("^T:")
    b2.row(atk_c.y).should_not contain("^T:")
  end

  it "chains clear of INPUT's READ/INS chip instead of over it" do
    # The failure this rules out is the Fuzzer's shipped `↵: §2`: a second badge drawn INSIDE
    # the mode chip, destroying it and leaving both unreadable.
    {false, true}.each do |insert|
      _, b, rect = render_lens(:decode, insert: insert)
      card, _, _ = JwtView.new.decode_layout(rect)
      row = b.row(card.y)
      mode = Frame.mode_badge_label(insert).strip
      row.should contain(mode)
      row.should contain("^T:→ENCODE")
      row.index("^T:→ENCODE").not_nil!.should be < row.index(mode).not_nil!
    end
  end

  it "hit-tests exactly the cells it drew, on both lenses" do
    {
      {:decode, "^T:→ENCODE", ->(r : Rect) { JwtView.new.decode_layout(r)[0] }},
      {:encode, "^T:→DECODE", ->(r : Rect) { JwtView.new.encode_layout(r)[0] }},
    }.each do |(mode, label, layout)|
      view, b, rect = render_lens(mode)
      card = layout.call(rect)
      hits = (0...W).select { |x| view.lens_chip_hit(card, x, card.y, mode, "^T") }
      hits.should_not be_empty
      # ` chord:NAME ` — the drawn run plus its two padding cells.
      (hits.last - hits.first + 1).should eq(label.size + 2)
      at = b.row(card.y).index(label).not_nil!
      hits.should contain(at)
      hits.should contain(at + label.size - 1)
      hits.should_not contain(at - 2) # left of the pad
      hits.should_not contain(at + label.size + 1)
      # Only the border row answers.
      view.lens_chip_hit(card, at, card.y + 1, mode, "^T").should be_false
    end
  end

  it "does not overlap the mode chip's own hit rect" do
    view, _, rect = render_lens(:decode)
    card, _, _ = JwtView.new.decode_layout(rect)
    (0...W).each do |x|
      next unless Frame.mode_badge_hit(x, card.y, card.y, card.right - 1, card.x + JwtView::INPUT_MIN_X, false)
      view.lens_chip_hit(card, x, card.y, :decode, "^T").should be_false
    end
  end

  it "follows a rebound chord in both the label and the hit rect" do
    # `JwtController` resolves the chord through the keymap, so the chip must not hardcode
    # its own width either — the footer and the chip name the same key.
    view, b, rect = render_lens(:decode, chord: "⌥E")
    card, _, _ = JwtView.new.decode_layout(rect)
    row = b.row(card.y)
    row.should contain("⌥E:→ENCODE")
    row.should_not contain("^T:")
    at = row.index("⌥E:→ENCODE").not_nil!
    view.lens_chip_hit(card, at, card.y, :decode, "⌥E").should be_true
  end

  # The whole point of a chip over a footer line is that it can be pressed. These aim at the
  # cell the FULL tab render (frame + sub-tab strip) actually put the label on.
  describe "clicked on the real screen" do
    it "switches the lens both ways, from the chip's own cells" do
      with_jwt_controller do |ctl, draw|
        rect = Rect.new(0, 0, W, 40)
        b = MemoryBackend.new(W, 40)
        draw.call(b)
        y = (0...40).find { |r| b.row(r).includes?("^T:→ENCODE") }.not_nil!
        x = b.row(y).index("^T:→ENCODE").not_nil!
        ctl.handle_click(rect, x + 1, y)

        b2 = MemoryBackend.new(W, 40)
        draw.call(b2)
        b2.contains?("PAYLOAD").should be_true # the ENCODE lens is on screen …
        b2.contains?("^T:→DECODE").should be_true

        y2 = (0...40).find { |r| b2.row(r).includes?("^T:→DECODE") }.not_nil!
        x2 = b2.row(y2).index("^T:→DECODE").not_nil!
        ctl.handle_click(rect, x2 + 1, y2)

        b3 = MemoryBackend.new(W, 40)
        draw.call(b3)
        b3.contains?("ATTACKS").should be_true # … and back
        b3.contains?("^T:→ENCODE").should be_true
      end
    end

    it "leaves the lens alone for a click anywhere else on the card" do
      with_jwt_controller do |ctl, draw|
        rect = Rect.new(0, 0, W, 40)
        b = MemoryBackend.new(W, 40)
        draw.call(b)
        y = (0...40).find { |r| b.row(r).includes?("^T:→ENCODE") }.not_nil!
        x = b.row(y).index("^T:→ENCODE").not_nil!

        ctl.handle_click(rect, x - 3, y)     # bare border, left of the chip's pad
        ctl.handle_click(rect, x + 2, y + 2) # the INPUT body — a caret click

        b2 = MemoryBackend.new(W, 40)
        draw.call(b2)
        b2.contains?("^T:→ENCODE").should be_true # still the DECODE lens
        b2.contains?("PAYLOAD").should be_false
      end
    end

    # The shell arms a drag on ANY body press and re-resolves the target on each motion, so
    # after the chip's press flipped the lens the next twitch used to open a selection in
    # HEADER — a pane the operator had not clicked. Same root cause as a double-tap on the
    # chip taking a word out of it.
    it "arms no text gesture from the chip's own row" do
      with_jwt_controller do |ctl, draw|
        rect = Rect.new(0, 0, W, 40)
        # HEADER has to HOLD something for this to mean anything: an empty editor collapses
        # anchor onto caret, so every assertion below passes on a blank ENCODE side whether
        # the guard is there or not.
        ctl.load_decoded # fills HEADER/PAYLOAD from the token, landing in ENCODE
        b = MemoryBackend.new(W, 40)
        draw.call(b)
        ey = (0...40).find { |r| b.row(r).includes?("^T:→DECODE") }.not_nil!
        ctl.handle_click(rect, b.row(ey).index("^T:→DECODE").not_nil! + 1, ey) # back to DECODE

        b2 = MemoryBackend.new(W, 40)
        draw.call(b2)
        y = (0...40).find { |r| b2.row(r).includes?("^T:→ENCODE") }.not_nil!
        x = b2.row(y).index("^T:→ENCODE").not_nil!

        # First the gesture the guard must NOT cost: a drag inside INPUT still selects.
        ty = (0...40).find { |r| b2.row(r).includes?("eyJ") }.not_nil!
        ctl.handle_click(rect, 3, ty)
        ctl.handle_drag(rect, 9, ty)
        ctl.jwt_selection_active?.should be_true

        ctl.handle_click(rect, x + 1, y) # the chip: → ENCODE
        ctl.handle_drag(rect, x + 2, y)  # the motion that follows that press
        ctl.handle_double_click(rect, x + 1, y).should be_false
        ctl.@sessions[ctl.subtab_index].header.selection?.should be_false
      end
    end

    # The view half of the rebind is covered above by passing a chord straight in — which is
    # exactly what this one does NOT do. Swap `lens_chord` back for a literal `"^T"` in
    # `render_body` and every other example here still passes, while an operator who rebound
    # the switch reads a chip naming a key that does nothing.
    it "paints the chord the keymap actually holds, not the default" do
      Gori::Settings.keymap_overrides = {"jwt.toggle-mode" => ["alt-e"]}
      begin
        with_jwt_controller do |_, draw|
          b = MemoryBackend.new(W, 40)
          draw.call(b)
          b.contains?("⌥E:→ENCODE").should be_true
          b.contains?("^T:→ENCODE").should be_false
        end
      ensure
        Gori::Settings.keymap_overrides = {} of String => Array(String)
      end
    end
  end

  it "drops the chip rather than draw it over the title on a narrow card" do
    # `Frame.toggle_badge` refuses below `min_x`; the hit-test refuses with it, so a narrow
    # pane keeps a plain border instead of a live target on nothing.
    view, b, rect = render_lens(:decode, w: 24)
    card, _, _ = JwtView.new.decode_layout(rect)
    b.row(card.y).should_not contain("→ENCODE")
    (0...24).any? { |x| view.lens_chip_hit(card, x, card.y, :decode, "^T") }.should be_false
  end
end
