require "./screen"
require "./theme"
require "./frame"
require "./text_area"
require "./input_mode"
require "./text_read_state"
require "../hotkeys"
require "./subtab_marks"

module Gori::Tui
  # What the JWT and Cookie renderers have in common: a two-lens workbench whose DECODE lens
  # opens with an INPUT editor (INS/READ) over a read-only DECODED card, and whose second lens
  # ends in a read-only OUTPUT card. This holds the sub-tab identity (`name`, the mark), the two
  # cards' scroll state, the INPUT card with its READ/INS badge and the lens chip, and the
  # read-only text card both lenses draw from. The lens layouts, the second lens's editors and
  # the SECRET/OPTIONS cards are each tool's own.
  abstract class WorkbenchView
    include SubtabRef # a sub-tab strip may hold a mark on this view (#683)
    @registry : Verb::Registry? = nil
    # Custom sub-tab chip label (nil = derive from the token / cookie); set by rename.
    property name : String? = nil

    def set_registry(registry : Verb::Registry) : Nil
      @registry = registry
    end

    # Left stop for the INPUT card's border chrome. `Frame.card` draws its title as ` TITLE `
    # from card.x + 2, so ` INPUT ` ends at card.x + 8 — one past it is where a right-chained
    # badge may start. The number was a literal 8 in the draw and a second literal 8 in the
    # controller's hit-test, which let the mode badge take the title's last cell at ~17
    # columns; both now read it here.
    INPUT_MIN_X = 9

    @dec_scroll : Int32 = 0
    @dec_h : Int32 = 0
    @dec_lines : Int32 = 0
    @out_scroll : Int32 = 0
    @out_h : Int32 = 0
    @out_lines : Int32 = 0

    # ` →ENCODE ` / ` →FORGE ` — where the lens chip GOES from `mode`.
    private abstract def lens_name(mode : Symbol) : String
    # The left stop for the second lens's top card (HEADER / PAYLOAD), where the chip takes
    # the border's right edge on its own.
    private abstract def encode_card_min_x : Int32
    # The DECODED card's one-line empty state.
    private abstract def decoded_placeholder : String

    # ---- INPUT (editable, INS/READ like the Decoder input) ----
    private def render_input(screen : Screen, card : Rect, input : TextArea, active : Bool,
                             mode : InputMode, read : TextReadState, lens_chord : String) : Nil
      reading = active && mode == InputMode::Read
      insert = active && mode == InputMode::Insert
      Frame.card(screen, card, "INPUT", bg: Theme.bg, border: Frame.pane_border(active))
      # `mode`, not `insert` — the badge states the pane's own mode, and the controller
      # hit-tests exactly that. Gating the draw on `active` (and passing the focus-folded
      # `insert`) left a live 8-cell target on an unpainted border: with focus on another card,
      # clicking the INPUT card's top-right corner toggled insert. See the same fix in
      # notes_view / fuzzer_view; focus stays in the border colour.
      Frame.mode_badge(screen, card.right - 1, card.y, card.x + INPUT_MIN_X, mode == InputMode::Insert)
      # …and the lens chip chains LEFT of it (`draw_lens_chip` re-derives that edge rather
      # than taking this return, so the hit-test can compute it the same way).
      draw_lens_chip(screen, card, :decode, lens_chord, mode == InputMode::Insert)
      body = card.inset(1, 1)
      input.render(screen, body, cursor: insert, gauge: true, gauge_focused: active)
      paint_read_chrome(screen, body, input, read) if reading
    end

    # ---- the lens chip: the ONE control on these tabs with no other trace on screen ----
    # ` ^T:→ENCODE ` on the DECODE lens' INPUT card, ` ^T:→DECODE ` on the second lens' top
    # card — the top card either way, where the eye lands when the tab opens. Each lens is a
    # complete workbench, so nothing inside one said the other existed: `^T` was named in
    # Help and in the footer and nowhere on the panes themselves.
    #
    # The NAME is where `^T` GOES, and the `→` says so. Naming the CURRENT lens — the way
    # the sibling ` ↵:READ ` chip names its own mode — would repeat what the card titles
    # under it already state, and ` ^T:DECODE ` riding a decoding pane reads as "^T decodes
    # this", i.e. as a key that does something else. `chord` comes from the keymap, so a
    # rebind moves this and the footer together — and `lens_chord:` is REQUIRED on both
    # render entry points rather than defaulting to `"^T"`, so a second render path cannot
    # quietly paint the default at someone who rebound the switch.
    #
    # Never lit: a two-way switch has no "on" state to light (the Fuzzer's sort chip passes
    # `false` for the same reason).
    #
    # `{right_edge, min_x}` for the chip. Draw and hit-test both derive from this one pair,
    # so the chip cannot drift off its own click target. On DECODE it chains left of INPUT's
    # READ/INS chip; on the other lens the top card's border carries nothing else, so it
    # takes the edge.
    private def lens_chip_geom(card : Rect, mode : Symbol, insert : Bool) : {Int32, Int32}
      if mode == :decode
        min_x = card.x + INPUT_MIN_X
        {Frame.mode_badge_edge(card.right - 1, min_x, insert), min_x}
      else
        {card.right - 1, card.x + encode_card_min_x}
      end
    end

    private def draw_lens_chip(screen : Screen, card : Rect, mode : Symbol, chord : String,
                               insert : Bool = false) : Nil
      edge, min_x = lens_chip_geom(card, mode, insert)
      Frame.toggle_badge(screen, edge, card.y, min_x, chord, lens_name(mode), false)
    end

    # Hit-test the lens chip on the lens' top card — the controller's `handle_click` runs it
    # for INPUT in DECODE and the top card of the other lens. `insert` is INPUT's REAL mode
    # (the chip chains past a badge whose two labels differ in width), and is unread on the
    # other side.
    def lens_chip_hit(card : Rect, mx : Int32, my : Int32, mode : Symbol, chord : String,
                      insert : Bool = false) : Bool
      edge, min_x = lens_chip_geom(card, mode, insert)
      !Frame.right_badge_hit(mx, my, card.y, edge, min_x,
        [{:lens, chord, lens_name(mode)}] of {Symbol, String, String}).nil?
    end

    # ---- read-only scrollable text card (DECODED / OUTPUT) ----
    # Returns {body_height, clamped_scroll} so the caller can persist the clamped scroll
    # (the mutators only floor at 0; the true upper bound is known here, at render).
    private def draw_text_card(screen : Screen, card : Rect, title : String, lines : Array(String),
                               scroll : Int32, focused : Bool, fg : Color = Theme.text) : {Int32, Int32}
      Frame.card(screen, card, title, bg: Theme.bg, border: Frame.pane_border(focused))
      body = card.inset(1, 1)
      return {0, scroll} if body.h <= 0
      top = scroll.clamp(0, {lines.size - body.h, 0}.max)
      (0...body.h).each do |i|
        line = lines[top + i]?
        break unless line
        # muted `// header` / `// format:` comment markers from the decoders, red WARNING lines.
        lfg = line.starts_with?("//") ? (line.includes?("WARNING") ? Theme.red : Theme.muted) : fg
        screen.text(body.x, body.y + i, line, lfg, Theme.bg, width: body.w)
      end
      Frame.scroll_gauge(screen, body, lines.size, top, focused)
      {body.h, top}
    end

    private def decoded_lines(decoded : String) : Array(String)
      decoded.empty? ? [decoded_placeholder] : decoded.split('\n')
    end

    # The shared over-paint — see `TextReadState#paint_chrome`, which carries the reasoning
    # (including the `sync_from` this pane's own copy omitted: `^L` clears the INPUT buffer
    # without resetting the read cursor, so a caret parked on line >= 1 then indexed off the
    # end of the one-line snapshot and took the render down every tick until the tick-error
    # breaker exited the session). Routing here also makes the band wrap-correct, by
    # inverting the row list the editor actually drew instead of assuming `li - scroll`.
    private def paint_read_chrome(screen : Screen, rect : Rect, ed : TextArea, read : TextReadState) : Nil
      read.paint_chrome(screen, rect, ed)
    end

    private def key_label(id : String, fallback : String) : String
      if registry = @registry
        Hotkeys.binding_label(registry, id, fallback)
      else
        fallback
      end
    end

    # ---- scroll mutators (called by the controller) ----
    def scroll_decoded(step : Int32) : Nil
      @dec_scroll = {@dec_scroll + step, 0}.max
    end

    def scroll_output(step : Int32) : Nil
      @out_scroll = {@out_scroll + step, 0}.max
    end

    def decoded_at_top? : Bool
      @dec_scroll <= 0
    end

    # True when the DECODED card has no more lines below the viewport (or content fits).
    # A short decode uses this so ↓ leaves to the next card instead of a no-op scroll.
    def decoded_at_bottom? : Bool
      return true if @dec_h <= 0
      @dec_scroll >= {@dec_lines - @dec_h, 0}.max
    end

    def output_at_top? : Bool
      @out_scroll <= 0
    end

    def output_at_bottom? : Bool
      return true if @out_h <= 0
      @out_scroll >= {@out_lines - @out_h, 0}.max
    end

    def reset_decoded_scroll : Nil
      @dec_scroll = 0
    end

    def reset_output_scroll : Nil
      @out_scroll = 0
    end
  end
end
