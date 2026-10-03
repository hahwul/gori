require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../bind_address"
require "../settings"
require "../plural"

module Gori::Tui
  # The ADDITIONAL-listener inventory: every socket this session serves besides the primary
  # bind, opened from the `listeners:N` top-bar chip (or the app.listeners palette entry).
  # Read-only — the section is edited in `settings.json`, and there is no TUI editor for it to
  # duplicate.
  #
  #   reverse      127.0.0.1:9000   → https://api.acme.test:443    up
  #   transparent  127.0.0.1:8443                                  up
  #   socks5       127.0.0.1:1080                                  up
  #   proxy        192.168.1.4:8070                        could not bind
  #
  # This is the second half of the #499 address decision. The primary bind stays THE proxy
  # address — the singular thing a client is configured against, and the only address gori can
  # move under the operator — so it keeps the `● host:port` chip to itself. Everything here was
  # typed into settings.json by the operator, so it needs confirming rather than announcing,
  # and an inventory is the shape that does that without making any of the six primary-bind
  # surfaces answer "which one?".
  #
  # It is also the first consumer of `Session#listener_errors`. That list has been collected
  # correctly since additional listeners existed and displayed nowhere, so a listener that
  # failed to bind — or was rejected as unusable before it ever got a socket — was invisible,
  # and the only symptom was traffic that never arrived.
  class ListenersOverlay < ListCard
    # `r`: re-read the `listeners` section from settings.json and make the sockets match it
    # (#508). Injected rather than called on `@session` here because the reconcile is a
    # lifecycle change and reporting what it moved is the shell's job — the overlay only asks,
    # then re-snapshots. Left nil (a plain re-snapshot) this is still the read-only list it was.
    property on_reload : Proc(Nil)?

    def initialize(@session : Gori::Session)
      @rows = @session.listener_rows
    end

    # Re-snapshot from the live session. The overlay holds a COPY rather than reading per draw
    # so the rows can't shift under a click hit-tested against the previous frame.
    def reload : Nil
      @rows = @session.listener_rows
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Listeners
    end

    def title : String
      "LISTENERS"
    end

    def hint : String
      "↑/↓ scroll · r reload settings.json · esc close"
    end

    # No ↵ commit — there is nothing here to edit, so the only action is `r`, which re-reads the
    # section and applies it.
    private def refresh : Nil
      (cb = on_reload) ? cb.call : reload
    end

    def entry_count : Int32
      @rows.size
    end

    # 76 columns: a row carries mode AND bind AND origin, and the origin is the field that must
    # never be the one squeezed out, since it is the whole content of a reverse listener.
    private def card_w : Int32
      76
    end

    private def meta : String
      Gori.plural(@rows.size, "listener")
    end

    private def empty_text : String
      "(no additional listeners configured)"
    end

    private def too_small_what : String
      "listener list needs a larger window"
    end

    # The last row inside the card. Two facts the list itself cannot carry, both of which the
    # operator would otherwise guess wrong:
    #
    #   - the PRIMARY bind is not in this list and is not supposed to be (#499). Naming it here
    #     is cheaper than letting "why isn't :8070 listed?" become a bug report.
    #   - where the edit happens and what makes it take effect (#508). The section has no editor
    #     here, so without this the operator has no way to know an edit needs `r` — which is the
    #     same silence the reconcile exists to end.
    private def draw_footer(screen : Screen, box : Rect) : Nil
      y = box.bottom - 2 # box.bottom - 1 is the card's bottom border (Frame.card)
      return if y <= box.y + 1
      primary = Gori::BindAddress.display(@session.proxy.host, @session.proxy.port, terse: true)
      screen.text(box.x + 3, y, "#{primary} is the proxy address · edit settings.json, then r",
        Theme.muted, Theme.panel, width: {box.w - 4, 1}.max)
    end

    # mode · bind · detail · status. The DETAIL column is the origin for a healthy reverse
    # listener and the reason for a broken one — the two are mutually exclusive and both are
    # what the row exists to say, so they share the widest column rather than competing for it.
    #
    # An error deliberately does NOT ride in the right-hand status column. It did at first, and
    # running it showed why that is wrong: the status column is right-aligned and sized to its
    # own text, so a sentence-length reason pushed the bind address down to "1…" — the row lost
    # the one field an operator needs in order to know WHICH listener is broken.
    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      row = @rows[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      # `Theme.accent`, not this row's status colour. The glyph is only drawn when the row is
      # SELECTED (unselected rows get a space, where a foreground colour renders nothing), so
      # tinting it never coloured the list — it recoloured the one bar whose job is to say
      # "you are here", making the selection indicator mean two things at once. The status is
      # already stated in words on this row: the up/down tail below, or the error reason in
      # the detail column.
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)

      # A broken listener's status is the reason, shown in the detail column, so the right-hand
      # column is left empty rather than saying "down" as well — one fact, one place.
      tail = row.error ? "" : (row.listening ? "up" : "down")
      tail_x = box.right - 1 - Screen.display_width(tail)

      mode_x = box.x + 3
      mode_w = 12 # the longest mode string ("transparent") plus a space
      screen.text(mode_x, py, row.mode, mode_color(row), bg, width: mode_w)

      bind_x = mode_x + mode_w
      # An "invalid" row never got a socket, so its host field carries the authority the config
      # named and its port is 0 — print that rather than a bogus ":0".
      bind = row.port > 0 ? Gori::BindAddress.authority(row.host, row.port) : row.host
      avail = {tail_x - 1 - bind_x, 2}.max
      detail, detail_color = detail_of(row)
      # A fixed bind column when there is a detail to show: an authority is short and bounded,
      # so splitting the free width proportionally only starved whichever field lost.
      bind_w = detail.empty? ? avail : {BIND_COL_W, avail}.min
      drawn = screen.text(bind_x, py, bind, sel ? Theme.text_bright : Theme.text, bg, width: bind_w)
      unless detail.empty?
        dx = {drawn + 2, bind_x + bind_w + 1}.min
        dw = {tail_x - 1 - dx, 0}.max
        screen.text(dx, py, detail, detail_color, bg, width: dw) if dw > 0
      end
      screen.text(tail_x, py, tail, status_color(row), bg) unless tail.empty?
    end

    # Wide enough for an authority with a full IPv4 and a 5-digit port ("192.168.100.20:18910"),
    # which is the longest one an operator realistically binds a listener to.
    BIND_COL_W = 22

    # What goes in the detail column: the reason a listener is broken, else where it forwards.
    private def detail_of(row : Gori::Session::ListenerRow) : {String, Color}
      if err = row.error
        # The error already begins with this listener's own address (Session builds it that way
        # so a failure can be matched back to its server) — drop that prefix, since the row is
        # already showing the address in its own column.
        return {err.split(" — ", 2).last, Theme.red}
      end
      row.origin.empty? ? {"", Theme.muted} : {"→ #{row.origin}", Theme.accent}
    end

    private def status_color(row : Gori::Session::ListenerRow) : Color
      return Theme.red if row.error
      row.listening ? Theme.green : Theme.muted
    end

    # A mode is a fact, not a state, so it stays plain — except "invalid", which is not a mode
    # at all but a rejected entry standing in for one.
    private def mode_color(row : Gori::Session::ListenerRow) : Color
      row.mode == "invalid" ? Theme.red : Theme.muted
    end
  end
end
