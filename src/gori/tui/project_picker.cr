require "termisu"
require "../project"
require "../project_registry"
require "../fuzzy"
require "./geometry"
require "./screen"
require "./theme"

module Gori::Tui
  # The startup screen: choose a project to open. New + Temp are always shown;
  # saved projects are live fuzzy-filtered (fzf-like subsequence via Gori::Fuzzy,
  # best score first) as you type. Letters always feed the filter (search focus wins;
  # no plain-letter shortcuts while the bar is active). Use arrows + ↵ on the
  # New/Temp rows, or ctrl-n/ctrl-t/ctrl-d. Returns the chosen Project from `run`,
  # or nil to quit gori. Monochrome, keyboard-first (Grok Build feel).
  class ProjectPicker
    def initialize(@term : Termisu, @registry : ProjectRegistry)
      @backend = TermisuBackend.new(@term)
      @projects = @registry.list
      @query = "" # drives live fuzzy filter over @projects (New/Temp unaffected)
      @selected = 0
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
      2 + filtered_projects.size # New, Temp, then (filtered) projects
    end

    # Saved projects filtered by @query using Gori::Fuzzy (only the variable part
    # of the list; New and Temp are always offered at indices 0/1).
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
      # Navigation is arrows only (like the command palette). Letter keys are
      # reserved for the live fuzzy filter so that searches like "test" don't
      # accidentally trigger 't' for temp etc.
      if key.up?
        @selected = (@selected - 1) % entry_count
      elsif key.down?
        @selected = (@selected + 1) % entry_count
      elsif key.enter?
        return activate
      elsif key.backspace?
        return if @query.empty?
        @query = @query[0, @query.size - 1]
        @selected = 0
      elsif key.escape?
        if @query.empty?
          return :quit
        else
          @query = ""
          @selected = 0
        end
      elsif ev.ctrl_c?
        return :quit
      elsif (c = key.to_char) && !ev.ctrl? && !ev.alt?
        # Printable chars always feed the query (search has priority).
        @query += c
        @selected = 0
      elsif ev.ctrl? && key.lower_n?
        # ctrl-n: quick new. If query has text, prefill (or direct-create).
        name = @query.strip
        if name.empty?
          start_new
        else
          return @registry.create(name)
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
      else
        filtered_projects[@selected - 2]?
      end
    end

    private def start_new : Nil
      @mode = :new
      @name = @query.strip
    end

    private def open_temp : Project
      @registry.temp(Random::Secure.hex(4))
    end

    private def delete_selected : Nil
      return if @selected < 2
      if project = filtered_projects[@selected - 2]?
        @registry.delete(project)
        @projects = @registry.list
        @selected = 0
      end
    end

    private def handle_new(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      if key.escape?
        @mode = :list
      elsif key.enter?
        name = @name.strip
        return @registry.create(name) unless name.empty?
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
    # Filter bar (› query_) is always shown for live fuzzy filtering of projects.
    private def render_list(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      fp = filtered_projects
      rows = list_rows
      has_saved = !fp.empty?
      visual = rows.size + (has_saved ? 1 : 0) # gap before saved projects
      header_lines = 3 # title, subtitle, filter bar
      top = {(h - (header_lines + visual)) // 2, 1}.max

      centered(screen, top, "gori", Theme::TEXT_BRIGHT, w, Attribute::Bold)
      centered(screen, top + 1, "free · open-source · human in the driver's seat", Theme::MUTED, w)

      # live fuzzy filter bar (fzf style)
      fy = top + 2
      screen.text(cx + 1, fy, "›", Theme::ACCENT, Theme::BG)
      screen.text(cx + 3, fy, @query, Theme::TEXT_BRIGHT, Theme::BG, width: cw - 5)
      screen.cell(cx + 3 + @query.size, fy, '_', Theme::ACCENT, Theme::BG)

      ey0 = top + 3
      rows.each_with_index do |(label, meta), i|
        y = ey0 + i + ((i >= 2 && has_saved) ? 1 : 0)
        next if y >= h - 1
        selected = i == @selected
        bg = selected ? Theme::ACCENT_BG : Theme::BG
        screen.fill(Rect.new(cx, y, cw, 1), bg) if selected
        screen.cell(cx + 1, y, selected ? '▸' : ' ', Theme::ACCENT, bg)
        screen.text(cx + 3, y, label, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg)
        screen.text(cx + cw - meta.size - 2, y, meta, Theme::MUTED, bg) unless meta.empty?
      end

      centered(screen, h - 2, "↑/↓ select   ↵ open   ctrl-n new   ctrl-t temp   ctrl-d delete   type to filter   esc/ctrl-c quit", Theme::MUTED, w)
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
      list = [{"+ New project", ""}, {"~ Temp project", "ephemeral · not saved"}]
      filtered_projects.each do |project|
        meta = project.last_modified.try { |t| relative_time(Time.utc - t) } || "new"
        list << {project.name, meta}
      end
      list
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
