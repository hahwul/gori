require "./screen"
require "./theme"
require "./frame"
require "./overlay"
require "./viewport"
require "../store"

module Gori::Tui
  # A small centered value-picker overlay — pick one option from a short coloured
  # list (an issue's severity or triage status, the Probe scan mode). Structurally a twin
  # of BrowserPicker: a dumb list, while WHAT the pick applies to rides in as the
  # `on_commit` closure each open-site injects. Each row is fronted by a mnemonic key
  # (helix feel) and the value currently set is marked "● current".
  class ChoicePicker < Overlay
    record Choice, label : String, key : Char, color : Color, value : Int32

    getter selected : Int32
    # :severity | :status | :probe_mode. The severity/status open-sites share ONE apply
    # closure (both write the open issue), so that closure still branches on this.
    getter kind : Symbol
    # Doubles as the Overlay focus-badge title — the card heading IS the badge here
    # ("SET SEVERITY"), which is what the pre-seam ladder read off this same getter.
    getter title : String

    def initialize(@title : String, @choices : Array(Choice), @current : Int32, @kind : Symbol)
      # Open on the row that's currently set, so ↵ without moving is a no-op.
      @selected = @choices.index { |c| c.value == @current } || 0
      @scroll = 0
    end

    # The coloured severity picker (Critical→Info), opened on the current level.
    def self.for_severity(current : Int32) : ChoicePicker
      new("SET SEVERITY", [
        Choice.new("CRITICAL", 'c', Theme.red, 4),
        Choice.new("HIGH", 'h', Theme.orange, 3),
        Choice.new("MEDIUM", 'm', Theme.yellow, 2),
        Choice.new("LOW", 'l', Theme.accent, 1),
        Choice.new("INFO", 'i', Theme.muted, 0),
      ], current, :severity)
    end

    # The coloured triage-status picker, opened on the current status.
    def self.for_status(current : Int32) : ChoicePicker
      # Live vs handled, the same two-tier the Issues and Probe lists use — NOT the severity
      # hues. This picker is where an operator learns what a status colour means, so teaching
      # `confirmed = red` here and then showing red-for-CRITICAL in the list beside it is how
      # the two axes came to look like one.
      new("SET STATUS", [
        Choice.new("open", 'o', Theme.text, 0),
        Choice.new("confirmed", 'c', Theme.text, 1),
        Choice.new("false-positive", 'f', Theme.muted, 2),
        Choice.new("resolved", 'r', Theme.muted, 3),
      ], current, :status)
    end

    # Probe scan MODE picker (kind :probe_mode — the Runner applies it to the analyzer).
    # Values match Probe::Mode (Off=0, Passive=1, Active=2, Aggressive=3).
    def self.for_probe_mode(current : Int32) : ChoicePicker
      new("SET PROBE MODE", [
        Choice.new("OFF — no scanning", 'o', Theme.muted, 0),
        Choice.new("PASSIVE — observe only", 'p', Theme.accent, 1),
        Choice.new("ACTIVE — passive + light-touch probes (in-scope)", 'a', Theme.orange, 2),
        Choice.new("AGGRESSIVE — deeper probing incl. unsafe methods (authorized, in-scope)", 'g', Theme.red, 3),
      ], current, :probe_mode)
    end

    # --- Overlay contract (see overlay.cr) ---
    def key : OverlayKind
      OverlayKind::Choice
    end

    def hint : String
      "↑/↓ select · ↵ set · key picks · esc cancel"
    end

    # ↑/↓ pick, ↵ sets, esc cancels. A printable matching a row's mnemonic sets that row
    # DIRECTLY (one keystroke, no ↵); j/k fall back to vim-style nav only when they aren't
    # themselves a mnemonic, so the reflex keystroke moves the highlight instead of being
    # ignored. Anything else is swallowed — the picker stays up, a value pick is deliberate.
    def handle_key(ev : Termisu::Event::Key) : Symbol
      key = ev.key
      case
      when key.escape? then :cancel
      when key.up?
        move(-1)
        :stay
      when key.down?
        move(1)
        :stay
      when key.enter? then :commit
      else
        if (c = ev.char) && !ev.ctrl? && !ev.alt?
          if idx = index_for(c)
            set_selected(idx)
            return :commit
          elsif c == 'j'
            move(1)
          elsif c == 'k'
            move(-1)
          end
        end
        :stay
      end
    end

    # A click on a row selects AND applies it (matching the mnemonic model); a click
    # outside the card dismisses; a click inside but off any row keeps it open.
    def handle_click(area : Rect, mx : Int32, my : Int32) : Symbol
      box = overlay_box(area)
      return :cancel if box.nil? || !box.contains?(mx, my)
      if idx = row_at(box, mx, my)
        set_selected(idx)
        return :commit
      end
      :stay
    end

    def move(delta : Int32) : Nil
      return if @choices.empty?
      @selected = (@selected + delta).clamp(0, @choices.size - 1)
    end

    def selected_value : Int32
      @choices[@selected].value
    end

    def set_selected(idx : Int32) : Nil
      return if @choices.empty?
      @selected = idx.clamp(0, @choices.size - 1)
    end

    # The row whose mnemonic matches `c` (case-insensitive), or nil for a miss.
    def index_for(c : Char) : Int32?
      lc = c.downcase
      @choices.index { |ch| ch.key == lc }
    end

    # Centered card geometry over `area` — inverse of render's offset math. nil
    # when render would draw nothing (mirrors the w/h guard).
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, label_w + 20}.min
      h = {@choices.size + 2, area.h - 2}.min
      return nil if w < 18 || area.h < 5
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

    # Row index under (mx,my), mirroring render's list loop; nil outside. Bound to
    # the ACTUALLY rendered rows ({box.h - 2, size}.min, matching render's break),
    # so a click on the bottom border of a height-clamped card can't pick a row
    # that was never drawn.
    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      rows = {box.h - 2, @choices.size}.min
      i = my - (box.y + 1)
      return nil if i < 0 || i >= rows
      return nil if mx <= box.x || mx >= box.right - 1
      ci = @scroll + i
      ci < @choices.size ? ci : nil
    end

    private def ensure_visible(rows : Int32) : Nil
      @scroll = Viewport.scroll_to_show(@selected, @scroll, rows, @choices.size)
    end

    def render(screen : Screen, area : Rect) : Nil
      box = overlay_box(area)
      unless box
        screen.text(area.x + 1, area.y, "picker needs a larger window · esc to close", Theme.muted, Theme.bg) unless area.empty?
        return
      end
      Frame.card(screen, box, @title, border: Theme.border_focus)
      rows = {box.h - 2, @choices.size}.min
      ensure_visible(rows) # keep the pre-selected 'current' row visible on a short terminal
      (0...rows).each do |i|
        ci = @scroll + i
        break if ci >= @choices.size
        ch = @choices[ci]
        ry = box.y + 1 + i
        active = ci == @selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 3, ry, ch.key.to_s, Theme.accent, bg, Attribute::Bold)
        screen.text(box.x + 6, ry, ch.label, ch.color, bg, Attribute::Bold)
        if ch.value == @current
          marker = "● current"
          screen.text(box.right - marker.size - 2, ry, marker, active ? Theme.text_bright : Theme.muted, bg)
        end
      end
    end

    private def label_w : Int32
      @choices.max_of(&.label.size)
    end
  end
end
