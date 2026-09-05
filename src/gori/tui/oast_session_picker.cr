require "./screen"
require "./theme"
require "./fmt"
require "./frame"
require "./picker_overlay"

module Gori::Tui
  # RESUME LISTENER: pick one of this project's persisted OAST sessions and start polling it
  # again.
  #
  # Registration state is the only part of an OAST listener that is NOT reconstructible: the
  # correlation id, the poll secret and the interactsh RSA private key are minted once, by the
  # server, and the payloads planted out in the world resolve against THAT triple and no other.
  # gori has always written them to `oast_sessions` — and never read them back, so `^R` could
  # only ever mint a fresh registration. Every payload planted before a restart was dead, which
  # is precisely backwards for the one workbench whose findings arrive late.
  #
  # Two actions, because a session has two ends: `↵` resumes it (the reason this card exists)
  # and `x` releases it — deregisters the server-side state for an engagement that is over,
  # without touching the callbacks already collected. Neither deletes anything local; the rows
  # in `oast_callbacks` are evidence.
  class OastSessionPicker < PickerOverlay
    # One persisted session as the card shows it. `hits` is the controller's own per-session
    # counter (the TOTAL folded, not the windowed view's size) and `live` marks the sessions
    # already polling — those rows stay listed rather than being filtered out, because a card
    # that silently omitted the running listener would read as "that session is gone".
    record Row,
      session_id : Int64,
      provider : String,
      payload_host : String,
      started_at : Time,
      hits : Int32,
      live : Bool

    # Set by the open-site; runs for the `x` action instead of the ↵ commit.
    property on_release : Proc(Int64, Nil)?

    def initialize(@rows : Array(Row))
    end

    def empty? : Bool
      @rows.empty?
    end

    def entry_count : Int32
      @rows.size
    end

    def selected_row : Row?
      @rows[@selected]?
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::OastSession
    end

    def title : String
      "RESUME LISTENER"
    end

    def hint : String
      "↑/↓ select · ↵ resume · x release (deregister) · esc cancel"
    end

    # ↵ resumes, `x` releases, esc cancels; j/k are the vim nav every other picker gives.
    #
    # `x` is a plain letter and that is safe HERE in a way it would not be in a
    # FilterPickerOverlay, where every printable belongs to the query. This card has no filter
    # — a project's session list is a handful of rows — so letters are free to be actions.
    #
    # A release does NOT commit: the card stays up. Releasing is a housekeeping pass over a
    # finished engagement ("drop these three"), and closing after each one would make the
    # operator reopen the card between them.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape?  then return :cancel
      when key.up?      then move(-1)
      when key.down?    then move(1)
      when page_key(ev) then nil
      when key.enter?   then return :commit
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt?
          case c
          when 'x' then release_selected
          when 'j' then move(1)
          when 'k' then move(-1)
          end
        end
      end
      :stay
    end

    # Hand the selected session to the open-site's release closure and mark the row released
    # in place, so the card reflects what just happened without a reopen. The row keeps its
    # place in the list: it is still resumable (interactsh rebuilds a deregistered session
    # from the same key), so removing it would overstate what a release does.
    private def release_selected : Nil
      row = @rows[@selected]?
      return unless row
      if cb = @on_release
        cb.call(row.session_id)
      end
      @rows[@selected] = row.copy_with(live: false)
    end

    # Centered card geometry over `area` — inverse of render's offset math. nil when render
    # would draw nothing. Guards the empty list for the same reason CopyPicker does: the base
    # class calls this on EVERY click, and `content_w`'s max_of raises on an empty array.
    def overlay_box(area : Rect) : Rect?
      return nil if @rows.empty?
      w = {area.w - 4, content_w + 8}.min
      h = {@rows.size + 2, area.h - 2}.min
      return nil if w < 30 || area.h < 5
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx,my), mirroring render's list loop; nil outside. Bound to the rows
    # ACTUALLY drawn, so a click on a height-clamped card's bottom border can't pick one that
    # was never there.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      rows = {box.h - 2, @rows.size}.min
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < @rows.size ? ci : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)
      rows = {box.h - 2, @rows.size}.min
      ensure_visible(rows)
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= @rows.size
        draw_row(screen, box, box.y + 1 + i, @rows[ci], ci == @selected)
      end
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, row : Row, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      # The right-hand meta ("4 hits · 2h · ● live") is laid down FIRST so the provider name
      # can be width-clamped to whatever is left. The other order lets a long provider name
      # push the age and the live marker off the card — and the live marker is the one cell
      # that tells the operator this row needs no resume at all.
      meta = meta_text(row)
      mx = box.right - 1 - Screen.draw_width(meta)
      screen.text(mx, ry, meta, row.live ? Theme.green : Theme.muted, bg)
      name_w = {mx - (box.x + 3) - 1, 1}.max
      screen.text(box.x + 3, ry, row.provider, active ? Theme.text_bright : Theme.text, bg,
        Attribute::Bold, width: name_w)
      # The payload host under the name would need a second row per session; instead it rides
      # after the name when there is room. A session IS its payload host to the operator —
      # "which of these is the oast.pro one" is the question this card gets asked.
      #
      # draw_width, not `size`: a provider name is whatever the operator typed, and a CJK one
      # occupies two cells per character. Advancing by the CHARACTER count would start the host
      # on top of the second half of the name it is supposed to follow.
      used = Screen.draw_width(row.provider) + 1
      if used < name_w
        screen.text(box.x + 3 + used, ry, row.payload_host, Theme.muted, bg,
          width: name_w - used)
      end
    end

    private def meta_text(row : Row) : String
      base = "#{row.hits} hit#{row.hits == 1 ? "" : "s"} · #{Fmt.ago(row.started_at)}"
      row.live ? "#{base} · ● live" : base
    end

    # Widest row, driving the card width. Same reason as draw_row's `used`: the provider name
    # and the payload host are measured in CELLS, not characters.
    private def content_w : Int32
      @rows.max_of do |r|
        Screen.draw_width(r.provider) + Screen.draw_width(r.payload_host) +
          Screen.draw_width(meta_text(r)) + 6
      end
    end

    # Compact relative age: "3s" / "5m" / "2h" / "1d". Mirrors PassthroughOverlay#ago —
    # the session's start is a wall-clock stamp read back out of the project DB, so it is a
    # `Time`, not a monotonic tick. Clamped at 0 so a clock that moved backwards between the
    # write and this read shows "0s" rather than a negative age.
  end
end
