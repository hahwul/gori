require "./screen"
require "./theme"
require "./frame"
require "../store"
require "../links"

module Gori::Tui
  # Manage entity_links for a Finding or Note: list, select, add (via Runner sub-pickers),
  # open, and remove. Pure state + rendering; the Runner owns @overlay lifecycle.
  class LinksOverlay
    getter owner_kind : Store::LinkOwnerKind
    getter owner_id : Int64
    getter selected : Int32
    getter? adding : Bool

    def initialize(@owner_kind : Store::LinkOwnerKind, @owner_id : Int64)
      @resolved = [] of Links::Resolved
      @selected = 0
      @scroll = 0
      @adding = false
    end

    def reload(store : Store) : Nil
      links = store.list_links(@owner_kind, @owner_id)
      if @owner_kind.finding?
        if f = store.get_finding(@owner_id)
          links = Links.dedupe_finding_flow(links, f.flow_id)
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

    def selected_link : Links::Resolved?
      @resolved[@selected]?
    end

    def selected_entity_link : Store::EntityLink?
      @resolved[@selected]?.try(&.link)
    end

    def move(delta : Int32) : Nil
      return if @resolved.empty?
      @selected = (@selected + delta).clamp(0, @resolved.size - 1)
    end

    def set_selected(idx : Int32) : Nil
      return if @resolved.empty?
      @selected = idx.clamp(0, @resolved.size - 1)
    end

    def start_add : Nil
      @adding = true
    end

    def stop_add : Nil
      @adding = false
    end

    def title : String
      owner = @owner_kind.finding? ? "FINDING ##{@owner_id}" : "NOTE ##{@owner_id}"
      "LINKS — #{owner}"
    end

    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 88}.min
      h = area.h - 2
      return nil if w < 30 || h < 8
      x = area.x + (area.w - w) // 2
      y = area.y + (area.h - h) // 2
      Rect.new(x, y, w, h)
    end

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

      hint = if @adding
               "add: f flow · r repeater · z fuzz · m miner · esc back"
             else
               "↑/↓ select · ↵/o open · a add · d remove · esc close"
             end
      screen.text(box.x + 2, box.y + 1, hint, Theme.muted, Theme.panel, width: box.w - 4)
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

    private def draw_row(screen : Screen, box : Rect, ry : Int32, res : Links::Resolved, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      fg = res.stale? ? Theme.muted : (active ? Theme.text_bright : Theme.text)
      screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
      screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
      line = res.line
      screen.text(box.x + 3, ry, line, fg, bg, width: box.w - 5)
    end

    private def ensure_visible(list_h : Int32) : Nil
      return if list_h <= 0
      @scroll = @selected if @selected < @scroll
      @scroll = @selected - list_h + 1 if @selected >= @scroll + list_h
      @scroll = @scroll.clamp(0, {@resolved.size - list_h, 0}.max)
    end
  end
end
