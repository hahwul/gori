require "./screen"
require "./theme"
require "./frame"
require "./picker_overlay"
require "../store"
require "../links"

module Gori::Tui
  # Manage entity_links for an Issue or Note: list, select, open, remove, and add.
  #
  # Adding is a two-step flow (`a` arms it, then f/r/z/m picks a source) that opens a
  # SECOND modal — the flow or sub-tab picker. Pre-seam that round-trip lived in the
  # Runner as three ivars (@link_add_owner / @link_add_ref_kind plus the picker itself)
  # and a pair of close methods that rebuilt this overlay from scratch on every exit.
  # It now rides the base's nested-modal seam: a source key reports :cancel with
  # `pending_add` set, and the injected `on_close` puts the sub-picker up in this card's
  # place — the sub-picker's own `on_close` pops back to a fresh LINKS card, whichever
  # way it exits. The owner is already ours (`owner_kind`/`owner_id`), so none of that
  # pending-link state survives in Runner.
  #
  # Domain edges are injected at the open-site (Runner#open_links_overlay): `on_commit`
  # opens the selected link, `on_remove` deletes it, `on_close` drives the add hand-off.
  class LinksOverlay < PickerOverlay
    # The card's own hint row and the shell's bottom row say DIFFERENT things on purpose:
    # the card has the width to spell out what each source key means, the status bar does
    # not. Collapsing them onto the terse pair loses the only place that tells the user
    # z is fuzz and m is miner.
    CARD_ADD_HINT    = "add: f flow · r repeater · z fuzz · m miner · esc back"
    CARD_BROWSE_HINT = "↑/↓ select · ↵/o open · a add · d remove · esc close"
    ADD_HINT         = "f/r/z/m pick type · esc back"
    BROWSE_HINT      = "↑/↓ · ↵/o open · a add · d remove · esc close"
    # The link sources, as the keys the adding-mode hint advertises.
    ADD_KEYS = "frzm"

    getter owner_kind : Store::LinkOwnerKind
    getter owner_id : Int64
    getter? adding : Bool
    # The source key chosen while adding, read by `on_close` once the shell has dropped
    # this card. nil for every other exit, which is what keeps `on_close` inert when the
    # user merely opened a link or pressed esc.
    getter pending_add : Char?

    # Deletes the highlighted link and reloads. Stays open — removing is a repeatable
    # edit, not a dismissal.
    property on_remove : Proc(Nil)?

    def initialize(@owner_kind : Store::LinkOwnerKind, @owner_id : Int64)
      @resolved = [] of Links::Resolved
      @adding = false
      @pending_add = nil
    end

    def reload(store : Store) : Nil
      links = store.list_links(@owner_kind, @owner_id)
      if @owner_kind.issue?
        if f = store.get_issue(@owner_id)
          links = Links.dedupe_issue_flow(links, f.flow_id)
        end
      end
      @resolved = Links.resolve_all(store, links)
      @selected = @selected.clamp(0, {@resolved.size - 1, 0}.max)
    end

    def empty? : Bool
      @resolved.empty?
    end

    def count : Int32
      @resolved.size
    end

    def entry_count : Int32
      @resolved.size
    end

    def selected_link : Links::Resolved?
      @resolved[@selected]?
    end

    def selected_entity_link : Store::EntityLink?
      @resolved[@selected]?.try(&.link)
    end

    def start_add : Nil
      @adding = true
    end

    def stop_add : Nil
      @adding = false
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Links
    end

    def title : String
      owner = @owner_kind.issue? ? "ISSUE ##{@owner_id}" : "NOTE ##{@owner_id}"
      "LINKS — #{owner}"
    end

    def hint : String
      adding? ? ADD_HINT : BROWSE_HINT
    end

    # Browse: ↑/↓ (or k/j) select · ↵/o open · a arms add · d removes · esc closes.
    # Adding: f/r/z/m choose the source, which hands off through on_close.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      # Unmodified letters only — `^D` reports 'd' and `on_remove` DELETEs the link row.
      # See the note at env_overlay.cr's matching arm. Read before the add-mode fork so
      # handle_add_key's f/r/z/m gets the same guard.
      ch = (ev.ctrl? || ev.alt?) ? nil : (ev.char || key.to_char)
      return handle_add_key(key, ch) if adding?
      case
      when key.escape?             then return :cancel
      when key.up?, key.lower_k?   then move(-1)
      when key.down?, key.lower_j? then move(1)
      when key.enter?              then return :commit
      when ch == 'o'               then return :commit
      when ch == 'd'               then on_remove.try(&.call)
      when ch == 'a'               then start_add
      end
      :stay
    end

    # Adding is a MODE, and the mouse has to respect it. `handle_key` forks to
    # handle_add_key while armed, but the click path was left to PickerOverlay, which knows
    # nothing about the mode: a row click answered :commit, the shell recorded that row as
    # `opening`, and on_close — pending_add still nil — ran navigate_link_ref, teleporting
    # the operator into an unrelated flow/repeater/fuzz while the armed add was silently
    # abandoned. While adding, the only meaningful input is f/r/z/m, so a click inside the
    # card is swallowed exactly as handle_add_key swallows a stray key.
    #
    # A click OUTSIDE still drops the whole card, deliberately NOT the one-level pop esc
    # does here. Click-away is the shell-wide dismiss gesture (Overlay#handle_click), and
    # HotkeysOverlay — the other modal with a sub-mode — makes the same split: its click
    # handler cancels outright while capturing, where handle_capture_key's esc only leaves
    # capture. Making this the one modal whose outside click does not dismiss would cost
    # more consistency than the two depths do, and nothing leaks: pending_add stays nil, so
    # on_close runs inert.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      return super unless adding?
      box = overlay_box(area)
      (box.nil? || !box.contains?(mx, my)) ? :cancel : :stay
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 88}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Still mode-aware even though `handle_click` no longer reaches it while adding: this is
    # the geometry statement (render reserves the same footer row), and the mode gate above
    # is a policy that could move. Dropping the subtraction would silently mis-map the last
    # row the moment either one changes.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      list_top = box.y + 3
      list_h = box.bottom - 1 - list_top - (@adding ? 1 : 0)
      i = my - list_top
      return nil if i < 0 || i >= list_h
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < @resolved.size ? ri : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "links overlay needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, title, border: Theme.border_focus)

      card_hint = adding? ? CARD_ADD_HINT : CARD_BROWSE_HINT
      screen.text(box.x + 2, box.y + 1, card_hint, Theme.muted, Theme.panel, width: box.w - 4)
      Frame.tee_divider(screen, box, box.y + 2)

      list_top = box.y + 3
      footer = @adding ? 1 : 0
      list_h = box.bottom - 1 - list_top - footer
      ensure_visible(list_h)

      if @resolved.empty?
        screen.text(box.x + 3, list_top, "no links yet — press a to add", Theme.muted, Theme.panel)
      else
        (0...list_h).each do |i|
          ri = @scroll + i
          break if ri >= @resolved.size
          draw_row(screen, box, list_top + i, @resolved[ri], ri == @selected)
        end
      end

      if @adding
        screen.text(box.x + 2, box.bottom - 1, "choose type to add…", Theme.accent, Theme.panel, width: box.w - 4)
      end
    end

    # A source key arms the hand-off and drops this card, so `on_close` can put the
    # sub-picker up in its place (the shell holds exactly one modal). esc backs out to
    # browse; anything else is swallowed so a stray key can't leave the flow half-armed.
    #
    # The esc branch is load-bearing and easy to lose: the pre-seam shell reached it
    # through `case (ev.char || key.to_char) … else stop_add if key.escape?`, which reads
    # like dead code because termisu's `Key#to_char` has no mapping for Escape. It is not
    # dead — gori enables the Kitty keyboard protocol unconditionally (app.cr), and under
    # it Escape arrives as `CSI 27 u`, which the parser turns into `char: '\e'`. So `c`
    # was non-nil and `stop_add` ran. Adding mode has no other keyboard exit, so dropping
    # this traps the user in the card whenever the mouse is off.
    private def handle_add_key(key : Termisu::Input::Key, ch : Char?) : Symbol
      if ch && ADD_KEYS.includes?(ch)
        @pending_add = ch
        return :cancel
      end
      stop_add if key.escape?
      :stay
    end

    private def draw_row(screen : Screen, box : Rect, ry : Int32, res : Links::Resolved, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = res.stale? ? Theme.muted : (active ? Theme.text_bright : Theme.text)
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      line = res.line
      screen.text(box.x + 3, ry, line, fg, bg, width: box.w - 5)
    end
  end
end
