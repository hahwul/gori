require "termisu"
require "../project"
require "../project_registry"
require "../fuzzy"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./confirm_dialog"

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
      @mode = :list # :list | :new | :confirm
      @name = ""
      @desc = ""
      @new_field = :name # :name | :desc (only in :new mode)
      @resized = false   # set on a Resize event → next frame full-repaints
      @preedit = ""      # live IME composing text for the active field (search/name/desc)
      # Delete confirmation (project deletion is irreversible — wipes its dir).
      @confirm = nil.as(ConfirmDialog?)
      @pending_delete = nil.as(Project?)
    end

    def run : Project?
      loop do
        render
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize
          # termisu already resized its buffer; force a full repaint next frame.
          @resized = true
        when Termisu::Event::Key
          result = case @mode
                   when :new     then handle_new(ev)
                   when :confirm then handle_confirm(ev)
                   else               handle_list(ev)
                   end
          case result
          when Project then return result
          when :quit   then return nil
          end
        when Termisu::Event::Preedit
          # Live IME composition for whichever field is active; the committed
          # syllable arrives afterwards as a normal Key and clears this.
          @preedit = ev.text
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
      @preedit = "" # any committed key ends an in-progress IME composition
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
      elsif (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt? && @selected == 2
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
        request_delete
      end
      nil
    end

    # Delete confirmation: ←/→ or Tab choose, `y` delete, `n`/esc cancel, ↵ acts
    # on the selection (which defaults to cancel). Other keys are swallowed.
    private def handle_confirm(ev : Termisu::Event::Key) : Project | Symbol | Nil
      @preedit = ""
      dlg = @confirm
      key = ev.key
      case
      when key.escape?, key.n?, ev.ctrl_c?                then cancel_confirm
      when key.y?                                         then commit_delete
      when key.left?, key.right?, key.tab?, key.back_tab? then dlg.try(&.move)
      when key.enter?
        (dlg.try(&.confirm_selected?)) ? commit_delete : cancel_confirm
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
      @desc = ""
      @new_field = :name
    end

    private def open_temp : Project
      @registry.temp(Random::Secure.hex(4))
    end

    # Create a project, swallowing an invalid-name error (e.g. a symbol-only name
    # that slugifies to empty) so the picker stays up instead of crashing the TUI.
    # Description is optional and passed through to init the project metadata.
    private def safe_create(name : String, description : String = "") : Project?
      @registry.create(name, description)
    rescue Gori::Error
      nil
    end

    # Open the delete-confirmation modal for the selected project (project
    # deletion wipes its directory — irreversible, so it's always confirmed).
    private def request_delete : Nil
      return if @selected < 3
      if project = filtered_projects[@selected - 3]?
        @confirm = ConfirmDialog.new("DELETE PROJECT",
          %(Delete "#{project.name}"?\nThis permanently removes all of its captured data.),
          confirm_label: "delete", cancel_label: "cancel", danger: true)
        @pending_delete = project
        @mode = :confirm
      end
    end

    private def commit_delete : Nil
      if project = @pending_delete
        @registry.delete(project)
        @projects = @registry.list
        @selected = 2
      end
      cancel_confirm
    end

    private def cancel_confirm : Nil
      @mode = :list
      @confirm = nil
      @pending_delete = nil
    end

    private def handle_new(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      @preedit = "" # any committed key ends an in-progress IME composition
      if key.escape?
        @mode = :list
      elsif key.enter?
        if @new_field == :name
          if !@name.strip.empty?
            @new_field = :desc
          end
        else
          # On desc field: create (description is optional/empty ok)
          name = @name.strip
          desc = @desc.strip
          if !name.empty? && (proj = safe_create(name, desc))
            return proj
          end
          # invalid → stay
        end
      elsif key.backspace?
        if @new_field == :name
          @name = @name[0, {@name.size - 1, 0}.max]
        else
          @desc = @desc[0, {@desc.size - 1, 0}.max]
        end
      elsif key.up? || key.down?
        @new_field = @new_field == :name ? :desc : :name
      elsif (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt?
        if @new_field == :name
          @name += c
        else
          @desc += c
        end
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
        @confirm.try(&.render(screen, Rect.new(0, 0, w, h))) if @mode == :confirm
      end
      # Sync the terminal hardware cursor to the focused caret so the terminal's
      # own IME composition UI (jamo/candidate popup) anchors at the right cell —
      # same as the Runner does for the in-app fields. When no field is focused
      # (e.g. New/Temp rows) hide the cursor so it doesn't linger at a stale spot.
      if pos = screen.desired_cursor
        @term.set_cursor(pos[0], pos[1], visible: true)
      else
        @term.hide_cursor
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

      # One rounded card holds the actions (New / Temp / Search), a tee divider,
      # then the scrollable project list — the same header + divider + list shape
      # the overlays use, so the picker matches the rest of the app.
      actions = 3
      res_rows = (h - 5 - 2 - actions - 1).clamp(1, 8) # 5: brand header + hints · 2: card borders
      card_h = actions + 1 + res_rows + 2
      top = {(h - (3 + card_h)) // 2, 0}.max

      centered(screen, top, "gori", Theme::TEXT_BRIGHT, w, Attribute::Bold)
      centered(screen, top + 1, "free · open-source · human in the driver's seat", Theme::MUTED, w)

      box = Rect.new(cx, top + 3, cw, card_h)
      Frame.card(screen, box)

      # action rows — selection indices 0=New, 1=Temp, 2=Search
      picker_row(screen, box, 0, "+ New project", "")
      picker_row(screen, box, 1, "~ Temp project", "ephemeral · not saved")
      render_search_row(screen, box)

      # divider with the result count embedded (mirrors how a card title rides the
      # top border)
      div_y = box.y + 1 + actions
      Frame.tee_divider(screen, box, div_y, bg: Theme::PANEL)
      count = @query.empty? ? "Projects (#{fp.size})" : "Matches (#{fp.size})"
      screen.text(box.x + 2, div_y, " #{count} ", Theme::MUTED, Theme::PANEL)
      list_top = div_y + 1

      ensure_results_visible(res_rows)
      if fp.empty?
        msg = @query.empty? ? "no projects yet" : "no matches"
        screen.text(box.x + 3, list_top, msg, Theme::MUTED, Theme::PANEL)
      else
        (0...res_rows).each do |vi|
          ri = @results_scroll + vi
          break if ri >= fp.size
          proj = fp[ri]
          py = list_top + vi
          is_selected = (ri + 3 == @selected)
          bg = is_selected ? Theme::ACCENT_BG : Theme::PANEL
          screen.fill(Rect.new(box.x + 1, py, cw - 2, 1), bg) if is_selected
          screen.cell(box.x + 1, py, is_selected ? '▎' : ' ', Theme::ACCENT, bg)
          meta = proj.last_modified.try { |t| relative_time(Time.utc - t) } || "new"
          mdw = Screen.display_width(meta)
          name_w = cw - 3 - (mdw + 2)
          screen.text(box.x + 3, py, proj.name, is_selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg, width: [name_w, 1].max)
          meta_x = box.right - mdw - 2
          screen.text(meta_x, py, meta, Theme::MUTED, bg) unless meta.empty?
        end
      end

      centered(screen, h - 2, "↑/↓ select   ↵ open   arrow to Search row then type   ctrl-n new   ctrl-t temp   ctrl-d delete   esc clear   ctrl-c quit", Theme::MUTED, w)
    end

    # One action/result row inside the picker card: selection band + ▎ bar, label
    # left, meta right. Row `idx` 0/1 are New/Temp (Search is its own renderer).
    private def picker_row(screen : Screen, box : Rect, idx : Int32, label : String, meta : String) : Nil
      y = box.y + 1 + idx
      selected = idx == @selected
      bg = selected ? Theme::ACCENT_BG : Theme::PANEL
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if selected
      screen.cell(box.x + 1, y, selected ? '▎' : ' ', Theme::ACCENT, bg)
      screen.text(box.x + 3, y, label, selected ? Theme::TEXT_BRIGHT : Theme::TEXT, bg)
      screen.text(box.right - meta.size - 2, y, meta, Theme::MUTED, bg) unless meta.empty?
    end

    # The search row (index 2): typing filters only when this row is selected.
    private def render_search_row(screen : Screen, box : Rect) : Nil
      y = box.y + 1 + 2
      selected = @selected == 2
      bg = selected ? Theme::ACCENT_BG : Theme::PANEL
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if selected
      screen.cell(box.x + 1, y, selected ? '▎' : ' ', Theme::ACCENT, bg)
      screen.text(box.x + 3, y, "›", selected ? Theme::ACCENT : Theme::MUTED, bg)
      qx = box.x + 5
      # When focused, always render via input_line — even when empty — so the
      # caret (and the terminal hardware cursor it sets) is anchored at the field.
      # Otherwise the terminal draws IME composition at a stale position (top-left).
      # The placeholder hint only shows when the row is not focused.
      if selected
        screen.input_line(qx, y, @query, @query.size, @preedit, Theme::TEXT_BRIGHT, bg, width: box.w - 7)
      elsif @query.empty?
        screen.text(qx, y, "search projects...", Theme::MUTED, bg)
      else
        screen.text(qx, y, @query, Theme::TEXT, bg, width: box.w - 7)
      end
    end

    private def render_new(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      top = {(h - 5) // 2, 1}.max
      centered(screen, top, "gori", Theme::TEXT_BRIGHT, w, Attribute::Bold)
      centered(screen, top + 2, "new project", Theme::MUTED, w)
      iy = top + 3
      # Two-row input area: name (required) + description (optional)
      screen.fill(Rect.new(cx, iy, cw, 3), Theme::PANEL)
      name_active = @new_field == :name
      name_fg = name_active ? Theme::TEXT_BRIGHT : Theme::TEXT
      name_prefix = "name › "
      screen.text(cx + 2, iy, name_prefix, name_fg, Theme::PANEL)
      nbase = cx + 2 + Screen.display_width(name_prefix)
      nwidth = {cw - Screen.display_width(name_prefix) - 2, 1}.max
      if name_active
        screen.input_line(nbase, iy, @name, @name.size, @preedit, name_fg, Theme::PANEL, width: nwidth)
      else
        screen.text(nbase, iy, @name, name_fg, Theme::PANEL, width: nwidth)
      end

      desc_active = @new_field == :desc
      desc_fg = desc_active ? Theme::TEXT_BRIGHT : Theme::TEXT
      if @desc.empty? && !desc_active
        screen.text(cx + 2, iy + 1, "description (optional) › ", desc_fg, Theme::PANEL)
      else
        desc_prefix = "description › "
        screen.text(cx + 2, iy + 1, desc_prefix, desc_fg, Theme::PANEL)
        dbase = cx + 2 + Screen.display_width(desc_prefix)
        dwidth = {cw - Screen.display_width(desc_prefix) - 2, 1}.max
        if desc_active
          screen.input_line(dbase, iy + 1, @desc, @desc.size, @preedit, desc_fg, Theme::PANEL, width: dwidth)
        else
          screen.text(dbase, iy + 1, @desc, desc_fg, Theme::PANEL, width: dwidth)
        end
      end

      hint = "↵ next/create   ↑/↓ fields   esc cancel"
      centered(screen, h - 2, hint, Theme::MUTED, w)
    end

    private def centered(screen : Screen, y : Int32, text : String, fg : Color, w : Int32,
                         attr : Attribute = Attribute::None) : Nil
      screen.text({(w - text.size) // 2, 0}.max, y, text, fg, Theme::BG, attr: attr)
    end

    private def ensure_results_visible(list_h : Int32) : Nil
      if @selected < 3
        @results_scroll = 0 # focus is on New/Temp/Search → show the list from the top
        return
      end
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
