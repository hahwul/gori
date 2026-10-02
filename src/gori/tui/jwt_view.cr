require "./workbench_view"
require "./gutter"
require "./viewport"
require "../jwt"

module Gori::Tui
  # The JWT tab's renderer. Two lenses over one session, toggled by the controller:
  #   DECODE — INPUT editor (raw token) → DECODED (live header/payload/sig) → ATTACKS
  #            (the generated testing payloads, one selectable row each).
  #   ENCODE — HEADER + PAYLOAD JSON editors → SECRET field (+ alg badge) → OUTPUT
  #            (the live re-signed token).
  # A pure renderer + layout math + read-only scroll / attack-selection state; the
  # controller owns the editable buffers and the cached decode/encode/attack results
  # (recomputed on edit, never on the render hot path). The INPUT card, the lens chip and
  # the DECODED / OUTPUT text cards are `WorkbenchView`'s.
  class JwtView < WorkbenchView
    SECRET_H = 3 # the SECRET card is a fixed single-line field, framed top + bottom.

    # Left stop for the HEADER card's border chrome: ` HEADER ` ends at card.x + 9 (see
    # `WorkbenchView::INPUT_MIN_X` for the INPUT card's).
    HEADER_MIN_X = 10

    @atk_sel : Int32 = 0
    @atk_scroll : Int32 = 0
    @atk_h : Int32 = 0

    # ---- DECODE lens layout: INPUT (fixed-ish) + DECODED + ATTACKS ----
    def decode_layout(rect : Rect) : {Rect, Rect, Rect}
      empty = Rect.new(rect.x, rect.y, 0, 0)
      return {empty, empty, rect} if rect.h < 9 || rect.w < 2
      input_h = (rect.h * 22 // 100).clamp(3, rect.h - 6)
      rest = rect.h - input_h
      dec_h = rest // 2
      atk_h = rest - dec_h
      y = rect.y
      input = Rect.new(rect.x, y, rect.w, input_h); y += input_h
      dec = Rect.new(rect.x, y, rect.w, dec_h); y += dec_h
      atk = Rect.new(rect.x, y, rect.w, atk_h)
      {input, dec, atk}
    end

    # ---- ENCODE lens layout: HEADER + PAYLOAD + SECRET (fixed) + OUTPUT ----
    def encode_layout(rect : Rect) : {Rect, Rect, Rect, Rect}
      empty = Rect.new(rect.x, rect.y, 0, 0)
      return {empty, empty, empty, rect} if rect.h < 12 || rect.w < 2
      rest = rect.h - SECRET_H
      hdr_h = (rest * 30 // 100).clamp(3, rest - 6)
      pay_h = (rest * 30 // 100).clamp(3, rest - hdr_h - 3)
      out_h = rest - hdr_h - pay_h
      y = rect.y
      hdr = Rect.new(rect.x, y, rect.w, hdr_h); y += hdr_h
      pay = Rect.new(rect.x, y, rect.w, pay_h); y += pay_h
      sec = Rect.new(rect.x, y, rect.w, SECRET_H); y += SECRET_H
      out = Rect.new(rect.x, y, rect.w, out_h)
      {hdr, pay, sec, out}
    end

    # ===================== DECODE lens =====================
    def render_decode(screen : Screen, rect : Rect, *, input : TextArea, input_mode : InputMode,
                      input_read : TextReadState, decoded : String, attacks : Array(Jwt::Attack),
                      input_jwe : Bool = false,
                      pane : Symbol, focused : Bool, lens_chord : String) : Nil
      return if rect.empty?
      input_c, dec_c, atk_c = decode_layout(rect)

      render_input(screen, input_c, input, focused && pane == :input, input_mode, input_read, lens_chord) unless input_c.empty?
      unless dec_c.empty?
        lines = decoded_lines(decoded)
        @dec_lines = lines.size
        @dec_h, @dec_scroll = draw_text_card(screen, dec_c, "DECODED", lines, @dec_scroll, focused && pane == :decoded)
      end
      render_attacks(screen, atk_c, attacks, focused && pane == :attacks, input_jwe) unless atk_c.empty?
    end

    # ===================== ENCODE lens =====================
    def render_encode(screen : Screen, rect : Rect, *, header : TextArea, payload : TextArea,
                      secret : String, secret_cx : Int32, secret_pre : String, alg : String,
                      output : String, output_ok : Bool, pane : Symbol, focused : Bool,
                      lens_chord : String) : Nil
      return if rect.empty?
      hdr_c, pay_c, sec_c, out_c = encode_layout(rect)

      unless hdr_c.empty?
        render_json_editor(screen, hdr_c, "HEADER", header, focused && pane == :header)
        # HEADER is this lens' top card, so it carries the way back — see draw_lens_chip.
        draw_lens_chip(screen, hdr_c, :encode, lens_chord)
      end
      render_json_editor(screen, pay_c, "PAYLOAD", payload, focused && pane == :payload) unless pay_c.empty?
      render_secret(screen, sec_c, secret, secret_cx, secret_pre, alg, focused && pane == :secret) unless sec_c.empty?
      unless out_c.empty?
        out_lines = output_ok ? output.split('\n') : ["✗ #{output}"]
        @out_lines = out_lines.size
        # Just "OUTPUT". The failure is already the body's first line (`✗ <reason>`, in red,
        # two lines below) — the title said a shorter version of the same thing, and a card
        # title is what the card IS, not what state it is in.
        title = "OUTPUT"
        @out_h, @out_scroll = draw_text_card(screen, out_c, title, out_lines, @out_scroll,
          focused && pane == :output, fg: output_ok ? Theme.text : Theme.red)
      end
    end

    private def lens_name(mode : Symbol) : String
      mode == :decode ? "→ENCODE" : "→DECODE"
    end

    private def encode_card_min_x : Int32
      HEADER_MIN_X
    end

    private def decoded_placeholder : String
      "(paste or send a JWT into INPUT to decode)"
    end

    # ---- HEADER / PAYLOAD (editable JSON, always-insert small editors) ----
    private def render_json_editor(screen : Screen, card : Rect, title : String, ed : TextArea, active : Bool) : Nil
      Frame.card(screen, card, title, bg: Theme.bg, border: Frame.pane_border(active))
      ed.render(screen, card.inset(1, 1), cursor: active, highlight: :json, gauge: true, gauge_focused: active)
    end

    # ---- SECRET / KEY single-line field + alg badge ----
    # One field, two meanings, and the title says which: an HS algorithm takes the HMAC
    # secret typed inline, while RS/PS/ES/EdDSA take a PEM key — which is multi-line and so
    # cannot be typed here at all, hence the path placeholder (the engine accepts either).
    private def render_secret(screen : Screen, card : Rect, secret : String, cx : Int32,
                              pre : String, alg : String, active : Bool) : Nil
      pem = Gori::Jwt::Asym.alg?(alg)
      Frame.card(screen, card, pem ? "KEY" : "SECRET", bg: Theme.bg, border: Frame.pane_border(active))
      # ` ^A:ALG ` badge (cycled by jwt.cycle-alg) — lit when a real key matters.
      Frame.toggle_badge(screen, card.right - 1, card.y, card.x + 9,
        key_label("jwt.cycle-alg", "^A"), alg, alg != "none")
      c = card.inset(1, 1)
      return if c.h <= 0
      screen.text(c.x, c.y, "› ", Theme.accent, Theme.bg)
      fg = active ? Theme.text_bright : Theme.text
      vw = {c.w - 2, 1}.max
      empty_hint = pem ? "(path to a PEM private key)" : "(empty key)"
      if alg == "none"
        screen.text(c.x + 2, c.y, "(no secret — alg=none is unsigned)", Theme.muted, Theme.bg, width: vw)
      elsif active
        screen.input_line(c.x + 2, c.y, secret, cx, pre, fg, Theme.bg, width: vw)
      else
        screen.text(c.x + 2, c.y, secret.empty? ? empty_hint : secret, secret.empty? ? Theme.muted : fg, Theme.bg, width: vw)
      end
    end

    # ---- ATTACKS list (one selectable row per generated payload) ----
    private def render_attacks(screen : Screen, card : Rect, attacks : Array(Jwt::Attack),
                               focused : Bool, input_jwe : Bool) : Nil
      Frame.card(screen, card, "ATTACKS", bg: Theme.bg, border: Frame.pane_border(focused))
      Frame.border_meta(screen, card, "ATTACKS", attacks.size.to_s)
      body = card.inset(1, 1)
      return if body.h <= 0
      if attacks.empty?
        # An encrypted token reaches here with a perfectly good JWT in INPUT and no payloads,
        # so "paste a JWT" would be wrong twice: they did, and there is nothing to generate.
        # `input_jwe` is computed once per EDIT beside `attacks` — this pane is empty for the
        # whole time a token is being typed, so deciding it here would parse on every frame.
        screen.text(body.x, body.y, empty_attacks_hint(input_jwe), Theme.muted, Theme.bg, width: body.w)
        return
      end
      @atk_h = body.h
      @atk_sel = @atk_sel.clamp(0, attacks.size - 1)
      # `attacks` is the generated payload list the row loop below indexes. (Clamp-then-follow
      # before; `Viewport` follows then clamps, same offset for an in-range selection — and
      # `@atk_sel` is clamped into range on the line above.)
      @atk_scroll = Viewport.scroll_to_show(@atk_sel, @atk_scroll, body.h, attacks.size)
      (0...body.h).each do |i|
        idx = @atk_scroll + i
        a = attacks[idx]?
        break unless a
        # Dimmed rather than erased when focus leaves this pane — the selection is still the
        # attack ↵ applies, and with the marker gone there was nothing on screen saying which.
        sel = idx == @atk_sel
        y = body.y + i
        bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        screen.fill(Rect.new(body.x, y, body.w, 1), bg) if sel
        x = screen.text(body.x, y, sel ? "▎" : " ", Theme.accent, bg)
        x = screen.text(x, y, a.name, sel ? Theme.text_bright : Theme.text, bg, width: {body.w // 3, 8}.max)
        x = screen.text(x, y, "  ", Theme.muted, bg)
        # A `verified` row is a FINDING, not a payload to go try: its key reproduces the input
        # token's own signature (`Jwt::Attack#verified`). `Theme.red` — the colour
        # `severity_color` gives Critical, which a recovered signing key is — and not
        # `Theme.muted`, which every other row's prose already wears in a pane that is scanned
        # rather than read.
        if a.verified
          x = screen.text(x, y, "✓ ", Theme.red, bg)
        end
        screen.text(x, y, a.note, a.verified ? Theme.red : Theme.muted, bg, width: {body.right - x, 0}.max)
      end
      Frame.scroll_gauge(screen, body, attacks.size, @atk_scroll, focused)
    end

    # ---- attack selection mutators (called by the controller) ----
    def attacks_move(dir : Int32) : Nil
      @atk_sel = {@atk_sel + dir, 0}.max
    end

    def attacks_selected : Int32
      @atk_sel
    end

    # Mouse: the attack index under a click in the ATTACKS card, or nil (past the last row).
    # Mirrors render_attacks' inset → @atk_scroll + i; the list has no header row. The pane
    # drew a cursor and moved it with ↑/↓ and the wheel, and the pointer could not place it.
    def attacks_row_at(card : Rect, my : Int32, count : Int32) : Int32?
      return nil if count <= 0
      body = card.inset(1, 1)
      return nil if body.h <= 0
      i = my - body.y
      return nil if i < 0 || i >= body.h
      idx = @atk_scroll + i
      idx < count ? idx : nil
    end

    # The attack a click on the ATTACKS gauge asks for. `@atk_scroll` is derived from
    # `@atk_sel` by render, so this answers with a selection. See `Frame.scroll_gauge_row`.
    def attacks_gauge_row(card : Rect, mx : Int32, my : Int32, count : Int32) : Int32?
      Frame.scroll_gauge_row(card.inset(1, 1), count, mx, my)
    end

    def select_attack_row(idx : Int32, count : Int32) : Nil
      @atk_sel = idx.clamp(0, {count - 1, 0}.max)
    end

    private def empty_attacks_hint(input_jwe : Bool) : String
      if input_jwe
        "(encrypted JWE — no claims to tamper with, no signature to strip)"
      else
        "(paste a JWT into INPUT to generate testing payloads)"
      end
    end

    # Hit-test the SECRET card's ` ^A:<alg> ` badge. Geometry mirrors render_secret. The
    # Decoder's structurally identical ` ^X:<mode> ` on its OUTPUT card has always answered a
    # click; this one, on the sibling tool tab, did not.
    def secret_alg_hit(card : Rect, mx : Int32, my : Int32, alg : String) : Bool
      !Frame.right_badge_hit(mx, my, card.y, card.right - 1, card.x + 9,
        [{:alg, key_label("jwt.cycle-alg", "^A"), alg}] of {Symbol, String, String}).nil?
    end

    def attacks_at_top? : Bool
      @atk_sel <= 0
    end
  end
end
