require "./screen"
require "./theme"
require "./frame"
require "./fmt"
require "./viewport"
require "../param_inventory"

module Gori::Tui
  # The Params sub-tab (under Target): the per-endpoint parameter inventory (#1231) — every
  # input name the captured requests carry, where it appears, how often, sample values, and
  # whether a value came back in the response.
  #
  # Owns no store and runs no read. The controller builds the `ParamInventory::Report` off
  # the event loop and hands it over; this is a renderer with a cursor and a node filter.
  # The filter is a SET of endpoint paths rather than a prefix because a Sitemap row can be a
  # `{uuid}` fold, whose descendants share a parent but not a path the fold itself names.
  class ParamsView
    alias Row = ParamInventory::Row

    # What the Sitemap row the operator came from stands for: a host (paths nil = every
    # endpoint on it) or a subtree's endpoint paths, with the label the header shows.
    record Target, host : String, paths : Set(String)?, label : String

    HEADER_H = 2 # summary · column headings

    LOC_W        = 10
    COUNT_W      =  6
    REFL_W       =  2
    NAME_MAX     = 32
    ENDPOINT_MAX = 36

    getter report : ParamInventory::Report?
    getter error : String?
    getter target : Target?
    getter selected : Int32
    property? scanning : Bool = false
    property? all_headers : Bool = false

    def initialize
      @report = nil
      @error = nil
      @target = nil
      @selected = 0
      @scroll = 0
      @rows = [] of Row
    end

    def report=(r : ParamInventory::Report) : Nil
      @report = r
      @error = nil
      reproject
    end

    def error=(message : String) : Nil
      @error = message
      @report = nil
      @rows = [] of Row
      @selected = 0
      @scroll = 0
    end

    def target=(t : Target?) : Nil
      @target = t
      reproject
    end

    def ready? : Bool
      !@report.nil?
    end

    def rows : Array(Row)
      @rows
    end

    def selected_row : Row?
      @rows[@selected]?
    end

    def move(delta : Int32) : Nil
      return if @rows.empty?
      @selected = (@selected + delta).clamp(0, @rows.size - 1)
    end

    # For the ↑-at-top release to the sub-tab strip. An empty list is at the top too, so ↑
    # is never a dead key on a tab that has not scanned yet.
    def at_top? : Bool
      @rows.empty? || @selected <= 0
    end

    def select_index(i : Int32) : Nil
      return if @rows.empty?
      @selected = i.clamp(0, @rows.size - 1)
    end

    def focus_first : Nil
      @selected = 0
    end

    def focus_last : Nil
      @selected = {@rows.size - 1, 0}.max
    end

    # Re-apply the node filter, keeping the cursor on the SAME parameter when it survives —
    # a rescan (new capture, the header toggle) is a refresh, not a reset.
    private def reproject : Nil
      anchor = @rows[@selected]?.try { |r| key_of(r) }
      all = @report.try(&.rows) || [] of Row
      @rows = if t = @target
                paths = t.paths
                all.select { |r| r.host == t.host && (paths.nil? || paths.includes?(r.path)) }
              else
                all
              end
      @selected = (anchor ? @rows.index { |r| key_of(r) == anchor } : nil) || 0
      @selected = @selected.clamp(0, {@rows.size - 1, 0}.max)
      @scroll = 0 if anchor.nil?
    end

    private def key_of(r : Row) : {String, String, String, Miner::Location, String}
      {r.host, r.method, r.path, r.location, r.name}
    end

    # The whole inventory's rows for the target HOST, ignoring the path filter — Miner's
    # neighbour names come from the host's OTHER endpoints, which the filter hides.
    def host_rows(host : String) : Array(Row)
      (@report.try(&.rows) || [] of Row).select { |r| r.host == host }
    end

    # ── render ──────────────────────────────────────────────────────────────────

    def render(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.empty?
      screen.fill(rect, Theme.bg)
      render_header(screen, rect)
      if err = @error
        if y = row(rect, HEADER_H)
          screen.text(rect.x, y, "! #{err}", Theme.red, Theme.bg, width: rect.w)
        end
        return
      end
      list = Rect.new(rect.x, rect.y + HEADER_H, rect.w, {rect.h - HEADER_H, 0}.max)
      render_list(screen, list, focused)
    end

    # `Screen#text` clips to the SCREEN, not the rect, so every row is checked against the
    # pane height (the 40x8 minimum leaves this body one or two rows).
    private def row(rect : Rect, offset : Int32) : Int32?
      offset < rect.h ? rect.y + offset : nil
    end

    private def render_header(screen : Screen, rect : Rect) : Nil
      if y = row(rect, 0)
        x = screen.text(rect.x, y, summary, Theme.text_bright, Theme.bg, width: rect.w)
        chips = [] of String
        chips << "scanning…" if scanning?
        chips << "all headers" if all_headers?
        chips << "TRUNCATED" if @report.try(&.truncated)
        unless chips.empty?
          label = chips.join(" · ")
          lx = {rect.right - label.size, x + 2}.max
          screen.text(lx, y, label, Theme.accent, Theme.bg, width: {rect.right - lx, 0}.max)
        end
      end
      if (y = row(rect, 1)) && !@rows.empty?
        name_w, ep_w = widths(rect.w)
        head = String.build do |io|
          io << " " << "LOCATION".ljust(LOC_W) << "NAME".ljust(name_w) << "FLOWS".rjust(COUNT_W - 1) << " "
          io << "R".ljust(REFL_W)
          io << "ENDPOINT".ljust(ep_w) if ep_w > 0
          io << "SAMPLES"
        end
        screen.text(rect.x, y, head, Theme.muted, Theme.bg, width: rect.w)
      end
    end

    private def summary : String
      where = @target.try(&.label) || "all endpoints"
      r = @report
      return "PARAMS · #{where}" unless r
      "PARAMS · #{where} · #{@rows.size} params · #{Fmt.count(r.flows_scanned)} flows read"
    end

    # {name column, endpoint column} widths. The endpoint column is dropped when the view is
    # one endpoint (it would repeat on every row) or when the pane is too narrow to spare it.
    private def widths(w : Int32) : {Int32, Int32}
      name_w = ((@rows.max_of? { |r| Screen.display_width(r.name) } || 4) + 2).clamp(6, NAME_MAX)
      single = (t = @target) && (paths = t.paths) && paths.size <= 1
      ep_w = single || w < 80 ? 0 : ENDPOINT_MAX
      {name_w, ep_w}
    end

    @list_last_h = 0 # rows the last list frame drew — the PgUp/PgDn step

    def list_page_rows : Int32
      {@list_last_h - 2, 1}.max
    end

    private def render_list(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h <= 0
      @list_last_h = rect.h
      if @rows.empty?
        screen.text(rect.x, rect.y, empty_note, Theme.muted, Theme.bg, width: rect.w)
        return
      end
      name_w, ep_w = widths(rect.w)
      @scroll = Viewport.scroll_to_show(@selected, @scroll, rect.h, @rows.size)
      (0...rect.h).each do |i|
        idx = @scroll + i
        break if idx >= @rows.size
        draw_row(screen, rect, @rows[idx], rect.y + i, idx == @selected, focused, name_w, ep_w)
      end
      Frame.scroll_gauge(screen, rect, @rows.size, @scroll, focused, Theme.bg)
    end

    private def empty_note : String
      return "scanning captured requests…" if scanning? && @report.nil?
      return "press ^R to scan the captured requests for parameters" unless r = @report
      return "no parameters on #{@target.try(&.label)} — esc clears the filter to show every endpoint" if @target && !r.rows.empty?
      "no parameters in #{Fmt.count(r.flows_scanned)} flows read (the Sitemap query and scope lens apply)"
    end

    def row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      top = rect.y + HEADER_H
      return nil unless mx >= rect.x && mx < rect.right && my >= top && my < rect.bottom
      idx = @scroll + (my - top)
      idx < @rows.size ? idx : nil
    end

    private def draw_row(screen : Screen, rect : Rect, r : Row, y : Int32, selected : Bool,
                         focused : Bool, name_w : Int32, ep_w : Int32) : Nil
      bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      if selected
        screen.fill(Rect.new(rect.x, y, rect.w, 1), bg)
        screen.cell(rect.x, y, '▎', Theme.accent, bg)
      end
      x = rect.x + 1
      screen.text(x, y, r.location.label, Theme.muted, bg, width: LOC_W - 1)
      x += LOC_W
      screen.text(x, y, r.name.scrub, selected ? Theme.text_bright : Theme.text, bg, Attribute::Bold, width: name_w - 1)
      x += name_w
      screen.text(x, y, r.count.to_s.rjust(COUNT_W - 1), Theme.text, bg, width: COUNT_W - 1)
      x += COUNT_W
      screen.text(x, y, "↩", Theme.orange, bg, width: 1) if r.reflected
      x += REFL_W
      if ep_w > 0
        screen.text(x, y, "#{r.method} #{r.path}".scrub, Theme.muted, bg, width: ep_w - 1)
        x += ep_w
      end
      rest = rect.right - 1 - x
      return if rest <= 0
      samples = r.samples.map(&.scrub).join(", ")
      samples += ", …" if r.samples_truncated
      screen.text(x, y, samples, r.sensitive ? Theme.orange : Theme.muted, bg, width: rest)
    end
  end
end
