require "termisu"
require "../project"
require "../project_search"
require "../store/query_control"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./text_field"
require "./viewport"
require "./url"
require "./flow_status"

module Gori::Tui
  # The project picker's ^F (#1229): type a needle, and every registered project's captured
  # flows are searched for it (`Gori::ProjectSearch`). Hits stream in grouped under their
  # project, and ↵ on one opens that project with the flow's detail already showing.
  #
  # A plain form object, the shape `CompactOverlay` has: the picker owns the mode, routes keys,
  # clicks and the wheel here, and acts on the `Outcome`. The picker holds a live Termisu and
  # cannot be built in a spec; this can.
  #
  # The search runs on a fiber of its own, one project at a time (see ProjectSearch.run), so
  # the picker's 50 ms loop keeps painting the progress line while it works. Every edit bumps
  # a GENERATION and cancels the run in flight; a result from an older generation is dropped
  # on arrival, so a slow project finishing late can never land under a newer needle.
  class ProjectSearchOverlay
    # How long typing has to pause before a search starts. A search reopens every project's
    # database, so starting one per keystroke would mostly be cancelling the last.
    DEBOUNCE = 250.milliseconds

    # What the picker should do after a key or a click. `:open` carries the pick.
    record Outcome, kind : Symbol, project : Project? = nil, flow_id : Int64? = nil

    STAY = Outcome.new(:stay)

    # One drawn line of the result list. `:header` names a project with hits, `:hit` is one
    # flow under it, `:skipped` is a project that could not be searched. The cursor lands on
    # hits AND skipped rows — the list scrolls only by following it, so a row it could not land
    # on would be a row nobody could scroll to — but only a hit opens anything.
    private record Row, kind : Symbol, result : ProjectSearch::Result, hit : ProjectSearch::Hit? = nil

    @field = TextField.new
    # Append-only per generation, in two parts so a streaming append never moves a row the
    # cursor is on: hit groups arrive in project order and always sit above the skipped list.
    @hit_rows = [] of Row
    @skip_rows = [] of Row
    # The cursor, as {part, index within that part}. Not a combined row index: a hit group
    # arriving while the cursor sits on a skipped row is inserted ABOVE it, and a combined index
    # would silently re-point at a different row.
    @sel : {Symbol, Int32}? = nil
    @user_moved = false # the operator has moved the cursor; streaming must not take it back
    @scroll = 0
    @list_h = 1
    @generation = 0
    @control : Store::QueryControl? = nil
    @running = false
    @edited_at : Time::Instant? = nil
    @needle : String? = nil
    @scanned = 0
    @hits = 0
    @skipped = 0
    @unindexed = 0
    @no_body = 0 # projects whose bodies a long-enough needle still could not search

    # `labels` is the picker's discriminator map (project dir → what tells two same-named
    # projects apart), so a group header names a project exactly the way its list row does.
    def initialize(@projects : Array(Project), @labels : Hash(String, String) = {} of String => String)
    end

    def query : String
      @field.value
    end

    def running? : Bool
      @running
    end

    # Typed, and waiting out the debounce.
    def pending? : Bool
      !@edited_at.nil?
    end

    def set_preedit(text : String) : Nil
      @field.set_preedit(text)
    end

    # Start the search once typing has paused for DEBOUNCE. The picker calls this every frame.
    def tick(now : Time::Instant = Time.instant) : Nil
      if (at = @edited_at) && now - at >= DEBOUNCE
        start
      end
    end

    # Search for the current query now, cancelling whatever was running.
    def start : Nil
      @edited_at = nil
      stop
      @generation += 1
      reset_results
      return unless needle = ProjectSearch.needle(query)
      @needle = needle
      gen = @generation
      control = Store::QueryControl.new
      @control = control
      @running = true
      projects = @projects
      spawn(name: "gori-project-search") do
        ProjectSearch.run(projects, needle, control: control) { |result| absorb(result, gen) }
      rescue ex
        # `run` reports every database it cannot read as a skipped result, so a raise here is
        # one it does not know about. Logged, never printed onto the picker's alternate screen.
        ::Log.error(exception: ex) { "project search fiber died" }
      ensure
        @running = false if gen == @generation
      end
    end

    # Cancel the run in flight, keeping what it found so far.
    def stop : Nil
      @control.try(&.cancel)
      @control = nil
      @running = false
    end

    # Called on every way out of the mode, so no search outlives the overlay.
    def close : Nil
      @edited_at = nil
      stop
    end

    # esc stops a running search first, and closes only once nothing is running. ↵ opens the
    # cursor hit — unless the query has changed since the last search, when it searches NOW:
    # the rows on screen belong to no needle, and ↵ right after typing means "go".
    def handle_key(ev : Termisu::Event::Key) : Outcome
      key = ev.key
      if ev.ctrl_c?
        close
        return Outcome.new(:quit)
      end
      case
      when key.escape?
        return close_outcome unless @running
        stop
      when key.up?        then move(-1)
      when key.down?      then move(1)
      when key.page_up?   then move(-@list_h)
      when key.page_down? then move(@list_h)
      when key.enter?
        return start_now if pending?
        return open_selected
      else
        edit(ev)
      end
      STAY
    end

    private def close_outcome : Outcome
      close
      Outcome.new(:close)
    end

    private def start_now : Outcome
      start
      STAY
    end

    private def open_selected : Outcome
      return STAY unless (sel = selected_index) && (row = row?(sel)) && (hit = row.hit)
      close
      Outcome.new(:open, row.result.project, hit.flow_id)
    end

    # The field refuses a Ctrl/Alt chord itself, so ^F and friends never type a letter. Only a
    # change to the TEXT re-arms the search — a caret motion is not a new needle.
    private def edit(ev : Termisu::Event::Key) : Nil
      before = @field.value
      return unless @field.handle_edit_key(ev) && @field.value != before
      stop
      @generation += 1 # a result already on its way belongs to the old needle
      reset_results
      @edited_at = Time.instant
    end

    private def reset_results : Nil
      @hit_rows = [] of Row
      @skip_rows = [] of Row
      @sel = nil
      @user_moved = false
      @scroll = 0
      @needle = nil
      @scanned = @hits = @skipped = @unindexed = @no_body = 0
    end

    # One project's result, from the search fiber. Dropped when it belongs to an older
    # generation: the run that produced it was cancelled, but the result was already in hand.
    private def absorb(result : ProjectSearch::Result, gen : Int32) : Nil
      return unless gen == @generation
      @scanned += 1
      @unindexed += result.unindexed
      if result.skipped?
        @skipped += 1
        @skip_rows << Row.new(:skipped, result)
        @sel ||= {:skip, @skip_rows.size - 1}
        return
      end
      @no_body += 1 if !result.body_searched && (n = @needle) && ProjectSearch.body_searchable?(n)
      return if result.hits.empty?
      @hits += result.hits.size
      @hit_rows << Row.new(:header, result)
      first = @hit_rows.size
      result.hits.each { |hit| @hit_rows << Row.new(:hit, result, hit) }
      # The first hit to arrive takes the cursor — from a skipped row too, unless the operator
      # put it there.
      @sel = {:hit, first} if @sel.nil? || (!@user_moved && @sel.try(&.[0]) == :skip)
    end

    private def selected_index : Int32?
      return nil unless sel = @sel
      part, idx = sel
      part == :hit ? idx : @hit_rows.size + idx
    end

    private def select_index(i : Int32) : Nil
      @sel = i < @hit_rows.size ? {:hit, i} : {:skip, i - @hit_rows.size}
    end

    private def row_count : Int32
      @hit_rows.size + @skip_rows.size
    end

    private def row?(i : Int32) : Row?
      return nil if i < 0
      i < @hit_rows.size ? @hit_rows[i] : @skip_rows[i - @hit_rows.size]?
    end

    # Step the cursor `delta` rows, over group headers, stopping at either end.
    def move(delta : Int32) : Nil
      return unless sel = selected_index
      dir = delta.sign
      i = sel
      delta.abs.times do
        j = i + dir
        while (r = row?(j)) && r.kind == :header
          j += dir
        end
        break unless row?(j)
        i = j
      end
      return if i == sel
      select_index(i)
      @user_moved = true
    end

    def wheel(delta : Int32) : Nil
      move(delta)
    end

    # The pick under the cursor, for a spec and for the hint.
    def selected_pick : {Project, Int64}?
      return nil unless (sel = selected_index) && (row = row?(sel)) && (hit = row.hit)
      {row.result.project, hit.flow_id}
    end

    # --- mouse ---------------------------------------------------------------

    # SELECT-FIRST, like the picker's list: a click on a hit selects it, a click on the
    # selected hit opens it. A click outside the card closes the search.
    def click(area : Rect, mx : Int32, my : Int32) : Outcome
      box = overlay_box(area)
      return close_outcome if box.nil? || !box.contains?(mx, my)
      return STAY unless (idx = row_at(box, mx, my)) && (row = row?(idx)) && row.kind != :header
      return open_selected if idx == selected_index
      select_index(idx)
      @user_moved = true
      STAY
    end

    def row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      i = my - (box.y + LIST_OFFSET)
      return nil if i < 0 || i >= list_height(box)
      return nil if mx < box.x + 1 || mx >= box.right - 1
      ri = @scroll + i
      ri < row_count ? ri : nil
    end

    # --- rendering -----------------------------------------------------------

    # The list starts below the query row and the divider carrying the progress line.
    LIST_OFFSET = 3

    # Most of the screen, but clear of the picker's bottom two rows: the hint row (h-2) says
    # what the keys do here, and the notice row (h-3) above it.
    def overlay_box(area : Rect) : Rect?
      w = {area.w - 4, 100}.min
      h = area.h - 5
      return nil if w < 30 || h < 7
      Rect.new(area.x + (area.w - w) // 2, area.y + 1, w, h)
    end

    private def list_height(box : Rect) : Int32
      {box.bottom - 1 - (box.y + LIST_OFFSET), 0}.max
    end

    def hint : String
      stop_or_close = @running ? "esc stop" : "esc close"
      "↑/↓ select   ↵ open   pgup/pgdn page   #{stop_or_close}"
    end

    def render(screen : Screen, area : Rect) : Nil
      unless box = overlay_box(area)
        screen.text(area.x + 1, area.y, "search needs a larger window · esc to close", Theme.muted, Theme.bg,
          width: {area.w - 1, 0}.max)
        return
      end
      Frame.card(screen, box, "SEARCH ALL PROJECTS", border: Theme.border_focus)
      render_query(screen, box)
      div_y = box.y + 2
      Frame.tee_divider(screen, box, div_y)
      screen.text(box.x + 2, div_y, " #{status_line} ", Theme.muted, Theme.panel, width: {box.w - 4, 1}.max)
      render_list(screen, box)
    end

    private def render_query(screen : Screen, box : Rect) : Nil
      y = box.y + 1
      screen.text(box.x + 2, y, "›", Theme.accent, Theme.panel)
      qx = box.x + 4
      qw = {box.right - 2 - qx, 1}.max
      if @field.value.empty? && @field.preedit.empty?
        screen.text(qx, y, "host, path or body text in every project…", Theme.muted, Theme.panel, width: qw)
        screen.cursor(qx, y)
      else
        screen.input_line(qx, y, @field.value, @field.caret, @field.preedit, Theme.text_bright, Theme.panel, width: qw)
      end
    end

    # The progress line on the divider: how far through the registry the search is, and what
    # it has found. Short needles say that bodies were not looked at, rather than leave an
    # empty list to be read as "no project ever saw this".
    def status_line : String
      total = @projects.size
      return ProjectPicker.plural_projects(total) unless @needle
      head = @running ? "scanning #{@scanned}/#{total}" : "#{@scanned}/#{total} searched"
      parts = [head, "#{@hits} hit#{@hits == 1 ? "" : "s"}"]
      parts << "#{@skipped} skipped" if @skipped > 0
      parts << "#{@unindexed} unindexed" if @unindexed > 0
      # A project with no body index was searched by host and path only, whatever the needle.
      parts << "#{@no_body} without a body index" if @no_body > 0
      parts << "host/path only" if (n = @needle) && !ProjectSearch.body_searchable?(n)
      parts.join(" · ")
    end

    private def render_list(screen : Screen, box : Rect) : Nil
      list_top = box.y + LIST_OFFSET
      h = list_height(box)
      @list_h = {h, 1}.max
      return if h <= 0
      if row_count == 0
        render_empty(screen, box, list_top, h)
        return
      end
      ensure_visible(h)
      selected = selected_index
      (0...h).each do |vi|
        ri = @scroll + vi
        break unless row = row?(ri)
        draw_row(screen, box, list_top + vi, row, ri == selected)
      end
    end

    private def render_empty(screen : Screen, box : Rect, y : Int32, h : Int32) : Nil
      msg, detail =
        if @needle.nil? && !pending?
          {"type to search the captured flows of every project",
           "host and path match from 1 character, bodies from #{QL::FTS_MIN_CHARS}"}
        elsif pending? || @running
          {"searching…", nil}
        else
          {"no flow matches in #{ProjectPicker.plural_projects(@projects.size)}", nil}
        end
      screen.text(box.x + 3, y, msg, Theme.muted, Theme.panel, width: {box.w - 5, 1}.max)
      screen.text(box.x + 3, y + 1, detail, Theme.muted, Theme.panel, width: {box.w - 5, 1}.max) if detail && h > 1
    end

    # Keep the cursor on screen, and its group's header with it when it is the group's first
    # hit — a hit row alone does not say which project it is in.
    private def ensure_visible(h : Int32) : Nil
      if sel = selected_index
        @scroll = Viewport.scroll_to_show(sel, @scroll, h, row_count)
        @scroll -= 1 if @scroll == sel && sel > 0 && row?(sel - 1).try(&.kind) == :header
      end
      @scroll = Viewport.clamp_scroll(@scroll, h, row_count)
    end

    private def draw_row(screen : Screen, box : Rect, y : Int32, row : Row, active : Bool) : Nil
      bg = active ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if active
      screen.cell(box.x + 1, y, active ? '▎' : ' ', Theme.accent, bg)
      case row.kind
      when :header  then draw_header(screen, box, y, row.result)
      when :skipped then draw_skipped(screen, box, y, row.result, bg)
      else
        if hit = row.hit
          draw_hit(screen, box, y, hit, active, bg)
        end
      end
    end

    private def label_width(box : Rect, meta : String) : Int32
      {box.w - 6 - Screen.display_width(meta) - 1, 1}.max
    end

    private def draw_header(screen : Screen, box : Rect, y : Int32, result : ProjectSearch::Result) : Nil
      n = result.hits.size
      # `+` only when the search stopped reading a project at the cap with more still matching.
      meta = "#{n}#{result.truncated ? "+" : ""} hit#{n == 1 ? "" : "s"}"
      meta += " · #{result.unindexed} unindexed" if result.unindexed > 0
      project = result.project
      label = ProjectPicker.fit_label(project.name, @labels[project.dir]?, label_width(box, meta))
      screen.text(box.x + 3, y, label, Theme.text_bright, Theme.panel, Attribute::Bold, width: label_width(box, meta))
      screen.text(box.right - 2 - Screen.display_width(meta), y, meta, Theme.muted, Theme.panel)
    end

    private def draw_skipped(screen : Screen, box : Rect, y : Int32, result : ProjectSearch::Result,
                             bg : Color) : Nil
      project = result.project
      label = ProjectPicker.labelled(project.name, @labels[project.dir]?)
      text = "skipped  #{label} — #{result.skipped}"
      screen.text(box.x + 3, y, text, Theme.yellow, bg, width: {box.w - 5, 1}.max)
    end

    private def draw_hit(screen : Screen, box : Rect, y : Int32, hit : ProjectSearch::Hit,
                         active : Bool, bg : Color) : Nil
      fg = active ? Theme.text_bright : Theme.text
      method_x = box.x + 5
      url_x = method_x + 8
      status, scolor = FlowStatus.cell(hit.status, hit.state)
      # A fixed right-hand block — status, then the match tag — so the status column lines up
      # whether or not a row carries the tag.
      right_x = box.right - 2 - 9
      screen.text(method_x, y, hit.method, Theme.method_color(hit.method), bg, width: 7)
      screen.text(url_x, y, "#{hit.host}#{Url.origin_path(hit.target)}", fg, bg, width: {right_x - 1 - url_x, 1}.max)
      screen.text(right_x, y, status, scolor, bg, width: 4)
      # Why a flow whose URL does not contain the needle is listed at all.
      screen.text(right_x + 5, y, "body", Theme.muted, bg) if hit.match.body?
    end
  end
end
