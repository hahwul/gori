require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"

module Gori::Tui
  # PICK A PROVIDER: which of the enabled OAST providers an action that needs exactly ONE
  # should use, asked at the moment it needs the answer.
  #
  # The payload bar's provider slot has an "All" position, and "All" is a legible state for
  # the callbacks table (show every provider's hits) but not for `g` / `^R`, which mint or
  # register against ONE provider. Both used to answer that with a status line — "select a
  # specific provider (use ‹/› to cycle)" — which names a second, invisible step: the operator
  # pressed a key, got told no, and had to find a bar they were not looking at. This card
  # answers the same question where it was asked.
  #
  # A row is addressed by its ProviderConfig#key, never by index: the enabled list is re-formed
  # on every reload/soft-sync (a peer process toggling a provider is enough), so an index
  # captured when the card opened can point at a different provider by the time ↵ lands. The
  # key is the same identity `Listener#provider_key` and `listener_for` already run on.
  class OastProviderPicker < PlainPickerOverlay
    # One enabled provider as the card shows it. `live` marks the ones already polling — a
    # provider gori is listening with mints its payload locally, with no round trip, and that
    # is worth seeing BEFORE the pick rather than after it.
    record Row,
      key : String,
      name : String,
      kind : String,
      host : String,
      scope : String,
      live : Bool

    # What the card is being asked FOR ("GET PAYLOAD FROM" / "START LISTENING WITH") — the two
    # open-sites differ only in this and in their injected on_commit.
    def initialize(@rows : Array(Row), @title : String)
    end

    def entry_count : Int32
      @rows.size
    end

    def selected_row : Row?
      @rows[@selected]?
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::OastProviderPick
    end

    def title : String
      @title
    end

    def hint : String
      "↑/↓ select · ↵ use this provider · esc cancel"
    end

    # esc cancels · ↑/↓ (and j/k, as in every sibling picker) move · ↵ picks. This card has no
    # filter — a project's enabled-provider list is a handful of rows — so the vim keys are
    # free to be nav, exactly as in OastSessionPicker.
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
          when 'j' then move(1)
          when 'k' then move(-1)
          end
        end
      end
      :stay
    end

    # Floors at 30 cells, not the base's 18: every row carries a right-aligned meta, and
    # "interactsh · project · ● live" alone is 29 of them.
    private def min_w : Int32
      30
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, idx : Int32, active : Bool, bg : Color) : Nil
      row = @rows[idx]
      # Meta first, so the NAME is the field that gets width-clamped — the same order (and the
      # same reason) as OastSessionPicker: a long provider name must not push the live marker
      # off the card, since that marker is what says this pick costs no round trip.
      meta = meta_text(row)
      mx = box.right - 1 - Screen.draw_width(meta)
      screen.text(mx, ry, meta, row.live ? Theme.green : Theme.muted, bg)
      name_w = {mx - (box.x + 3) - 1, 1}.max
      screen.text(box.x + 3, ry, row.name, active ? Theme.text_bright : Theme.text, bg,
        Attribute::Bold, width: name_w)
      # The host rides after the name when there is room — two providers of the same kind are
      # told apart by the server they point at. draw_width, not `size`: a CJK provider name
      # occupies two cells per character, so advancing by the character count would start the
      # host on top of the name's second half.
      used = Screen.draw_width(row.name) + 1
      if used < name_w
        screen.text(box.x + 3 + used, ry, row.host, Theme.muted, bg, width: name_w - used)
      end
    end

    private def meta_text(row : Row) : String
      base = "#{row.kind} · #{row.scope}"
      row.live ? "#{base} · ● live" : base
    end

    # Widest row plus its padding, driving the card width — measured in CELLS, like
    # draw_row's `used`.
    private def card_w : Int32
      widest = @rows.max_of do |r|
        Screen.draw_width(r.name) + Screen.draw_width(r.host) +
          Screen.draw_width(meta_text(r)) + 6
      end
      widest + 8
    end
  end
end
