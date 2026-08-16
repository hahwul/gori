require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "../hotkeys"
require "../authorize/identity"

module Gori::Tui
  # The Authorize tab's identity LIST: which identities a run replays each request under,
  # which one is the baseline the others are judged against, and the way in to editing them.
  #
  # It renders header NAMES only, never values (`Identity#summary`). A session cookie is a
  # credential, and a list that paints it is a credential on screen for as long as the card is
  # open; the form shows the value, because that is what editing one means.
  #
  # Add/edit hand off to `AuthorizeIdentityOverlay`, and an overlay cannot open another one —
  # `Runner#open_overlay` is private, and deliberately so. So `handle_key` ARMS `pending` and
  # answers `:close`; the Runner-installed `on_close` reads it and opens the form. That is the
  # same shape `LinksOverlay#pending_add` uses for the identical list→form hand-off.
  class AuthorizeIdentitiesOverlay < Overlay
    # What the operator asked to edit: an index into the list, or nil for "add a new one".
    record Pending, index : Int32?

    getter identities : Array(Authorize::Identity)
    getter pending : Pending?
    getter selected : Int32

    # Applied after an IN-PLACE change (delete, or moving the baseline) — the card stays open,
    # so there is no commit to carry it. Returns whether the write persisted; false paints the
    # note so a failed save is never silent.
    property on_change : Proc(Array(Authorize::Identity), Bool)?

    def initialize(identities : Array(Authorize::Identity), cursor : Int32? = nil)
      @identities = identities.dup
      @selected = (cursor || 0).clamp(0, {identities.size - 1, 0}.max)
      @pending = nil.as(Pending?)
      @note = nil.as(String?)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::AuthorizeIdentities
    end

    def title : String
      "IDENTITIES"
    end

    def hint : String
      "↑/↓ pick · a add · e edit · d delete · b baseline · esc close"
    end

    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      return :cancel if key.escape?
      return :stay if ev.ctrl? || ev.alt?
      case
      when key.up?, key.lower_k?   then move(-1)
      when key.down?, key.lower_j? then move(1)
      when key.lower_a?
        @pending = Pending.new(nil)
        # `:cancel`, not a commit: this card has nothing to commit (delete/baseline already
        # applied through `on_change`). It just closes, and the Runner's `on_close` reads
        # `pending` and opens the form. `:cancel` and `:commit` are the ONLY outcomes that
        # close — anything else leaves the card up.
        return :cancel
      when key.lower_e?, key.enter?
        return :stay if @identities.empty?
        @pending = Pending.new(@selected)
        return :cancel
      when key.lower_d? then delete_selected
      when key.lower_b? then promote_selected
      end
      :stay
    end

    def move(d : Int32) : Nil
      return if @identities.empty?
      @selected = (@selected + d).clamp(0, @identities.size - 1)
    end

    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if i = row_at(box, mx, my)
        @selected = i
      end
      :stay
    end

    # --- mutations that keep the card open ---

    private def delete_selected : Nil
      return if @identities.empty?
      # Refusing to delete the last one is not paternalism: a run with no identities sends
      # nothing at all, and the tab would give no hint why. Deleting it back to the built-in
      # pair is what "start over" means here.
      if @identities.size == 1
        @note = "the last identity cannot be deleted — edit it instead"
        return
      end
      dropped = @identities.delete_at(@selected)
      @selected = @selected.clamp(0, @identities.size - 1)
      # The baseline is what every other identity is read against, so it cannot simply vanish
      # with the row: promote the first survivor rather than leaving a set with no anchor.
      if dropped.baseline? && @identities.none?(&.baseline?)
        @identities[0] = @identities[0].with_baseline(true)
      end
      publish("removed #{dropped.name}")
    end

    private def promote_selected : Nil
      return if @identities.empty?
      return if @identities[@selected].baseline?
      # Set-then-clear through the whole list, so "exactly one baseline" is enforced by
      # construction rather than by everyone remembering to clear the old one.
      @identities = @identities.map_with_index { |id, i| id.with_baseline(i == @selected) }
      publish("#{@identities[@selected].name} is the baseline")
    end

    private def publish(what : String) : Nil
      # A COPY. `AuthorizeView#identities=` short-circuits on `list == @identities`, so handing
      # over the same object made every later in-place edit invisible to it: after one delete
      # the view held THIS array, and the next `delete_at` mutated it behind the setter's back.
      # `identity_rev` then stopped advancing, ^R answered "every request already has a result",
      # and the table kept showing trials for identities that no longer existed.
      saved = @on_change.try(&.call(@identities.dup))
      @note = saved == false ? "#{what} — but the project could not be written" : what
    end

    # --- geometry / render ---

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 68}.min
      h = {area.h - 2, {@identities.size + 6, 10}.max}.min
      return nil if w < 36 || h < 7
      Rect.new(area.x + (area.w - w) // 2, area.y + (area.h - h) // 2, w, h)
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless box.contains?(mx, my)
      i = my - (box.y + 2)
      (0 <= i < @identities.size) ? i : nil
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "identities need a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, "IDENTITIES", border: Theme.border_focus)
      first = box.y + 2
      if @identities.empty?
        screen.text(box.x + 3, first, "no identities — a adds one", Theme.muted, Theme.panel)
      else
        @identities.each_with_index do |id, i|
          py = first + i
          break if py >= box.bottom - 2
          draw_row(screen, box, id, i, py)
        end
      end
      # The ACTIONS, on the card itself. They were only ever on the shell's hint strip, which
      # is the wrong place for the one thing a first-time reader needs here: the card lists
      # what exists and said nothing about how to add to it. A transient note takes the row
      # when there is one to report, then it goes back to the actions.
      note_y = box.bottom - 2
      text = @note || "a add · e edit · d delete · b baseline"
      screen.text(box.x + 3, note_y, Hotkeys.retag(text), Theme.muted, Theme.panel, width: box.w - 6)
    end

    private def draw_row(screen : Screen, box : Rect, id : Authorize::Identity, i : Int32, py : Int32) : Nil
      sel = i == @selected
      bg = sel ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, py, box.w - 2, 1), bg)
      screen.cell(box.x + 1, py, sel ? '▎' : ' ', Theme.accent, bg)
      x = box.x + 3
      screen.cell(x, py, id.baseline? ? '◆' : '·', id.baseline? ? Theme.focus_gold : Theme.muted, bg)
      name_x = x + 2
      name_w = 18
      screen.text(name_x, py, id.name, sel ? Theme.text_bright : Theme.text, bg, width: name_w)
      sx = name_x + name_w + 1
      # The baseline row says so in WORDS, right-aligned, rather than leaving `◆` to a legend
      # the card no longer has room for. A glyph nobody can look up is not a label.
      tag = id.baseline? ? "baseline" : ""
      tag_x = box.right - 2 - tag.size
      screen.text(sx, py, id.summary, Theme.muted, bg, width: {tag_x - 1 - sx, 1}.max)
      screen.text(tag_x, py, tag, Theme.focus_gold, bg) unless tag.empty?
    end
  end
end
