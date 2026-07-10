require "./screen"
require "./theme"
require "./frame"
require "../store"

module Gori::Tui
  # A small centered value-picker overlay — pick one option from a short coloured
  # list (a finding's severity or triage status). Structurally a twin of
  # BrowserPicker: pure state + rendering, while the Runner owns opening/closing
  # and applying the choice. Each row is fronted by a mnemonic key (helix feel)
  # and the value currently set on the finding is marked "● current".
  class ChoicePicker
    record Choice, label : String, key : Char, color : Color, value : Int32

    getter selected : Int32
    getter kind : Symbol # :severity | :status — the Runner branches on this to apply
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
      new("SET STATUS", [
        Choice.new("open", 'o', Theme.accent, 0),
        Choice.new("confirmed", 'c', Theme.red, 1),
        Choice.new("false-positive", 'f', Theme.muted, 2),
        Choice.new("resolved", 'r', Theme.green, 3),
      ], current, :status)
    end

    # Prism scan MODE picker (kind :prism_mode — the Runner applies it to the analyzer).
    # Values match Prism::Mode (Off=0, Passive=1, Active=2).
    def self.for_prism_mode(current : Int32) : ChoicePicker
      new("SET PRISM MODE", [
        Choice.new("OFF — no scanning", 'o', Theme.muted, 0),
        Choice.new("PASSIVE — observe only", 'p', Theme.accent, 1),
        Choice.new("ACTIVE — passive + reflected-param probes (scope rules)", 'a', Theme.orange, 2),
      ], current, :prism_mode)
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
      return if rows <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - rows + 1 if @selected >= @scroll + rows
      @scroll = @scroll.clamp(0, {@choices.size - rows, 0}.max)
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
