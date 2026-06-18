require "termisu"
require "../project"
require "../project_registry"
require "../fuzzy"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"

module Gori::Tui
  # The startup screen: choose a project to open. New + Temp are always shown at
  # the top. Below them is a Search row (the "search area"). Arrow down to it to
  # "enter" search, then typing does fuzzy filter (Gori::Fuzzy, best-first) on the
  # projects listed below the search row. Search is *not* live on every keystroke
  # from anywhere (avoids the previous always-on filter which felt inconvenient).
  # Use arrows + ↵ , ctrl-n/ctrl-t/ctrl-d etc. Returns chosen Project or nil to quit.
  # Monochrome, keyboard-first (Grok Build feel).
  class ProjectPicker
    def initialize(@term : Termisu, @registry : ProjectRegistry)
      @backend = TermisuBackend.new(@term)
      @projects = @registry.list
      @query = "" # current search filter; only editable when Search row selected
      @selected = 0
      @results_scroll = 0
      @mode = :list # :list | :new
      @name = ""
      @resized = false # set on a Resize event → next frame full-repaints
    end

    def run : Project?
      loop do
        render
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize
          # termisu already resized its buffer; force a full repaint next frame.
          @resized = true
        when Termisu::Event::Key
          result = @mode == :new ? handle_new(ev) : handle_list(ev)
          case result
          when Project then return result
          when :quit   then return nil
          end
        end
      end
    end

    # --- input ---------------------------------------------------------------

    private def entry_count : Int32
      3 + filtered_projects.size # New, Temp, Search, then (filtered) projects
    end

    # Saved projects filtered by @query using Gori::Fuzzy.
    # List layout: 0=New, 1=Temp, 2=Search bar (typing only active here), 3+=projects.
    private def filtered_projects : Array(Project)
      return @projects if @query.empty?
      q = @query.downcase
      scored = @projects.compact_map do |p|
        if score = Gori::Fuzzy.score(q, p.name.downcase)
          {p, score}
        end
      end
      scored.sort_by! { |(_, score)| -score }.map { |(p, _)| p }
    end

    private def handle_list(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      # Navigation is arrows only. Search is *deliberate*: arrow down past New/Temp
      # to the Search row (index 2) to "enter" the search area. Only then does
      # typing perform fuzzy filtering on the projects listed below it.
      # This avoids the previous always-on live filter which was inconvenient.
      if key.up?
        @selected = (@selected - 1).clamp(0, entry_count - 1)
      elsif key.down?
        @selected = (@selected + 1).clamp(0, entry_count - 1)
      elsif key.enter?
        return activate
      elsif key.backspace?
        if @selected == 2 && !@query.empty?
          @query = @query[0, @query.size - 1]
          @selected = 2
          @results_scroll = 0
        end
      elsif key.escape?
        if @query.empty?
          return :quit
        else
          @query = ""
          @selected = 0
        end
      elsif ev.ctrl_c?
        return :quit
      elsif (c = key.to_char) && !ev.ctrl? && !ev.alt? && @selected == 2
        # Only when the Search row is selected (we have "entered" it).
        @query += c
        @selected = 2
        @results_scroll = 0
      elsif ev.ctrl? && key.lower_n?
        # ctrl-n: quick new. If query has text, prefill (or direct-create).
        name = @query.strip
        if name.empty?
          start_new
        elsif proj = safe_create(name)
          return proj
        end
      elsif ev.ctrl? && key.lower_t?
        return open_temp
      elsif ev.ctrl? && key.lower_d?
        delete_selected
      end
      nil
    end

    private def activate : Project?
      case @selected
      when 0
        start_new
        nil
      when 1
        open_temp
      when 2
        # Enter while on Search row: immediately pick the top match if any.
        # (Arrow down into the box if you want to choose a different result.)
        if filtered_projects.any?
          return filtered_projects[0]
        end
        nil
      else
        filtered_projects[@selected - 3]?
      end
    end

    private def start_new : Nil
      @mode = :new
      @name = @query.strip
    end

    private def open_temp : Project
      @registry.temp(Random::Secure.hex(4))
    end

    # Create a project, swallowing an invalid-name error (e.g. a symbol-only name
    # that slugifies to empty) so the picker stays up instead of crashing the TUI.
    private def safe_create(name : String) : Project?
      @registry.create(name)
    rescue Gori::Error
      nil
    end

    private def delete_selected : Nil
      return if @selected < 3
      if project = filtered_projects[@selected - 3]?
        @registry.delete(project)
        @projects = @registry.list
        @selected = 2
      end
    end

    private def handle_new(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      if key.escape?
        @mode = :list
      elsif key.enter?
        name = @name.strip
        if !name.empty? && (proj = safe_create(name))
          return proj
        end
        # invalid (e.g. symbol-only) name → stay in the new-project input
      elsif key.backspace?
        @name = @name[0, {@name.size - 1, 0}.max]
      elsif (c = key.to_char) && !ev.ctrl? && !ev.alt?
        @name += c
      end
      nil
    end

    # --- rendering -----------------------------------------------------------

    MENU_WIDTH = 50

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme::BG)
      cw = {w - 4, MENU_WIDTH}.min
      cx = {(w - cw) // 2, 0}.max
      if @mode == :new
        render_new(screen, cx, cw, w, h)
      else
        render_list(screen, cx, cw, w, h)
      end
      # Full repaint right after a resize (the diff renderer would leave stale
      # cells, especially for the centered layout); a cheap diff otherwise.
      if @resized
        @term.sync
        @resized = false
      else
        @term.render
      end
    end

    # Centered like a game main menu: title + menu block vertically centered,
    # the column itself horizontally centered, hints pinned to the bottom edge.
    #
    # Layout (search is *not* live-by-default):
    #   New
    #   Temp
    #   [blank for breathing room]
    #   🔍 Search   <--- arrow here ("enter" the search area) then type for fuzzy
    #   [gap]
    #   project matches (or all when no query)
    private def render_list(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      fp = filtered_projects
      rows = list_rows
      has_projects = !fp.empty?

      # Center the header part (title + top rows + search). Box height is capped so
      # the overall menu doesn't grow unbounded and centering stays reasonable.
      header_visual = 3 + 2                         # title/sub + new/temp/search + breathing
      top = {(h - (header_visual + 8)) // 2, 1}.max # assume ~8 for box

      centered(screen, top, "gori", Theme::TEXT_BRIGHT, w, Attribute::Bold)
      centered(screen, top + 1, "free · open-source · human in the driver's seat", Theme::MUTED, w)

      ey0 = top + 2
      search_y = nil
      rows.each_with_index do |(label, meta), i|
        if i > 2
          break
        end
        # Spacing: consecutive New/Temp, +1 blank before Search
        y = ey0 + i + (i >= 2 ? 1 : 0)
        next if y >= h - 1
        selected = i == @selected
        bg = selected ? Theme::ACCENT_BG : Theme::BG

        if i == 2
          search_y = y
          # Search row - the "area" under New/Temp. Typing only works when this
          # row is selected (we have entered the search).
          if selected
            screen.fill(Rect.new(cx, y, cw, 1), bg)
            screen.cell(cx, y, '▎', Theme::ACCENT, bg)
          end
          screen.text(cx + 2, y, "›", selected ? Theme::ACCENT : Theme::MUTED, bg)
          qx = cx + 4
          if @query.empty?
            screen.text(qx, y, "search projects...", Theme::MUTED, bg)
          else
            screen.text(qx, y, @query, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg, width: cw - 6)
            if selected
              screen.cell(qx + @query.size, y, '_', Theme::ACCENT, bg)
            end
          end
        else
          # New or Temp
          if selected
            screen.fill(Rect.new(cx, y, cw, 1), bg)
            screen.cell(cx, y, '▎', Theme::ACCENT, bg)
          end
          screen.text(cx + 2, y, label, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg)
          screen.text(cx + cw - meta.size - 2, y, meta, Theme::MUTED, bg) unless meta.empty?
        end
      end

      # Now draw the results as a bordered scrollable box below the search row.
      # Skip it entirely on a short terminal — clamp(4, available) would otherwise
      # return 4 even when `available` is smaller (clamp with min > max yields min),
      # drawing a box with no room.
      box_h = search_y ? {h - (search_y + 2) - 3, 8}.min : 0
      if search_y && box_h >= 4
        box_y = search_y + 2
        box = Rect.new(cx, box_y, cw, box_h)
        title = @query.empty? ? "Projects (#{fp.size})" : "Matches (#{fp.size})"
        Frame.card(screen, box, title)

        list_top = box.y + 1
        list_h = box.h - 2
        ensure_results_visible(list_h)

        if fp.empty?
          msg = @query.empty? ? "no projects yet" : "no matches"
          screen.text(box.x + 2, list_top, msg, Theme::MUTED, Theme::PANEL)
        else
          (0...list_h).each do |vi|
            ri = @results_scroll + vi
            break if ri >= fp.size
            proj = fp[ri]
            py = list_top + vi
            is_selected = (ri + 3 == @selected)
            bg = is_selected ? Theme::ACCENT_BG : Theme::PANEL
            screen.fill(Rect.new(box.x + 1, py, cw - 2, 1), bg) if is_selected
            screen.cell(box.x + 1, py, is_selected ? '▎' : ' ', Theme::ACCENT, bg)
            screen.text(box.x + 3, py, proj.name, is_selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg, width: cw - 8)
            meta = proj.last_modified.try { |t| relative_time(Time.utc - t) } || "new"
            screen.text(box.right - meta.size - 2, py, meta, Theme::MUTED, bg) unless meta.empty?
          end
        end
      end

      centered(screen, h - 2, "↑/↓ select   ↵ open   arrow to Search row then type   ctrl-n new   ctrl-t temp   ctrl-d delete   esc clear   ctrl-c quit", Theme::MUTED, w)
    end

    private def render_new(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      top = {(h - 5) // 2, 1}.max
      centered(screen, top, "gori", Theme::TEXT_BRIGHT, w, Attribute::Bold)
      centered(screen, top + 2, "new project", Theme::MUTED, w)
      iy = top + 3
      screen.fill(Rect.new(cx, iy, cw, 1), Theme::PANEL)
      cursor = screen.text(cx + 2, iy, "name › #{@name}", Theme::TEXT_BRIGHT, Theme::PANEL)
      screen.cell(cursor, iy, '_', Theme::ACCENT, Theme::PANEL)
      centered(screen, h - 2, "↵ create    esc cancel", Theme::MUTED, w)
    end

    private def centered(screen : Screen, y : Int32, text : String, fg : Color, w : Int32,
                         attr : Attribute = Attribute::None) : Nil
      screen.text({(w - text.size) // 2, 0}.max, y, text, fg, Theme::BG, attr: attr)
    end

    private def list_rows : Array({String, String})
      list = [
        {"+ New project", ""},
        {"~ Temp project", "ephemeral · not saved"},
        {"🔍 Search", @query.empty? ? "type to filter" : @query},
      ]
      filtered_projects.each do |project|
        meta = project.last_modified.try { |t| relative_time(Time.utc - t) } || "new"
        list << {project.name, meta}
      end
      list
    end

    private def ensure_results_visible(list_h : Int32) : Nil
      return if @selected < 3
      pi = @selected - 3
      total = filtered_projects.size
      if pi < @results_scroll
        @results_scroll = pi
      elsif pi >= @results_scroll + list_h
        @results_scroll = pi - list_h + 1
      end
      @results_scroll = 0 if @results_scroll < 0
      max_s = [total - list_h, 0].max
      @results_scroll = max_s if @results_scroll > max_s
    end

    private def relative_time(span : Time::Span) : String
      secs = span.total_seconds
      return "just now" if secs < 60
      return "#{(secs / 60).to_i}m ago" if secs < 3600
      return "#{(secs / 3600).to_i}h ago" if secs < 86_400
      "#{(secs / 86_400).to_i}d ago"
    end
  end
end
