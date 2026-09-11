require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./highlight"
require "./viewport"
require "./fmt"
require "../store"
require "../entity"
require "../evidence"

module Gori::Tui
  # One frozen evidence row (#1038), read-only: the request and the response exactly as
  # they were copied, with the provenance line that says where and when.
  #
  # It is a modal over the Issues detail and NOT the History drill-in, though the
  # drill-in is "the normal request/response viewer". The drill-in's verbs act on a LIVE
  # flow id — delete it, link it, probe it, send it to the Repeater — and a snapshot has
  # no live id to act on; every one of those would have to be gated, and one missed gate
  # is an operator deleting the flow they thought they were reading a copy of. A modal
  # can hold nothing but the bytes. It also answers the other half of the contract for
  # free: esc lands back on the RELATED row the viewer was opened from, same tab, same
  # cursor, because nothing underneath moved.
  #
  # Read-only, so there is no `on_commit` and `handle_key` never answers :commit. The one
  # action, `y`, hands the pane's text to the injected `on_copy` — the clipboard is the
  # shell's (it writes to the tty), not this card's.
  class EvidenceViewer < Overlay
    # Which of the two messages the body shows. One at a time rather than side by side:
    # gori's messages are read by width, and a card split in two shows neither.
    PANES = [:request, :response]

    # How much of a BODY the card will style. A snapshot body is capture-capped already, but
    # `Highlight.message` materialises a styled line per source line, and a multi-MiB minified
    # body is one line — so the cap is on bytes, and the cut is announced in the pane.
    DISPLAY_BODY_CAP = 256 * 1024
    TRUNCATED_NOTE   = "… [display truncated — the stored copy is complete]"

    # Rows the card spends above the message: provenance, hashes, the chip strip, and the
    # divider under them.
    HEAD_ROWS = 4

    MIN_W = 40
    MIN_H = 12

    getter evidence : Store::IssueEvidence
    getter pane : Symbol
    getter scroll : Int32

    # Receives the shown pane's text when the operator presses `y`.
    property on_copy : Proc(String, Nil)?

    def initialize(@evidence : Store::IssueEvidence)
      @pane = :request
      @scroll = 0
      @lines = {} of Symbol => Array(Highlight::Line)
    end

    # What ⇞/⇟ step by: the body height the last render measured (see HelpPopupOverlay's
    # `@page` for why it is only knowable on the draw path). Seeded with the smallest card.
    @page : Int32 = MIN_H - HEAD_ROWS - 3

    def meta : Store::IssueEvidenceMeta
      @evidence.meta
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Evidence
    end

    def title : String
      "FROZEN EVIDENCE ##{meta.id}"
    end

    def hint : String
      "↹/←/→ request/response · ↑/↓ scroll · ⇞/⇟ page · y copy · esc close"
    end

    # Never :commit. ↹ and ←/→ swap panes; the rest is scrolling. `j`/`k` are taken as the
    # motions they are everywhere else in this app — there is no filter here for them to
    # collide with, unlike the Help popup.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      ch = (ev.ctrl? || ev.alt?) ? nil : ev.char
      case
      when k.escape?, ch == 'q'      then return :cancel
      when k.tab?, k.left?, k.right? then toggle_pane
      when k.up?, ch == 'k'          then move(-1)
      when k.down?, ch == 'j'        then move(1)
      when k.page_up?                then move(-page_step)
      when k.page_down?              then move(page_step)
      when k.home?, ch == 'g'        then @scroll = 0
      when k.end?, ch == 'G'         then @scroll = Int32::MAX
      when ch == 'y'                 then on_copy.try(&.call(pane_text))
      end
      :stay
    end

    def toggle_pane : Nil
      @pane = @pane == :request ? :response : :request
      @scroll = 0
    end

    def show(pane : Symbol) : Nil
      return unless PANES.includes?(pane)
      @scroll = 0 if pane != @pane
      @pane = pane
    end

    def move(d : Int32) : Nil
      @scroll = {@scroll + d, 0}.max
    end

    private def page_step : Int32
      {@page - 1, 1}.max
    end

    # A click on a chip swaps panes, on the gauge scrolls; anywhere else in the card is inert.
    # Outside dismisses — the shell-wide gesture.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if my == chip_y(box)
        chip_x = box.x + 2
        PANES.each do |p|
          w = chip_label(p).size + 2
          if mx >= chip_x && mx < chip_x + w
            show(p)
            return :stay
          end
          chip_x += w + 1
        end
      end
      if top = Frame.scroll_gauge_top(body_rect(box), lines.size, mx, my)
        @scroll = top
      end
      :stay
    end

    def handle_wheel(step : Int32) : Nil
      move(step)
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 120}.min
      h = area.h - 2
      return nil if w < MIN_W || h < MIN_H
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.desired_cursor = nil
        Overlay.too_small(screen, area, "the evidence viewer needs a larger window")
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      Frame.border_meta(screen, box, title, "issue ##{meta.issue_id}", bg: Theme.panel)
      Highlight.draw(screen, box.x + 2, box.y + 1, provenance_line, Theme.panel, box.w - 4)
      screen.text(box.x + 2, box.y + 2, hashes_line, Theme.muted, Theme.panel, width: box.w - 4)
      render_chips(screen, box)
      Frame.tee_divider(screen, box, box.y + HEAD_ROWS)

      body = body_rect(box)
      return if body.h <= 0
      @page = body.h
      rows = lines
      @scroll = Viewport.clamp_scroll(@scroll, body.h, rows.size)
      (0...body.h).each do |i|
        li = @scroll + i
        break if li >= rows.size
        Highlight.draw(screen, body.x, body.y + i, rows[li], Theme.panel, body.w)
      end
      Frame.scroll_gauge(screen, body, rows.size, @scroll, true, Theme.panel)
    end

    # `hist #12 · frozen 09-11 14:02:33 · 200 · HTTP/1.1 · 4ms · 34KB`, the status coloured
    # as the History list colours it, and the error in place of a status when there is one.
    def provenance_line : Highlight::Line
      m = meta
      sep = Highlight::Span.new(" · ", Theme.muted)
      line = [Highlight::Span.new(m.source_label, Theme.text_bright, Attribute::Bold)]
      line << sep << Highlight::Span.new("frozen #{EvidenceViewer.fmt_time(m.created_at)}", Theme.syn_header)
      if st = m.status
        line << sep << Highlight::Span.new(st.to_s, Theme.status_color(st), Attribute::Bold)
      elsif err = m.error
        line << sep << Highlight::Span.new("ERR #{err}".scrub, Theme.red)
      else
        line << sep << Highlight::Span.new("no response", Theme.muted)
      end
      if proto = m.protocol
        line << sep << Highlight::Span.new(proto, Theme.text)
      end
      line << sep << Highlight::Span.new(Fmt.dur(m.duration_us), Theme.text) if m.duration_us
      line << sep << Highlight::Span.new(Fmt.size(m.bytes), Theme.text)
      notes = [] of String
      notes << "request body truncated at capture" if m.request_truncated?
      notes << "response body truncated at capture" if m.response_truncated?
      line << sep << Highlight::Span.new(notes.join(" · "), Theme.yellow) unless notes.empty?
      line
    end

    # The two hashes, shortened — a report wants the whole digest, and the export carries
    # it; here they are a fingerprint the operator can compare by eye.
    def hashes_line : String
      m = meta
      req = "sha256 req #{m.request_sha256[0, 16]}…"
      res = m.response_sha256.try { |h| " · res #{h[0, 16]}…" } || " · res —"
      req + res
    end

    private def chip_y(box : Rect) : Int32
      box.y + 3
    end

    private def chip_label(p : Symbol) : String
      p == :request ? "REQUEST" : "RESPONSE"
    end

    private def render_chips(screen : Screen, box : Rect) : Nil
      x = box.x + 2
      y = chip_y(box)
      PANES.each do |p|
        active = p == @pane
        fg = active ? Theme.text_bright : Theme.muted
        bg = active ? Theme.accent_bg : Theme.panel
        x = screen.text(x, y, " #{chip_label(p)} ", fg, bg, attr: active ? Attribute::Bold : Attribute::None) + 1
      end
      screen.text(x + 1, y, "read-only copy — the live #{meta.source_kind.tag} is unchanged", Theme.muted, Theme.panel,
        width: {box.right - 1 - (x + 1), 0}.max)
    end

    private def body_rect(box : Rect) : Rect
      Rect.new(box.x + 2, box.y + HEAD_ROWS + 1, box.w - 4, box.bottom - 1 - (box.y + HEAD_ROWS + 1))
    end

    # The shown pane's styled lines, built once per pane. Bodies are shown as their ENTITY
    # (de-chunked, inflated) the way every display pane shows them; the stored bytes stay
    # the wire form.
    def lines : Array(Highlight::Line)
      @lines[@pane] ||= build_lines(@pane)
    end

    private def build_lines(pane : Symbol) : Array(Highlight::Line)
      head, body = message(pane)
      if head.nil?
        text = meta.error ? "(no response — #{meta.error})" : "(no response)"
        return [[Highlight::Span.new(text.scrub, Theme.muted)] of Highlight::Span]
      end
      shown = Entity.bytes(head, body)
      cut = false
      if shown && shown.size > DISPLAY_BODY_CAP
        shown = shown[0, DISPLAY_BODY_CAP]
        cut = true
      end
      out = Highlight.message(head, shown, pane == :request)
      out << [Highlight::Span.new(TRUNCATED_NOTE, Theme.yellow)] of Highlight::Span if cut
      out
    end

    private def message(pane : Symbol) : {Bytes?, Bytes?}
      if pane == :request
        {@evidence.request_head, @evidence.request_body}
      else
        {@evidence.response_head, @evidence.response_body}
      end
    end

    # What `y` copies: the shown pane, head and decoded body, as text. Scrubbed, because the
    # clipboard write is a tty escape and a raw 0x80 inside one is the History copy path's
    # own lesson.
    def pane_text : String
      head, body = message(@pane)
      return "" unless head
      String.build do |io|
        io << String.new(head).scrub
        if (b = Entity.bytes(head, body)) && !b.empty?
          io << String.new(b).scrub
        end
      end
    end

    def self.fmt_time(us : Int64) : String
      Time.unix(us // 1_000_000).to_local.to_s("%Y-%m-%d %H:%M:%S")
    end
  end
end
