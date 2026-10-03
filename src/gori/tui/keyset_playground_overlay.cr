require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./keyset_pad"
require "./register"
require "../verb"

module Gori::Tui
  # Preferences → Keys → Keyset playground: the setup wizard's practice pad, reachable after
  # the wizard, with the whole READ grammar of the keyset being tried listed under it. The pad
  # is the wizard's (`KeysetPad`, the real keymap and the real `ReadEdit` engine); this card
  # adds the key list. It only tries: the keyset is picked on the Editor keyset row right above
  # the row that opens it, and a second setter here would be one more way for the two to
  # disagree about what is saved.
  #
  #   ◉ helix-ish (default)  x line · y copy · d delete · p paste · ^Z undo
  #   ◯ vim-ish              ⇧V line · yy yank · dd delete · p paste · u undo
  #   ╭ TRY IT · helix-ish ─╮
  #   KEYS · helix-ish
  #     move    ←↓↑→ or h j k l · …
  #
  # The pad's copies and deletes fill gori's paste register, which a real `p` reads, so the
  # register is put back as it was when the card closes (`restore_register`).
  class KeysetPlaygroundOverlay < Overlay
    property on_palette : Proc(Nil)?

    getter keyset : Verb::Keyset::Kind

    OFFER_ROW  = 2 # box-relative rows: the two keysets
    PAD_ROW    = 5
    PAD_H      = 5
    STATUS_ROW = PAD_ROW + PAD_H
    CHEAT_ROW  = STATUS_ROW + 2
    HEIGHT     = CHEAT_ROW + 1 + KeysetPad::CHEAT[Verb::Keyset::Kind::Vim].size + 1
    LABEL_W    = 22
    KINDS      = {Verb::Keyset::Kind::Helix, Verb::Keyset::Kind::Vim}

    def initialize(@keyset : Verb::Keyset::Kind = Verb::Keyset.active, pad : KeysetPad? = nil)
      @pad = pad || KeysetPad.new(@keyset)
      @focus = :choice
      @held = {Register.text, Register.linewise?}
    end

    def pad_focused? : Bool
      @focus == :pad
    end

    # Put the paste register back as the card found it: the pad's practice copies are not
    # what the next `p` in a real pane should paste.
    def restore_register : Nil
      text, linewise = @held
      text ? Register.store(text, linewise: linewise) : Register.clear
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::KeysetPlayground
    end

    def title : String
      "KEYSET PLAYGROUND"
    end

    def hint : String
      return "⇥ back to the keysets · esc leaves the pad" if pad_focused?
      "↑/↓ keyset · ⇥/↵ or type to try · esc close — pick yours on the Editor keyset row"
    end

    # On the keyset rows: ↑/↓ pick, ⇥ / ↵ (or any letter) move into the pad.
    # In the pad every key is the pad's except ⇥ / ⇧⇥, which hand the keys back, and the esc
    # the pad hands back itself (READ, nothing selected or armed).
    def handle_key(ev : Termisu::Event::Key) : Symbol
      if ev.ctrl? && ev.key.lower_p?
        on_palette.try(&.call)
        return :stay
      end
      return choice_key(ev) unless pad_focused?
      key = ev.key
      leave_pad if key.tab? || key.back_tab? || !@pad.handle_key(ev)
      :stay
    end

    private def choice_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      if key.tab? || key.enter?
        @focus = :pad
      elsif key.up? || key.down?
        stage(@keyset.vim? ? Verb::Keyset::Kind::Helix : Verb::Keyset::Kind::Vim)
      elsif (c = ev.char) && !c.control? && !key.space? && !ev.ctrl? && !ev.alt?
        @focus = :pad
        @pad.handle_key(ev)
      end
      :stay
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      return :stay unless box = overlay_box(area)
      return :cancel unless box.contains?(mx, my)
      row = my - box.y
      if 0 <= row - OFFER_ROW < KINDS.size
        leave_pad
        stage(KINDS[row - OFFER_ROW])
      elsif PAD_ROW <= row < PAD_ROW + PAD_H
        @focus = :pad
      end
      :stay
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 100}.min
      h = HEIGHT
      return nil if w < 60 || area.h - 2 < h
      area.center(w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      unless box = overlay_box(area)
        Overlay.too_small(screen, area, "the keyset playground needs a larger window")
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      ix = box.x + 3
      iw = {box.w - 6, 1}.max
      screen.text(ix, box.y + 1, "Try either keyset on the pad; pick yours on the Editor keyset row. Your rebindings apply here too.",
        Theme.muted, Theme.panel, width: iw)
      on_choice = !pad_focused?
      KINDS.each_with_index do |kind, i|
        ry = box.y + OFFER_ROW + i
        picked = kind == @keyset
        band = picked && on_choice
        bg = band ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, band ? '▎' : ' ', Theme.accent, bg)
        screen.cell(ix, ry, picked ? '◉' : '◯', picked ? Theme.accent : Theme.muted, bg)
        name = Verb::Keyset.name_of(kind)
        screen.text(ix + 2, ry, Hotkeys::KEYSET_LABELS[name]? || name, band ? Theme.text_bright : Theme.text, bg, width: LABEL_W)
        rx = ix + 2 + LABEL_W
        screen.text(rx, ry, @pad.reference(kind), Theme.muted, bg, width: {ix + iw - rx, 1}.max)
      end
      @pad.render(screen, Rect.new(ix, box.y + PAD_ROW, iw, PAD_H), pad_focused?)
      screen.text(ix, box.y + STATUS_ROW, @pad.status, Theme.muted, Theme.panel, width: iw)
      render_cheat(screen, ix, box.y + CHEAT_ROW, iw)
    end

    # The keyset being tried, every READ gesture it has, one row per kind of gesture.
    private def render_cheat(screen : Screen, x : Int32, y : Int32, w : Int32) : Nil
      screen.text(x, y, "KEYS · #{Verb::Keyset.name_of(@keyset)}-ish", Theme.accent, Theme.panel, width: w)
      @pad.cheat_sheet(@keyset).each_with_index do |(label, keys), i|
        screen.text(x + 2, y + 1 + i, label, Theme.text, Theme.panel, width: 8)
        screen.text(x + 10, y + 1 + i, keys, Theme.muted, Theme.panel, width: {w - 10, 1}.max)
      end
    end

    private def stage(kind : Verb::Keyset::Kind) : Nil
      @keyset = kind
      @pad.keyset = kind
    end

    # The keys go back to the keyset rows: out of INSERT, and any armed `d` dropped with it.
    private def leave_pad : Nil
      @pad.editor_exit_insert if @pad.insert?
      @pad.disarm
      @focus = :choice
    end
  end
end
