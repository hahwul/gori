require "termisu"
require "../project"
require "../project_registry"
require "./geometry"
require "./screen"
require "./theme"

module Gori::Tui
  # The startup screen: choose a project to open. Entries are New, Temp, then the
  # existing projects. Returns the chosen Project from `run`, or nil to quit gori.
  # Monochrome, keyboard-first (Grok Build feel).
  class ProjectPicker
    def initialize(@term : Termisu, @registry : ProjectRegistry)
      @backend = TermisuBackend.new(@term)
      @projects = @registry.list
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
      2 + @projects.size # New, Temp, then projects
    end

    private def handle_list(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      if key.up? || key.lower_k?
        @selected = (@selected - 1) % entry_count
      elsif key.down? || key.lower_j?
        @selected = (@selected + 1) % entry_count
      elsif key.enter? || key.right? || key.lower_l?
        return activate
      elsif key.lower_n?
        start_new
      elsif key.lower_t?
        return open_temp
      elsif key.lower_d?
        delete_selected
      elsif key.lower_q? || key.escape? || ev.ctrl_c?
        return :quit
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
        @projects[@selected - 2]?
      end
    end

    private def start_new : Nil
      @mode = :new
      @name = ""
    end

    private def open_temp : Project
      @registry.temp(Random::Secure.hex(4))
    end

    private def delete_selected : Nil
      return if @selected < 2
      if project = @projects[@selected - 2]?
        @registry.delete(project)
        @projects = @registry.list
        @selected = @selected.clamp(0, entry_count - 1)
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
    private def render_list(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      rows = entries
      visual = rows.size + (@projects.empty? ? 0 : 1) # gap before saved projects
      top = {(h - (3 + visual)) // 2, 1}.max

      centered(screen, top, "gori", Theme::TEXT_BRIGHT, w, Attribute::Bold)
      centered(screen, top + 1, "free · open-source · human in the driver's seat", Theme::MUTED, w)

      ey0 = top + 3
      rows.each_with_index do |(label, meta), i|
        y = ey0 + i + (i >= 2 ? 1 : 0)
        next if y >= h - 1
        selected = i == @selected
        bg = selected ? Theme::ACCENT_BG : Theme::BG
        screen.fill(Rect.new(cx, y, cw, 1), bg) if selected
        screen.cell(cx + 1, y, selected ? '▸' : ' ', Theme::ACCENT, bg)
        screen.text(cx + 3, y, label, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg)
        screen.text(cx + cw - meta.size - 2, y, meta, Theme::MUTED, bg) unless meta.empty?
      end

      centered(screen, h - 2, "↑/↓ select   ↵ open   n new   t temp   d delete   q quit", Theme::MUTED, w)
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

    private def entries : Array({String, String})
      list = [{"+ New project", ""}, {"~ Temp project", "ephemeral · not saved"}]
      @projects.each do |project|
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
