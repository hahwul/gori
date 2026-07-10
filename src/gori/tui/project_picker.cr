require "termisu"
require "../capture_lock"
require "../capture_status"
require "../project"
require "../project_registry"
require "../fuzzy"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./confirm_dialog"
require "./settings_view"

module Gori::Tui
  # The startup screen: choose a project to open. New + Temp are always shown at
  # the top. Below them is a Search row (the "search area"). Arrow down to it to
  # "enter" search, then typing does fuzzy filter (Gori::Fuzzy, best-first) on the
  # projects listed below the search row. Search is *not* live on every keystroke
  # from anywhere (avoids the previous always-on filter which felt inconvenient).
  # Use arrows + ↵ , ctrl-n/ctrl-t/ctrl-d etc. Returns chosen Project or nil to quit.
  # Monochrome, keyboard-first (Grok Build feel).
  class ProjectPicker
    # Throttle flock + status-file probes so the 50 ms poll loop doesn't hammer
    # the filesystem on every visible project row every frame.
    RUNNING_PROBE_TTL = 400.milliseconds

    record RunningProbe, at : Time::Instant, held : Bool, status : CaptureStatus::Status?

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
      @settings = SettingsView.new # the config editor (ctrl-, → :settings mode)
      @running_cache = {} of String => RunningProbe
      @art_frame = 0 # entrance-animation clock for the brand art; advances each frame until ART_ANIM_DONE
    end

    def run : Project?
      loop do
        render
        # Drive the entrance animation off the idle poll cadence (~50 ms/frame):
        # the loop re-renders whenever poll_event times out, so bumping the clock
        # here plays the reveal once, then freezes at ART_ANIM_DONE (static after).
        @art_frame += 1 if @art_frame < ART_ANIM_DONE
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize
          # termisu already resized its buffer; force a full repaint next frame.
          @resized = true
        when Termisu::Event::Key
          result = case @mode
                   when :new      then handle_new(ev)
                   when :confirm  then handle_confirm(ev)
                   when :settings then handle_settings(ev)
                   else                handle_list(ev)
                   end
          case result
          when Project then return result
          when :quit   then return nil
          end
        when Termisu::Event::Mouse
          result = handle_picker_mouse(ev)
          case result
          when Project then return result
          when :quit   then return nil
          end
        when Termisu::Event::Preedit
          # Live IME composition for whichever field is active; the committed
          # syllable arrives afterwards as a normal Key and clears this.
          if @mode == :settings
            @settings.set_preedit(ev.text)
          else
            @preedit = ev.text
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
      @preedit = "" # any committed key ends an in-progress IME composition
      # Arrows are pure navigation (never filter). Typing a printable key jumps into
      # the Search row and filters — matching the "type to search" hint + the universal
      # picker expectation — so a user who lands on New/Temp and types a project name to
      # find it isn't met with silence. (↓ to the Search row also works.)
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
      elsif (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt?
        # Any printable key filters: enter the Search row (if not already) and append.
        @selected = 2
        @query += c
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
      elsif ev.ctrl? && key.comma?
        @settings.reload
        @mode = :settings
      end
      nil
    end

    # Settings (config) editor: ↑/↓ pick a field, type to edit, ↵ save, esc back.
    private def handle_settings(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      c = ev.char || key.to_char
      @preedit = ""
      if key.escape?
        @mode = :list
      elsif key.enter?
        @settings.save # the view shows its own saved/invalid status
      elsif key.up?
        @settings.move_field(-1)
      elsif key.down?
        @settings.move_field(1)
      elsif key.left?
        @settings.move_cursor(-1)
      elsif key.right?
        @settings.move_cursor(1)
      elsif key.backspace?
        @settings.backspace
      elsif ev.ctrl_c?
        return :quit
      elsif c && !ev.ctrl? && !ev.alt?
        @settings.insert(c)
        @settings.set_preedit("")
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
    rescue Gori::Error | IO::Error | DB::Error | SQLite3::Exception
      # An invalid name (Gori::Error) OR a filesystem/DB failure — mkdir_p on an
      # unwritable root, Store.open on a full/locked disk — must keep the picker up
      # instead of unwinding to the event loop and crashing the whole TUI.
      nil
    end

    # Open the delete-confirmation modal for the selected project (project
    # deletion wipes its directory — irreversible, so it's always confirmed).
    private def request_delete : Nil
      return if @selected < 3
      if project = filtered_projects[@selected - 3]?
        # Don't offer to delete a project another live instance is capturing into —
        # the green "● on" dot already flags it; deleting would silently orphan its
        # capture. (registry.delete also refuses, as a TOCTOU backstop below.)
        return if probe_running(project)[0]
        @confirm = ConfirmDialog.new("DELETE PROJECT",
          %(Delete "#{project.name}"?\nThis permanently removes all of its captured data.),
          confirm_label: "delete", cancel_label: "cancel", danger: true)
        @pending_delete = project
        @mode = :confirm
      end
    end

    private def commit_delete : Nil
      if project = @pending_delete
        begin
          @registry.delete(project) # refuses if a live instance took the lock since request_delete
          @projects = @registry.list
          invalidate_running_cache
          @selected = 2
        rescue Gori::Error
          # became live between confirm and here — leave it in place
        rescue IO::Error
          # rm_rf hit a real filesystem failure (permission, locked file) — keep the TUI
          # alive; refresh the list since the directory may be partially removed.
          @projects = @registry.list
          invalidate_running_cache
        end
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

    # --- mouse ---------------------------------------------------------------

    # Maps a click to a picker entry index (0=New, 1=Temp, 2=Search, 3+=projects),
    # or nil outside the rows. Inverts render_list's layout: action rows at box.y+1+i,
    # a divider, then the windowed project list (from @results_scroll) at box.y+5.
    private def entry_at(mx : Int32, my : Int32) : Int32?
      w, h = @backend.size
      box, res_rows = card_metrics(w, h)
      return nil unless box.contains?(mx, my)
      arow = my - (box.y + 1)
      return arow if 0 <= arow < 3 # New / Temp / Search action rows
      list_top = box.y + 1 + 3 + 1 # action rows + divider
      vi = my - list_top
      return nil if vi < 0 || vi >= res_rows
      ri = @results_scroll + vi
      ri < filtered_projects.size ? ri + 3 : nil
    end

    private def handle_picker_mouse(ev : Termisu::Event::Mouse) : Project | Symbol | Nil
      return nil unless ev.press? || ev.wheel?
      w, h = @backend.size
      mx, my = ev.x - 1, ev.y - 1
      if ev.wheel?
        return nil unless ev.button.wheel_up? || ev.button.wheel_down?
        return picker_wheel(ev.button.wheel_up? ? -3 : 3)
      end
      case @mode
      when :confirm  then handle_confirm_mouse(w, h, mx, my)
      when :settings then handle_settings_mouse(w, h, mx, my)
      when :new      then nil # text form — keyboard only (cursor placement is Phase 2)
      else                handle_list_mouse(mx, my)
      end
    end

    # List click: SELECT-FIRST — first click highlights the entry, a second click on
    # the already-selected entry activates it (same model as the History/Findings list).
    private def handle_list_mouse(mx : Int32, my : Int32) : Project | Symbol | Nil
      return nil unless idx = entry_at(mx, my)
      if idx == @selected
        activate
      else
        @selected = idx
        @results_scroll = 0 if idx < 3 # focusing an action row shows the list from the top
        nil
      end
    end

    private def picker_wheel(delta : Int32) : Nil
      case @mode
      when :settings      then @settings.move_field(delta)
      when :new, :confirm then nil # nothing to scroll
      else                     @selected = (@selected + delta).clamp(0, entry_count - 1)
      end
    end

    private def handle_confirm_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Nil
      dlg = @confirm
      return if dlg.nil?
      box = dlg.overlay_box(Rect.new(0, 0, w, h))
      return cancel_confirm unless box.contains?(mx, my) # click away → cancel
      case dlg.button_at(box, mx, my)
      when :confirm then commit_delete
      when :cancel  then cancel_confirm
      end
    end

    private def handle_settings_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Nil
      area = Rect.new(0, 0, w, h)
      box = @settings.overlay_box(area)
      if box.contains?(mx, my)
        if idx = @settings.field_at(box, mx, my)
          @settings.set_field(idx)
        end
      else
        @mode = :list # click outside the settings card → back to the list
      end
    end

    # --- rendering -----------------------------------------------------------

    MENU_WIDTH = 50

    # Decorative wordmark that rides above the "gori" title on the picker. Drawn
    # as a block (every line shares one left edge so the internal spacing — and
    # thus the shape — is preserved; per-line centering would shear it). Only
    # painted when the terminal has rows/cols to spare (see `art_shown?`); short
    # screens fall back to the plain wordmark. Kept in sync with `brand_h` so the
    # card geometry reserves exactly these rows above the card.
    # Shared with Help → About (see Brand). Aliased so the entrance timeline below
    # keeps deriving from the same figure.
    BRAND_ART = Brand::ART
    ART_H     = Brand::ART_H
    # Ink extent of the art: leftmost stroke column and inked width. Centering
    # uses these — not raw line widths — so the visible figure (rather than its
    # leading indentation) is what centres over the wordmark; raw-width centering
    # pushed the figure a few cells right of the wordmark's optical centre.
    ART_LEFT  = Brand::ART_LEFT
    ART_INK_W = Brand::ART_INK_W

    # Entrance effect — three phases on one frame clock (~50 ms/frame, the idle poll):
    #   1. Wave reveal: a diagonal front (top-left → bottom-right) materialises the
    #      art; each cell ramps ░▒▓ while its colour fades from near-canvas up to
    #      the accent, then locks to a solid block.
    #   2. Glint: a narrow focus_gold band sweeps the same diagonal once — light
    #      catching the finished mark.
    #   3. The wordmark, then the tagline, fade in beneath it (see render_list).
    # Every timeline constant derives from BRAND_ART, so swapping the art re-times
    # the entrance. ART_ANIM_DONE is the frame at which everything has resolved —
    # the run loop freezes @art_frame there, and past it the same code paints the
    # identical static logo (band swept out, full accent, text at full strength).
    ART_SHADES    = {'░', '▒', '▓'}
    ART_ROW_SLOPE = 2 # diagonal metric d = col + row * SLOPE — the front's tilt
    ART_STAGGER   = 4 # d-units the wave front advances per frame
    ART_MAX_D     = BRAND_ART.map_with_index { |line, row| line.rstrip.size - 1 + row * ART_ROW_SLOPE }.max
    REVEAL_DONE   = ART_MAX_D // ART_STAGGER + ART_SHADES.size + 1
    GLINT_BAND    = 6 # width of the light band, in d-units
    GLINT_SPEED   = 7 # d-units the band advances per frame
    GLINT_DONE    = REVEAL_DONE + (ART_MAX_D + GLINT_BAND) // GLINT_SPEED + 1
    # Text staging: the wordmark starts fading in as the wave crests, the tagline
    # one beat later; each fade spans TEXT_FADE frames. ART_ANIM_DONE covers the
    # slower of glint/tagline so neither can freeze mid-animation.
    TEXT_FADE      = 5
    WORDMARK_START = REVEAL_DONE - 3
    TAGLINE_START  = REVEAL_DONE + 1
    ART_ANIM_DONE  = {GLINT_DONE, TAGLINE_START + TEXT_FADE}.max
    # Nudge the whole hero (art + wordmark + card) a hair above dead-centre so the
    # logo reads as the focal point rather than floating mid-screen.
    ART_LIFT = 2
    # Blank rows between the art block and the "gori" wordmark, so the logo has a
    # little breathing room instead of sitting flush on the text.
    ART_GAP = 1
    # The strapline under the wordmark (fades in last during the entrance).
    TAGLINE = Brand::TAGLINE

    # The art is a nicety, not load-bearing — only show it when the terminal is
    # tall enough to keep a usable project list beneath this taller logo and wide
    # enough to fit the block without clipping; otherwise fall back to the wordmark.
    private def art_shown?(w : Int32, h : Int32) : Bool
      h >= 26 && w >= 32
    end

    # Rows reserved above the picker card for the brand block. With the art the
    # stack is [art][ART_GAP][gori][subtitle][gap]; without it just [gori][subtitle][gap].
    private def brand_h(w : Int32, h : Int32) : Int32
      art_shown?(w, h) ? ART_H + ART_GAP + 3 : 3
    end

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)
      cw = {w - 4, MENU_WIDTH}.min
      cx = {(w - cw) // 2, 0}.max
      if @mode == :new
        render_new(screen, cx, cw, w, h)
      else
        render_list(screen, cx, cw, w, h)
        @confirm.try(&.render(screen, Rect.new(0, 0, w, h))) if @mode == :confirm
        @settings.render(screen, Rect.new(0, 0, w, h)) if @mode == :settings
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
    # The picker card rect + the number of project rows it shows, for `w`×`h`. The
    # ONE source of this geometry — render_list and the mouse hit-test (entry_at)
    # both call it so a click maps to exactly the row that was drawn.
    private def card_metrics(w : Int32, h : Int32) : {Rect, Int32}
      cw = {w - 4, MENU_WIDTH}.min
      cx = {(w - cw) // 2, 0}.max
      actions = 3
      bh = brand_h(w, h) # rows reserved above the card for the brand block
      # The taller art block sits low enough that a naive centering would let the
      # card bottom reach the hint row (h-2), so claw back 2 extra rows when it's
      # shown to keep a clear gap. (Base header path stays h-5-2-… unchanged.)
      bottom_gap = art_shown?(w, h) ? 2 : 0
      res_rows = (h - bh - 2 - 2 - actions - 1 - bottom_gap).clamp(1, 8) # bh: brand block · 2: card borders
      card_h = actions + 1 + res_rows + 2
      # Bias the hero slightly above centre when the art shows, but keep at least
      # one blank row above it so it never slams flush against the top edge.
      lift = art_shown?(w, h) ? ART_LIFT : 0
      floor = art_shown?(w, h) ? 1 : 0
      top = {(h - (bh + card_h)) // 2 - lift, floor}.max
      {Rect.new(cx, top + bh, cw, card_h), res_rows}
    end

    private def render_list(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      fp = filtered_projects

      # One rounded card holds the actions (New / Temp / Search), a tee divider,
      # then the scrollable project list — the same header + divider + list shape
      # the overlays use, so the picker matches the rest of the app.
      actions = 3
      box, res_rows = card_metrics(w, h)
      top = box.y - 3 # the "𝓰𝓸𝓻𝓲" wordmark sits 3 rows above the card

      # The decorative art (when it fits) sits ART_GAP rows above the wordmark;
      # card_metrics reserved ART_H + ART_GAP rows above `top` for exactly this.
      # Keep the whole logo stack (art + wordmark + tagline) on the canvas bg — no
      # lifted panel band — so the mark reads against the same field as the body.
      hero_top = art_shown?(w, h) ? top - ART_H - ART_GAP : top
      if hero_top < box.y
        screen.fill(Rect.new(0, hero_top, w, box.y - hero_top), Theme.bg)
      end
      draw_brand_art(screen, top - ART_H - ART_GAP, w, @art_frame) if art_shown?(w, h)
      render_hero_text(screen, top, w, h)

      Frame.card(screen, box)

      # action rows — selection indices 0=New, 1=Temp, 2=Search
      picker_row(screen, box, 0, "+ New project", "")
      picker_row(screen, box, 1, "~ Temp project", "ephemeral · not saved")
      render_search_row(screen, box)

      # divider with the result count embedded (mirrors how a card title rides the
      # top border)
      div_y = box.y + 1 + actions
      Frame.tee_divider(screen, box, div_y, bg: Theme.panel)
      count = @query.empty? ? "Projects (#{fp.size})" : "Matches (#{fp.size})"
      screen.text(box.x + 2, div_y, " #{count} ", Theme.muted, Theme.panel)
      list_top = div_y + 1

      ensure_results_visible(res_rows)
      if fp.empty?
        msg = @query.empty? ? "no projects yet" : "no matches"
        screen.text(box.x + 3, list_top, msg, Theme.muted, Theme.panel)
      else
        (0...res_rows).each do |vi|
          ri = @results_scroll + vi
          break if ri >= fp.size
          proj = fp[ri]
          py = list_top + vi
          is_selected = (ri + 3 == @selected)
          bg = is_selected ? Theme.accent_bg : Theme.panel
          screen.fill(Rect.new(box.x + 1, py, cw - 2, 1), bg) if is_selected
          screen.cell(box.x + 1, py, is_selected ? '▎' : ' ', Theme.accent, bg)
          meta, meta_fg = project_meta(proj)
          mdw = Screen.display_width(meta)
          name_w = cw - 3 - (mdw + 2)
          screen.text(box.x + 3, py, proj.name, is_selected ? Theme.text_bright : Theme.text, bg, width: [name_w, 1].max)
          meta_x = box.right - mdw - 2
          screen.text(meta_x, py, meta, meta_fg, bg) unless meta.empty?
        end
      end

      centered(screen, h - 2, "↑/↓ select   ↵ open   type to search   ctrl-n new   ctrl-t temp   ctrl-d delete   ctrl-, settings   ctrl-c quit", Theme.muted, w)
    end

    # One action/result row inside the picker card: selection band + ▎ bar, label
    # left, meta right. Row `idx` 0/1 are New/Temp (Search is its own renderer).
    private def picker_row(screen : Screen, box : Rect, idx : Int32, label : String, meta : String) : Nil
      y = box.y + 1 + idx
      selected = idx == @selected
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if selected
      screen.cell(box.x + 1, y, selected ? '▎' : ' ', Theme.accent, bg)
      screen.text(box.x + 3, y, label, selected ? Theme.text_bright : Theme.text, bg)
      screen.text(box.right - meta.size - 2, y, meta, Theme.muted, bg) unless meta.empty?
    end

    # The search row (index 2): typing filters only when this row is selected.
    private def render_search_row(screen : Screen, box : Rect) : Nil
      y = box.y + 1 + 2
      selected = @selected == 2
      bg = selected ? Theme.accent_bg : Theme.panel
      screen.fill(Rect.new(box.x + 1, y, box.w - 2, 1), bg) if selected
      screen.cell(box.x + 1, y, selected ? '▎' : ' ', Theme.accent, bg)
      screen.text(box.x + 3, y, "›", selected ? Theme.accent : Theme.muted, bg)
      qx = box.x + 5
      # When focused, always render via input_line — even when empty — so the
      # caret (and the terminal hardware cursor it sets) is anchored at the field.
      # Otherwise the terminal draws IME composition at a stale position (top-left).
      # The placeholder hint only shows when the row is not focused.
      if selected
        screen.input_line(qx, y, @query, @query.size, @preedit, Theme.text_bright, bg, width: box.w - 7)
      elsif @query.empty?
        screen.text(qx, y, "search projects...", Theme.muted, bg)
      else
        screen.text(qx, y, @query, Theme.text, bg, width: box.w - 7)
      end
    end

    private def render_new(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      top = {(h - 5) // 2, 1}.max
      Chrome.render_wordmark(screen, 0, top, center_w: w, bg: Theme.bg)
      centered(screen, top + 2, "new project", Theme.muted, w)
      iy = top + 3
      # Two-row input area: name (required) + description (optional)
      screen.fill(Rect.new(cx, iy, cw, 3), Theme.panel)
      name_active = @new_field == :name
      name_fg = name_active ? Theme.text_bright : Theme.text
      name_prefix = "name › "
      screen.text(cx + 2, iy, name_prefix, name_fg, Theme.panel)
      nbase = cx + 2 + Screen.display_width(name_prefix)
      nwidth = {cw - Screen.display_width(name_prefix) - 2, 1}.max
      if name_active
        screen.input_line(nbase, iy, @name, @name.size, @preedit, name_fg, Theme.panel, width: nwidth)
      else
        screen.text(nbase, iy, @name, name_fg, Theme.panel, width: nwidth)
      end

      desc_active = @new_field == :desc
      desc_fg = desc_active ? Theme.text_bright : Theme.text
      if @desc.empty? && !desc_active
        screen.text(cx + 2, iy + 1, "description (optional) › ", desc_fg, Theme.panel)
      else
        desc_prefix = "description › "
        screen.text(cx + 2, iy + 1, desc_prefix, desc_fg, Theme.panel)
        dbase = cx + 2 + Screen.display_width(desc_prefix)
        dwidth = {cw - Screen.display_width(desc_prefix) - 2, 1}.max
        if desc_active
          screen.input_line(dbase, iy + 1, @desc, @desc.size, @preedit, desc_fg, Theme.panel, width: dwidth)
        else
          screen.text(dbase, iy + 1, @desc, desc_fg, Theme.panel, width: dwidth)
        end
      end

      hint = "↵ next/create   ↑/↓ fields   esc cancel"
      centered(screen, h - 2, hint, Theme.muted, w)
    end

    private def centered(screen : Screen, y : Int32, text : String, fg : Color, w : Int32,
                         attr : Attribute = Attribute::None) : Nil
      screen.text({(w - text.size) // 2, 0}.max, y, text, fg, Theme.bg, attr: attr)
    end

    # Draw BRAND_ART as one centered block: every line starts at the same left
    # edge (derived from the ink extent — see ART_LEFT/ART_INK_W) so the figure
    # keeps its shape rather than each row centering on its own width. Accent
    # colour so it reads as a logo mark distinct from the wordmark beneath it.
    #
    # `frame` drives the entrance (see the timeline constants above): the diagonal
    # wave front reveals cells by their d-coordinate, each ramping ░▒▓ and fading
    # up to the accent before locking solid; the glint band then sweeps the same
    # diagonal once. Past ART_ANIM_DONE every cell is solid accent, so the same
    # call renders the final static logo.
    private def draw_brand_art(screen : Screen, y : Int32, w : Int32, frame : Int32) : Nil
      x = {(w - ART_INK_W) // 2 - ART_LEFT, 0}.max
      BRAND_ART.each_with_index do |line, i|
        line.each_char_with_index do |ch, col|
          next if ch == ' '
          d = col + i * ART_ROW_SLOPE
          prog = frame - d // ART_STAGGER
          next if prog <= 0 # not yet reached by the wave front
          glyph, fg = art_cell(prog)
          fg = glint_tint(d, frame, fg) if glyph == '█'
          screen.cell(x + col, y + i, glyph, fg, Theme.bg, attr: Attribute::Bold)
        end
      end
    end

    # Shade + colour for a cell `prog` frames after the wave front reached it:
    # ░▒▓ ramping from a dim accent up toward full strength, then a solid block.
    private def art_cell(prog : Int32) : {Char, Color}
      return {'█', Theme.accent} if prog > ART_SHADES.size
      t = 0.35 + 0.65 * prog / (ART_SHADES.size + 1)
      {ART_SHADES[prog - 1], Theme.blend(Theme.accent, Theme.bg, t)}
    end

    # 0..1 progress of a text fade that starts at frame `start` and spans TEXT_FADE.
    private def fade_t(start : Int32) : Float64
      ((@art_frame - start) / TEXT_FADE.to_f).clamp(0.0, 1.0)
    end

    # The wordmark + tagline under the art. With the art shown they stage in —
    # the wordmark fades up as the wave crests, the tagline one beat later — each
    # skipped while still fully transparent. At ART_ANIM_DONE both fades sit at
    # 1.0, i.e. the same static render as the no-art path, which skips the
    # entrance entirely (short/narrow terminals shouldn't wait on a flourish).
    private def render_hero_text(screen : Screen, top : Int32, w : Int32, h : Int32) : Nil
      unless art_shown?(w, h)
        Chrome.render_wordmark(screen, 0, top, center_w: w, bg: Theme.bg)
        centered(screen, top + 1, TAGLINE, Theme.muted, w)
        return
      end
      if (t = fade_t(WORDMARK_START)) > 0
        Chrome.render_wordmark(screen, 0, top, center_w: w, bg: Theme.bg,
          fg: Theme.blend(Theme.text_bright, Theme.bg, t))
      end
      if (t = fade_t(TAGLINE_START)) > 0
        centered(screen, top + 1, TAGLINE, Theme.blend(Theme.muted, Theme.bg, t), w)
      end
    end

    # The glint: a GLINT_BAND-wide focus_gold band sweeping down the diagonal after
    # the reveal — brightest at its leading edge, trailing back off to the accent.
    # A no-op before the sweep starts and after the band has left the art, so the
    # frozen frame is pure accent.
    private def glint_tint(d : Int32, frame : Int32, fg : Color) : Color
      return fg if frame <= REVEAL_DONE
      dist = (frame - REVEAL_DONE) * GLINT_SPEED - d
      return fg if dist < 0 || dist >= GLINT_BAND
      Theme.blend(Theme.focus_gold, Theme.accent, 1.0 - dist / GLINT_BAND.to_f)
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

    private def invalidate_running_cache : Nil
      @running_cache.clear
    end

    private def project_meta(proj : Project) : {String, Color}
      held, status = probe_running(proj)
      if held
        if status && status.listening
          {"● #{CaptureStatus.format_endpoint(status.host, status.port)}", Theme.green}
        elsif status
          {"● off · #{CaptureStatus.format_endpoint(status.host, status.port)}", Theme.yellow}
        else
          {"● off", Theme.yellow}
        end
      else
        meta = proj.last_modified.try { |t| relative_time(Time.utc - t) } || "new"
        {meta, Theme.muted}
      end
    end

    private def probe_running(proj : Project) : {Bool, CaptureStatus::Status?}
      now = Time.instant
      if cached = @running_cache[proj.dir]?
        return {cached.held, cached.status} if now - cached.at < RUNNING_PROBE_TTL
      end
      held, status = fetch_running(proj.dir)
      @running_cache[proj.dir] = RunningProbe.new(at: now, held: held, status: status)
      {held, status}
    end

    private def fetch_running(dir : String) : {Bool, CaptureStatus::Status?}
      held = CaptureLock.held?(dir)
      return {false, nil} unless held
      status = CaptureStatus.read(dir)
      status ||= CaptureStatus.read(dir) # retry once after a concurrent write
      {true, status}
    rescue IO::Error | File::Error
      {false, nil}
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
