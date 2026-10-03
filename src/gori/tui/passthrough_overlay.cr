require "./screen"
require "./theme"
require "./fmt"
require "./frame"
require "./overlay"
require "../settings"
require "../plural"

module Gori::Tui
  # The TLS-passthrough list: every host gori relayed WITHOUT decrypting it, opened from the
  # `bypass:N` top-bar chip (or the app.passthrough palette entry). Read-only — the rules
  # themselves are edited in settings:network, and duplicating that editor here would be two
  # places to change one list.
  #
  #   updates.acme.test        *.acme.test        2m ago       14 conns
  #   push.acme.test           push.acme.test     11m ago       3 conns
  #
  # This answers the question a bypassed host otherwise leaves unanswerable: nothing is
  # captured for it, so History has no row, Sitemap has no node, and "why is this host
  # missing?" had only a gori.log line for an answer (#497). Each row names the PATTERN as
  # well as the host, because the operator's next move is usually to delete the rule.
  #
  # Not a flow list and deliberately unlike one: no ids, no marks, no verbs. Nothing here can
  # be sent to the repeater or probed, because gori never saw the bytes.
  class PassthroughOverlay < ListCard
    def initialize
      @hosts = Settings.passthrough_hosts
    end

    # Re-snapshot from the live inventory. The overlay holds a COPY rather than reading
    # Settings per draw so the rows can't shift under a click that was hit-tested against
    # the previous frame; `r` refreshes it on demand.
    def reload : Nil
      @hosts = Settings.passthrough_hosts
      @selected = @selected.clamp(0, {@hosts.size - 1, 0}.max)
    end

    def hosts : Array(Settings::PassthroughHost)
      @hosts
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Passthrough
    end

    def title : String
      "TLS PASSTHROUGH"
    end

    def hint : String
      "↑/↓ scroll · r refresh · esc close"
    end

    def entry_count : Int32
      @hosts.size
    end

    # Wider than the notification ring (72 vs 60) because a row carries host AND pattern, and
    # the pattern is the field that must never be the thing that gets dropped.
    private def card_w : Int32
      72
    end

    private def meta : String
      Gori.plural(@hosts.size, "host")
    end

    private def too_small_what : String
      "passthrough list needs a larger window"
    end

    # "Nothing bypassed yet" and "no rules configured" are DIFFERENT facts and must not read
    # the same: the first means the rules exist and no client has hit them, the second means
    # this list can never fill. Only the second is answerable from Settings.tls_passthrough.
    private def empty_text : String
      return "(no TLS passthrough rules configured)" if Settings.tls_passthrough.empty?
      "(no host has been bypassed yet)"
    end

    # The last row inside the card: where the rules live, plus the truncation notice. The cap
    # is stated OUT LOUD rather than silently showing the first N of more (see
    # Settings::PASSTHROUGH_INVENTORY_MAX).
    private def draw_footer(screen : Screen, box : Rect) : Nil
      y = box.bottom - 2 # box.bottom - 1 is the card's bottom border (Frame.card)
      return if y <= box.y + 1
      over = Settings.passthrough_over_cap
      if over > 0
        text = "capped at #{Settings::PASSTHROUGH_INVENTORY_MAX} hosts · #{over} later bypassed connection#{over == 1 ? "" : "s"} not listed"
        screen.text(box.x + 3, y, text, Theme.yellow, Theme.panel, width: {box.w - 4, 1}.max)
      else
        # Session-global, not per-project: `tls_passthrough` is a global setting and the proxy
        # keeps running across a project switch, so this list does too. Said here because the
        # chip sits in per-project chrome, where the opposite would be the fair guess.
        screen.text(box.x + 3, y, "session-wide · edit the rules in settings:network",
          Theme.muted, Theme.panel, width: {box.w - 4, 1}.max)
      end
    end

    # host · pattern · age · connection count. The pattern gets its own column rather than
    # riding in an aside that a narrow pane can drop — naming the rule to delete is the point
    # of the row, so it is the last thing that may be squeezed, not the first.
    private def draw_row(screen : Screen, box : Rect, i : Int32, py : Int32) : Nil
      entry = @hosts[i]
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      # `Theme.accent` — the selection bar reads the same in every list. The yellow it used to
      # carry said nothing this row does not: the pattern column below is already yellow.
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)

      conns = Gori.plural(entry.connections, "conn")
      stamp = Fmt.ago(entry.first_seen)
      tail = "#{stamp}  #{conns}"
      tail_x = box.right - 1 - Screen.display_width(tail)

      host_x = box.x + 3
      # Split the free width between host and pattern, host first: an over-long host must not
      # push the pattern off the row entirely.
      avail = {tail_x - 1 - host_x, 2}.max
      host_w = {avail // 2, 1}.max
      drawn = screen.text(host_x, py, entry.host, sel ? Theme.text_bright : Theme.text, bg, width: host_w)
      pat_x = {drawn + 2, host_x + host_w + 1}.min
      pat_w = {tail_x - 1 - pat_x, 0}.max
      screen.text(pat_x, py, entry.pattern, Theme.yellow, bg, width: pat_w) if pat_w > 0
      screen.text(tail_x, py, tail, Theme.muted, bg) if tail_x > pat_x
    end
  end
end
