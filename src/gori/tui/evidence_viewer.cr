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
  # One exchange, read-only: the request and the response with the provenance line that says
  # where they came from. Two modes over ONE card (#1038, the RELATED-row ↵):
  #
  #   * FROZEN — a copy from `issue_evidence`, the bytes exactly as they were taken, with the
  #     moment of the copy and its stored hashes.
  #   * LIVE   — a `Evidence::Snapshot` of a source AS IT IS NOW, built on the keypress. It is
  #     the same bytes the freeze would copy, shown without copying them, and the card says so
  #     in every place it would otherwise say "frozen": retention or the next send can still
  #     change what this shows.
  #
  # One class, not two, because everything below the title is identical work — the panes, the
  # entity decoding, the display cap, the scroll, the `y` copy. Only the provenance says which
  # kind of answer this is.
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
  # That argument is why the LIVE mode goes through a Snapshot rather than through the
  # drill-in, even though a live flow HAS a live id to hand it: ↵ on a RELATED row is a
  # READ, and reading must not put a row of verbs that delete and send one keystroke from
  # the reader. `f` is the one action, and it only ever ADDS a copy.
  #
  # Read-only, so there is no `on_commit` and `handle_key` never answers :commit. Its two
  # actions hand OUT rather than change what is shown: `y` gives the pane's text to the
  # injected `on_copy` (the clipboard is the shell's — it writes to the tty — not this
  # card's), and `f`, LIVE only, asks the injected `on_freeze` to copy what is on screen
  # into the open issue's evidence. Neither edits a byte of the source.
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

    # FROZEN is a copy that cannot change; LIVE is the source as it is at this instant.
    enum Mode
      Frozen
      Live
    end

    getter snapshot : Evidence::Snapshot
    getter mode : Mode
    # The `issue_evidence` row this card was opened from — its id, Issue membership and the
    # moment the copy was taken, none of which a LIVE snapshot has. nil in LIVE mode, which
    # is also what `frozen?` reads.
    getter meta : Store::IssueEvidenceMeta?
    getter pane : Symbol
    getter scroll : Int32

    # Receives the shown pane's text when the operator presses `y`.
    property on_copy : Proc(String, Nil)?
    # LIVE only: `f` asks for what is on screen to be frozen onto the open issue. The Runner
    # installs it and calls `frozen_as` when the write lands, so the card flips its title
    # without closing — pressing the key and watching the answer arrive in place.
    property on_freeze : Proc(Nil)?

    def initialize(ev : Store::IssueEvidence)
      @snapshot = Evidence.to_snapshot(ev)
      @meta = ev.meta
      @mode = Mode::Frozen
      @pane = :request
      @scroll = 0
      @lines = {} of Symbol => Array(Highlight::Line)
    end

    def initialize(@snapshot : Evidence::Snapshot)
      @meta = nil
      @mode = Mode::Live
      @pane = :request
      @scroll = 0
      @lines = {} of Symbol => Array(Highlight::Line)
    end

    def frozen? : Bool
      @mode.frozen?
    end

    def live? : Bool
      @mode.live?
    end

    # The `f` landing: the same bytes, now with a row id behind them. Same card, same pane,
    # same scroll — only what the provenance can now claim about them changed.
    def frozen_as(ev : Store::IssueEvidence) : Nil
      @snapshot = Evidence.to_snapshot(ev)
      @meta = ev.meta
      @mode = Mode::Frozen
      @lines.clear
    end

    # What ⇞/⇟ step by: the body height the last render measured (see HelpPopupOverlay's
    # `@page` for why it is only knowable on the draw path). Seeded with the smallest card.
    @page : Int32 = MIN_H - HEAD_ROWS - 3

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Evidence
    end

    # `FROZEN EVIDENCE #7` / `LIVE hist #12`. The mode is the FIRST word either way: it is
    # the one thing a reader must not have to infer from the rest of the card.
    def title : String
      if m = @meta
        "FROZEN EVIDENCE ##{m.id}"
      else
        "LIVE #{@snapshot.source_kind.tag} ##{@snapshot.source_id}"
      end
    end

    def hint : String
      freeze = live? && !on_freeze.nil? ? " · f freeze" : ""
      "↹/←/→ request/response · ↑/↓ scroll · ⇞/⇟ page · y copy#{freeze} · esc close"
    end

    # Never :commit. ↹ and ←/→ swap panes, `y` and `f` are the two actions, and everything
    # else the card answers is a motion.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      k = ev.key
      ch = (ev.ctrl? || ev.alt?) ? nil : ev.char
      case
      when k.escape?, ch == 'q'      then return :cancel
      when k.tab?, k.left?, k.right? then toggle_pane
      when ch == 'y'                 then on_copy.try(&.call(pane_text))
      when ch == 'f'                 then freeze_pressed
      else                                scroll_key(k, ch)
      end
      :stay
    end

    # Every motion the card has, in one place. `j`/`k` are taken as the motions they are
    # everywhere else in this app — there is no filter here for them to collide with, unlike
    # the Help popup — and a key that is none of these is simply inert.
    private def scroll_key(k : Termisu::Input::Key, ch : Char?) : Nil
      case
      when k.up?, ch == 'k'   then move(-1)
      when k.down?, ch == 'j' then move(1)
      when k.page_up?         then move(-page_step)
      when k.page_down?       then move(page_step)
      when k.home?, ch == 'g' then @scroll = 0
      when k.end?, ch == 'G'  then @scroll = lines.size # the render clamps it to the last page
      end
    end

    # LIVE only, even when a callback is still attached: `frozen_as` flips the card without
    # dropping the Runner's closure, and a second freeze of what is already a copy is not an
    # action this card has.
    private def freeze_pressed : Nil
      on_freeze.try(&.call) if live?
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
      Frame.border_meta(screen, box, title, border_note, bg: Theme.panel)
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

    # `hist #12 · frozen 09-11 14:02:33 · 200 · HTTP/1.1 · 4ms · 34KB` for a copy, and
    # `hist #12 · as it is now · not frozen · 200 · …` for a live exchange. The status is
    # coloured as the History list colours it, and the error stands in place of a status
    # when there is one. Everything after the second field is the same fact either way —
    # it is the second field that says what the reader is looking at.
    def provenance_line : Highlight::Line
      snap = @snapshot
      sep = Highlight::Span.new(" · ", Theme.muted)
      line = [Highlight::Span.new(source_label, Theme.text_bright, Attribute::Bold)]
      if m = @meta
        line << sep << Highlight::Span.new("frozen #{EvidenceViewer.fmt_time(m.created_at)}", Theme.syn_header)
      else
        line << sep << Highlight::Span.new("as it is now", Theme.text)
        line << sep << Highlight::Span.new("not frozen", Theme.yellow)
      end
      if st = snap.status
        line << sep << Highlight::Span.new(st.to_s, Theme.status_color(st), Attribute::Bold)
      elsif err = snap.error
        line << sep << Highlight::Span.new("ERR #{err}".scrub, Theme.red)
      else
        line << sep << Highlight::Span.new("no response", Theme.muted)
      end
      if proto = snap.protocol
        line << sep << Highlight::Span.new(proto, Theme.text)
      end
      line << sep << Highlight::Span.new(Fmt.dur(snap.duration_us), Theme.text) if snap.duration_us
      line << sep << Highlight::Span.new(Fmt.size(bytes), Theme.text)
      notes = [] of String
      notes << "request body truncated at capture" if snap.request_truncated?
      notes << "response body truncated at capture" if snap.response_truncated?
      # A LIVE Repeater tab edited since its stored response is showing two halves that never
      # happened together (`Evidence.from_repeater`). A frozen row can never be drifted — the
      # freeze gate asks first — so this rides the live card only, and it rides it because
      # NOT saying it would be the card presenting a pair as one exchange.
      notes << "request edited since this response — not one exchange" if snap.request_drifted?
      line << sep << Highlight::Span.new(notes.join(" · "), Theme.yellow) unless notes.empty?
      line
    end

    # The two hashes, shortened — a report wants the whole digest, and the export carries
    # it; here they are a fingerprint the operator can compare by eye. A FROZEN row's come
    # off the ROW (what it stored and asserts), a live exchange's are computed from the
    # bytes on screen.
    def hashes_line : String
      m = @meta
      req_sha = m ? m.request_sha256 : @snapshot.request_sha256
      res_sha = m ? m.response_sha256 : @snapshot.response_sha256
      req = "sha256 req #{req_sha[0, 16]}…"
      res = res_sha.try { |h| " · res #{h[0, 16]}…" } || " · res —"
      req + res
    end

    # `hist #12` / `repeater #3` — one spelling for both modes, `IssueEvidenceMeta`'s.
    def source_label : String
      "#{@snapshot.source_kind.tag} ##{@snapshot.source_id}"
    end

    # What the card costs: the row's recorded size when there is a row, else the four blobs
    # as they stand. The two agree for a copy of the same exchange.
    private def bytes : Int64
      @meta.try(&.bytes) || @snapshot.bytes
    end

    # The right-hand border slot: Issue membership for a copy, and for a live exchange the
    # one fact that outranks it — there is no copy yet.
    private def border_note : String
      m = @meta || return "not frozen"
      m.issue_ids.empty? ? "orphaned" : "issues #{m.issue_ids.map { |id| "##{id}" }.join(",")}"
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
      screen.text(x + 1, y, chip_note, Theme.muted, Theme.panel,
        width: {box.right - 1 - (x + 1), 0}.max)
    end

    # What the strip promises beside the two chips. A copy is inert and says the source is
    # untouched; a live view is the opposite claim and must make it — the bytes on screen are
    # the ones retention or the next send can take away, and `f` is how they stop being.
    private def chip_note : String
      if frozen?
        "read-only copy — the live #{@snapshot.source_kind.tag} is unchanged"
      elsif on_freeze
        "live copy — retention or the next send can change it · f freezes it"
      else
        "live copy — retention or the next send can change it"
      end
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
        err = @snapshot.error
        text = err ? "(no response — #{err})" : "(no response)"
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
        {@snapshot.request_head, @snapshot.request_body}
      else
        {@snapshot.response_head, @snapshot.response_body}
      end
    end

    # What `y` copies: the shown pane, head and decoded body, as text. Scrubbed, because the
    # clipboard write is a tty escape and a raw 0x80 inside one is the History copy path's
    # own lesson.
    def pane_text : String
      head, body = message(@pane)
      EvidenceViewer.pane_text(head, body)
    end

    # ONE home for that shape, because the copy the Runner actually writes is taken from the
    # REDACTED twin of this evidence (#1035) rather than from `@evidence` — and a copy built
    # from the stored body instead of the ENTITY would hand the operator gzip or chunk
    # framing where the card showed them text.
    def self.pane_text(head : Bytes?, body : Bytes?) : String
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
