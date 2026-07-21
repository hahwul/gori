require "termisu"
require "../capture_lock"
require "../capture_status"
require "../project"
require "../project_registry"
require "../update"
require "../fuzzy"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./confirm_dialog"
require "./settings_view"
require "./preferences_view"
require "./compact_overlay"

module Gori::Tui
  # The startup screen: choose a project to open. New + Temp are always shown at
  # the top. Below them is a Search row (the "search area"). Arrow down to it to
  # "enter" search, then typing does fuzzy filter (Gori::Fuzzy, best-first) on the
  # projects listed below the search row. Search is *not* live on every keystroke
  # from anywhere (avoids the previous always-on filter which felt inconvenient).
  # On a project row, Space opens a small action menu (open / rename / delete) —
  # same discovery surface as the in-session space menu, scoped to the picker.
  # Use arrows + ↵ , Space, ctrl-n/ctrl-t/ctrl-d etc. Returns chosen Project or nil
  # to quit. Monochrome, keyboard-first (Grok Build feel).
  class ProjectPicker
    # Throttle flock + status-file probes so the 50 ms poll loop doesn't hammer
    # the filesystem on every visible project row every frame.
    RUNNING_PROBE_TTL = 400.milliseconds

    record RunningProbe, at : Time::Instant, held : Bool, status : CaptureStatus::Status?

    # One row in the project-list space menu (mnemonic key → action).
    record SpaceEntry, key : Char, label : String, action : Symbol

    # One token of the footer hint row. `action` non-nil → a click on the token runs it;
    # inert tokens ("↑/↓ select", "type to search") describe a gesture with no single thing
    # to press, so they swallow no clicks. `action` is HIT-TEST METADATA ONLY — the row
    # paints exactly as it always did. (A lifted band marking the pressable tokens was
    # tried and dropped for the same reason as the top bar's: it only earns its keep next
    # to a hover highlight, which termisu can't report. See `Chrome::Chip`.)
    record HintToken, label : String, action : Symbol? = nil

    SPACE_ENTRIES = [
      SpaceEntry.new('o', "Open", :open),
      SpaceEntry.new('r', "Rename", :rename),
      SpaceEntry.new('c', "Compress", :compress),
      SpaceEntry.new('d', "Delete", :delete),
    ]

    def initialize(@term : Termisu, @registry : ProjectRegistry)
      # Held as the base Backend: TermisuBackend is generic over the terminal type.
      @backend = TermisuBackend.new(@term).as(Backend)
      @projects = @registry.list
      @query = "" # current search filter; only editable when Search row selected
      @selected = 0
      @results_scroll = 0
      @mode = :list # :list | :new | :confirm | :space | :rename | :settings | :theme | :compress | :measuring | :compressing
      @name = ""
      @desc = ""
      @new_field = :name # :name | :desc (only in :new mode)
      @resized = false   # set on a Resize event → next frame full-repaints
      @preedit = ""      # live IME composing text for the active field (search/name/desc)
      # Delete confirmation (project deletion is irreversible — wipes its dir).
      @confirm = nil.as(ConfirmDialog?)
      @pending_delete = nil.as(Project?)
      # Space menu over a project row (open/rename/compress/delete).
      @space_selected = 0
      @space_project = nil.as(Project?)
      # Compress scope popup (space → Compress): choose what to strip, confirm, VACUUM.
      # The picker holds no open Store, so it acts on the project's db file directly.
      @compact = nil.as(CompactOverlay?)
      @compact_project = nil.as(Project?)
      @pending_compact = nil.as(Store::CompactPlan?)
      # Which action a shared ConfirmDialog commits (:delete wipes the dir, :compress runs Store.compact).
      @confirm_kind = :delete
      # Transient one-line result shown above the hint after a compaction (green ok / red fail),
      # cleared on the next list keystroke.
      @flash = nil.as(String?)
      @flash_ok = true
      # Rename prompt (display name only — directory slug stays put).
      @pending_rename = nil.as(Project?)
      @rename_name = ""
      # The SAME unified Preferences modal used in-app (Ctrl+,), so pre-project settings
      # aren't a separate surface. Only :theme is allowed as an opener here — the picker
      # can host the theme card (below); it has no tabs/hosts/env/hotkeys editors, so those
      # rows stay hidden.
      @preferences = PreferencesView.new(Set{:theme})
      @theme_card = SettingsView.new # the theme picker opened from the modal's Theme row
      @theme_restore = ""            # active theme name to revert to on esc (live preview)
      @running_cache = {} of String => RunningProbe
      @art_frame = 0  # entrance-animation clock for the brand art; advances each frame until ART_ANIM_DONE
      @star_frame = 0 # starfield twinkle clock; unlike @art_frame it never freezes (wraps via &+)
      # Startup update check (see start_update_check / reconcile_update_check / the
      # notice in render_list). The background fiber only writes @remote_latest +
      # @remote_ready; every Settings mutation stays on the main fiber.
      @update_started = false          # guard: kick the check off exactly once
      @update_reconciled = false       # guard: fold the result in exactly once
      @remote_latest = nil.as(String?) # fetched (or cached) latest version, normalized
      @remote_ready = false            # set last by the producer so the reader sees a consistent pair
      @fetched_live = false            # true when @remote_latest came from a live fetch (→ refresh the cache)
      @update_notice = nil.as(String?) # the one-line notice text, once a fresh update is available
      @update_notice_version = ""      # the version the notice is for (persisted as the read-once marker)
      @notice_persisted = false        # guard: write the read-once marker after the notice's first real paint
    end

    # Once-a-day cache window: skip the network probe when the last successful check
    # is this recent (still surfaces a not-yet-notified update from the cached value).
    UPDATE_CHECK_TTL = 24 * 60 * 60

    def run : Project?
      start_update_check
      loop do
        reconcile_update_check
        render
        # Drive the entrance animation off the idle poll cadence (~50 ms/frame):
        # the loop re-renders whenever poll_event times out, so bumping the clock
        # here plays the reveal once, then freezes at ART_ANIM_DONE (static after).
        @art_frame += 1 if @art_frame < ART_ANIM_DONE
        @star_frame &+= 1
        case ev = @term.poll_event(50)
        when Termisu::Event::Resize
          # termisu already resized its buffer to these dims; re-fit the backend grids in
          # lockstep off the same event dims, and force a full repaint next frame.
          @backend.resize(ev.width, ev.height)
          @resized = true
        when Termisu::Event::Key
          result = case @mode
                   when :new      then handle_new(ev)
                   when :confirm  then handle_confirm(ev)
                   when :settings then handle_preferences(ev)
                   when :theme    then handle_theme(ev)
                   when :space    then handle_space(ev)
                   when :rename   then handle_rename(ev)
                   when :compress then handle_compress(ev)
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
            @preferences.set_preedit(ev.text)
          else
            @preedit = ev.text
          end
        end
      end
    end

    # --- update check --------------------------------------------------------

    # Kick the startup update probe off exactly once (from `run`, not `initialize`,
    # so a picker built in a spec never phones home). A fresh cache is used inline
    # (no network); otherwise a background fiber fetches the latest release version
    # and hands it back via @remote_latest/@remote_ready — no Settings I/O here.
    private def start_update_check : Nil
      return if @update_started
      @update_started = true
      return unless Settings.update_check_enabled?

      now = Time.utc.to_unix
      cached = Settings.update_latest_seen
      if !cached.empty? && (now - Settings.update_checked_at) < UPDATE_CHECK_TTL
        @remote_latest = cached
        @remote_ready = true
        return
      end

      spawn(name: "gori-update-check") do
        latest = Update.latest_version # nil on any failure (offline, rate-limited, …)
        @remote_latest = latest
        @fetched_live = true
        @remote_ready = true # set last so the reader never sees a half-written pair
      end
    end

    # Fold a ready result in once, on the main fiber: refresh the day cache after a
    # live fetch, then decide whether a fresh, not-yet-notified update should show.
    # The marker itself is persisted only when the notice actually paints (render_list).
    private def reconcile_update_check : Nil
      return unless @remote_ready
      return if @update_reconciled
      @update_reconciled = true

      latest = @remote_latest
      return unless latest # failed fetch → nothing to show, cache untouched (retry next launch)

      if @fetched_live
        Settings.update_latest_seen = latest
        Settings.update_checked_at = Time.utc.to_unix
        Settings.save
      end

      if nv = Update.notice_version(Gori::VERSION, latest, Settings.update_notified_version)
        @update_notice_version = nv
        @update_notice = "update available: v#{Update.normalize_version(Gori::VERSION)} → v#{nv} · run: gori update"
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
      @flash = nil  # a fresh keystroke dismisses the last compaction result line
      # Arrows are pure navigation (never filter). Typing a printable key jumps into
      # the Search row and filters — matching the "type to search" hint + the universal
      # picker expectation — so a user who lands on New/Temp and types a project name to
      # find it isn't met with silence. (↓ to the Search row also works.)
      # Space on a project row opens the action menu (open/rename/delete); on the
      # Search row it types a literal space into the query.
      if key.up?
        @selected = (@selected - 1).clamp(0, entry_count - 1)
      elsif key.down?
        @selected = (@selected + 1).clamp(0, entry_count - 1)
      elsif key.enter?
        return activate
      elsif key.space? && !ev.ctrl? && !ev.alt?
        if @selected >= 3
          open_space_menu
        elsif @selected == 2
          @query += " "
          @results_scroll = 0
        end
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
        @preferences.open_default
        @mode = :settings
      end
      nil
    end

    # The unified Preferences modal (Ctrl+,). The view handles editing/navigation itself;
    # we act on its Outcome — :close pops back to the list, :open (only :theme is allowed
    # here) opens the theme card, a save just persists (no live proxy to re-apply
    # pre-project). ^C still quits the picker.
    private def handle_preferences(ev : Termisu::Event::Key) : Project | Symbol | Nil
      return :quit if ev.ctrl_c?
      @preedit = "" # a committed key ends any in-progress IME composition (the modal owns its own)
      outcome = @preferences.handle_key(ev)
      case outcome.kind
      when :close then @mode = :list
      when :saved
        @resized = true # a saved Display/Layout pref may change how the picker draws
        # Mouse capture is armed once for the whole process in `App` and reconciled only
        # by the in-app save seam, so toggling it here used to persist and do nothing —
        # not even after opening a project — leaving native text selection broken for the
        # rest of the session with no hint that a restart was needed.
        Settings.mouse ? @term.enable_mouse : @term.disable_mouse
      when :open
        if outcome.section == :theme
          @theme_card.reload(:theme)
          @theme_restore = Settings.theme # revert target if the user cancels
          @mode = :theme
        end
      end
      nil
    end

    # The theme card opened from the modal's Theme row: ↑/↓ preview, ↵ apply + persist,
    # esc reverts. Mirrors the in-app theme editor, minus the proxy/toast.
    private def handle_theme(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      return :quit if ev.ctrl_c?
      if key.escape?
        Theme.apply(@theme_restore) # drop the live preview
        @resized = true
        @mode = :settings # back to the modal (still on the Appearance/Theme row)
      elsif key.enter?
        @theme_card.save # persists Settings.theme = selection
        Theme.apply(Settings.theme)
        @theme_restore = Settings.theme
        @resized = true
        @mode = :settings
      elsif key.up?
        @theme_card.move_field(-1)
        preview_theme
      elsif key.down?
        @theme_card.move_field(1)
        preview_theme
      end
      nil
    end

    # Live-apply the highlighted theme so the whole picker previews it before committing.
    private def preview_theme : Nil
      if name = @theme_card.theme_value
        Theme.apply(name)
        @resized = true
      end
    end

    # Delete confirmation: ←/→ or Tab choose, `y` delete, `n`/esc cancel, ↵ acts
    # on the selection (which defaults to cancel). Other keys are swallowed.
    private def handle_confirm(ev : Termisu::Event::Key) : Project | Symbol | Nil
      @preedit = ""
      dlg = @confirm
      key = ev.key
      case
      when key.escape?, key.n?, ev.ctrl_c?                then cancel_confirm
      when key.y?                                         then commit_confirmed
      when key.left?, key.right?, key.tab?, key.back_tab? then dlg.try(&.move)
      when key.enter?
        (dlg.try(&.confirm_selected?)) ? commit_confirmed : cancel_confirm
      end
      nil
    end

    # Runs the action the shared ConfirmDialog was opened for — delete wipes the
    # project dir, compress strips + VACUUMs its db in place.
    private def commit_confirmed : Nil
      case @confirm_kind
      when :compress then commit_compress
      else                commit_delete
      end
    end

    # Project-row space menu: ↑/↓ move, mnemonic key or ↵ run, esc dismiss.
    private def handle_space(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      @preedit = ""
      if key.escape? || ev.ctrl_c?
        close_space_menu
      elsif key.up?
        @space_selected = (@space_selected - 1).clamp(0, SPACE_ENTRIES.size - 1)
      elsif key.down?
        @space_selected = (@space_selected + 1).clamp(0, SPACE_ENTRIES.size - 1)
      elsif key.enter?
        return activate_space_entry(SPACE_ENTRIES[@space_selected])
      elsif (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt?
        if entry = SPACE_ENTRIES.find { |e| e.key == c.downcase }
          return activate_space_entry(entry)
        end
      end
      nil
    end

    # Rename prompt: type a new display name, ↵ commit, esc cancel.
    private def handle_rename(ev : Termisu::Event::Key) : Project | Symbol | Nil
      key = ev.key
      @preedit = ""
      if key.escape?
        cancel_rename
      elsif key.enter?
        commit_rename
      elsif key.backspace?
        @rename_name = @rename_name[0, {@rename_name.size - 1, 0}.max]
      elsif ev.ctrl_c?
        return :quit
      elsif (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt?
        @rename_name += c
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
    # When `project` is passed (space menu), use that; otherwise the list selection.
    private def request_delete(project : Project? = nil) : Nil
      target = project
      if target.nil?
        return if @selected < 3
        target = filtered_projects[@selected - 3]?
      end
      return unless target
      # Don't offer to delete a project another live instance is capturing into —
      # the green "● on" dot already flags it; deleting would silently orphan its
      # capture. (registry.delete also refuses, as a TOCTOU backstop below.)
      return if probe_running(target)[0]
      @confirm = ConfirmDialog.new("DELETE PROJECT",
        %(Delete "#{target.name}"?\nThis permanently removes all of its captured data.),
        confirm_label: "delete", cancel_label: "cancel", danger: true)
      @pending_delete = target
      @confirm_kind = :delete
      @mode = :confirm
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
      @confirm_kind = :delete
      @pending_delete = nil
      @pending_compact = nil
      @compact_project = nil
    end

    # --- space menu (project row actions) ------------------------------------

    private def selected_project : Project?
      return nil if @selected < 3
      filtered_projects[@selected - 3]?
    end

    private def open_space_menu : Nil
      return unless project = selected_project
      @space_project = project
      @space_selected = 0
      @mode = :space
    end

    private def close_space_menu : Nil
      @mode = :list
      @space_project = nil
      @space_selected = 0
    end

    private def activate_space_entry(entry : SpaceEntry) : Project | Symbol | Nil
      project = @space_project || selected_project
      close_space_menu
      return nil unless project
      case entry.action
      when :open
        project
      when :rename
        start_rename(project)
        nil
      when :compress
        start_compress(project)
        nil
      when :delete
        request_delete(project)
        nil
      end
    end

    private def start_rename(project : Project) : Nil
      @pending_rename = project
      @rename_name = project.name
      @preedit = ""
      @mode = :rename
    end

    private def commit_rename : Nil
      project = @pending_rename
      name = @rename_name.strip
      if project && !name.empty?
        begin
          renamed = @registry.rename(project, name)
          @projects = @registry.list
          invalidate_running_cache
          # Keep the cursor on the renamed project when it still matches the filter;
          # otherwise clamp so we don't land past the end of a shrunken list.
          if idx = filtered_projects.index { |p| p.dir == renamed.dir }
            @selected = idx + 3
          else
            @selected = @selected.clamp(0, {entry_count - 1, 0}.max)
          end
        rescue Gori::Error | IO::Error
          # invalid name or write failure — stay in rename so the user can fix it
          return
        end
      end
      cancel_rename
    end

    private def cancel_rename : Nil
      @mode = :list
      @pending_rename = nil
      @rename_name = ""
      @preedit = ""
    end

    # --- compress (space → Compress) -----------------------------------------

    # Open the compress-scope popup for `project`. Refuses one another live
    # instance is capturing into (VACUUM/deletes would race its writer — the green
    # "● on" dot already flags it), flashing why. Measures reclaimable sizes up
    # front so each option shows roughly what it would free.
    private def start_compress(project : Project) : Nil
      if probe_running(project)[0]
        set_flash(%(can't compress "#{project.name}" — it's open in another window), ok: false)
        return
      end
      # measure runs several full-table scans synchronously on this event loop; on a large
      # project that blocks repaint/input for a beat, so paint a busy card first (mirrors the
      # VACUUM path) instead of freezing on the stale frame.
      @mode = :measuring
      render
      stats = begin
        Store.measure(project.db_path)
      rescue Gori::Error | IO::Error | DB::Error | SQLite3::Exception
        @mode = :list
        set_flash(%(can't read "#{project.name}" to compress), ok: false)
        return
      end
      @compact_project = project
      @compact = CompactOverlay.new(project.name, stats)
      @mode = :compress
    end

    # Compress popup: ↑/↓ move, ‹/› cycle keep-flows, space toggle, ↵/space on the
    # Compress row opens the confirm (else toggles the focused row), esc dismiss.
    private def handle_compress(ev : Termisu::Event::Key) : Project | Symbol | Nil
      ov = @compact
      return nil unless ov
      key = ev.key
      @preedit = ""
      if key.escape? || ev.ctrl_c?
        close_compact
      elsif key.up?
        ov.move(-1)
      elsif key.down?
        ov.move(1)
      elsif key.left?
        ov.adjust(-1)
      elsif key.right?
        ov.adjust(1)
      elsif (key.enter? || key.space?) && !ev.ctrl? && !ev.alt?
        ov.on_run_row? ? request_compress(ov) : ov.toggle
      end
      nil
    end

    # Confirm before the destructive run (compaction can't be undone). Stashes the
    # plan, then reuses the shared danger ConfirmDialog (committed via @confirm_kind).
    private def request_compress(ov : CompactOverlay) : Nil
      return unless @compact_project
      plan = ov.plan
      est = ov.estimated_bytes
      detail = if plan.removes_data?
                 amount = est > 0 ? "~#{Fmt.size(est)} of data" : "the selected data"
                 "Remove #{amount} and reclaim disk?"
               else
                 "Reclaim free space (VACUUM only)?"
               end
      @pending_compact = plan
      @confirm = ConfirmDialog.new("COMPRESS PROJECT",
        %(#{detail}\nThis permanently drops the selected data.),
        confirm_label: "compress", cancel_label: "cancel", danger: true)
      @confirm_kind = :compress
      @compact = nil
      @mode = :confirm
    end

    # Run the compaction synchronously (the picker has no background jobs — mirrors
    # the synchronous delete). Paints a brief "Compressing …" frame first since a
    # VACUUM on a large db can block, then flashes the reclaimed size (or failure).
    private def commit_compress : Nil
      project = @compact_project
      plan = @pending_compact
      if project && plan
        @mode = :compressing
        render # paint the busy card before the blocking VACUUM
        begin
          if result = Store.compact(project.db_path, plan)
            if result.vacuumed
              reclaimed = result.reclaimed_bytes > 0 ? "  (−#{Fmt.size(result.reclaimed_bytes)})" : ""
              set_flash(%(compressed "#{project.name}"  #{Fmt.size(result.before_bytes)} → #{Fmt.size(result.after_bytes)}#{reclaimed}), ok: true)
            else
              # The strip committed but VACUUM failed (often low disk — it needs ~db-size
              # scratch). Data WAS removed; only the OS reclaim was skipped.
              set_flash(%(compressed "#{project.name}" — data removed, but disk not reclaimed (free up space and compress again)), ok: true)
            end
          else
            set_flash(%(can't compress "#{project.name}" — it's open in another window), ok: false)
          end
        rescue ex : Gori::Error | IO::Error | DB::Error | SQLite3::Exception
          set_flash("compress failed: #{ex.message}", ok: false)
        end
        @projects = @registry.list
        invalidate_running_cache
      end
      cancel_confirm # resets mode → :list and clears the confirm/compress state
    end

    private def close_compact : Nil
      @mode = :list
      @compact = nil
      @compact_project = nil
    end

    private def set_flash(msg : String, *, ok : Bool) : Nil
      @flash = msg
      @flash_ok = ok
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
      when :confirm      then handle_confirm_mouse(w, h, mx, my)
      when :settings     then handle_preferences_mouse(w, h, mx, my)
      when :theme        then handle_theme_mouse(w, h, mx, my)
      when :space        then handle_space_mouse(w, h, mx, my)
      when :compress     then handle_compress_mouse(w, h, mx, my)
      when :compressing  then nil # blocking VACUUM in progress — ignore clicks
      when :new, :rename then nil # text form — keyboard only (cursor placement is Phase 2)
      else                    handle_list_mouse(mx, my)
      end
    end

    # Click a compress-popup row to focus + toggle it (or open the confirm on the
    # Compress row); a click outside the card dismisses, like the other overlays.
    private def handle_compress_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Project | Symbol | Nil
      ov = @compact
      return nil if ov.nil?
      box = ov.overlay_box(Rect.new(0, 0, w, h))
      if box.nil? || !box.contains?(mx, my)
        close_compact
        return nil
      end
      if idx = ov.row_at(box, mx, my)
        ov.set_selected(idx)
        ov.on_run_row? ? request_compress(ov) : ov.toggle
      end
      nil
    end

    # List click: SELECT-FIRST — first click highlights the entry, a second click on
    # the already-selected entry activates it (same model as the History/Issues list).
    # The footer hint's buttons are checked first and fire on a SINGLE click: they're
    # commands, not a selection, so select-first would just make them feel broken.
    private def handle_list_mouse(mx : Int32, my : Int32) : Project | Symbol | Nil
      w, h = @backend.size
      if action = hint_action_at(mx, my, w, h)
        return run_hint_action(action)
      end
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
      when :settings                             then @preferences.wheel(delta)
      when :theme                                then (@theme_card.move_field(delta); preview_theme)
      when :space                                then @space_selected = (@space_selected + delta.sign).clamp(0, SPACE_ENTRIES.size - 1)
      when :compress                             then @compact.try(&.move(delta.sign))
      when :new, :confirm, :rename, :compressing then nil # nothing to scroll
      else                                            @selected = (@selected + delta).clamp(0, entry_count - 1)
      end
    end

    private def handle_confirm_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Nil
      dlg = @confirm
      return if dlg.nil?
      box = dlg.overlay_box(Rect.new(0, 0, w, h))
      return cancel_confirm unless box.contains?(mx, my) # click away → cancel
      case dlg.button_at(box, mx, my)
      when :confirm then commit_confirmed
      when :cancel  then cancel_confirm
      end
    end

    private def handle_preferences_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Nil
      # click outside the card → the view returns :close, which pops back to the list
      @mode = :list if @preferences.click(Rect.new(0, 0, w, h), mx, my).kind == :close
    end

    private def handle_theme_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Nil
      box = @theme_card.overlay_box(Rect.new(0, 0, w, h))
      if box.contains?(mx, my)
        if idx = @theme_card.field_at(box, mx, my)
          @theme_card.set_field(idx)
          preview_theme
        end
      else
        Theme.apply(@theme_restore) # click outside → cancel the preview, back to the modal
        @resized = true
        @mode = :settings
      end
    end

    private def handle_space_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Project | Symbol | Nil
      box = space_menu_box(w, h)
      return close_space_menu unless box.contains?(mx, my) # click away → dismiss
      if idx = space_row_at(box, mx, my)
        if idx == @space_selected
          return activate_space_entry(SPACE_ENTRIES[idx])
        else
          @space_selected = idx
        end
      end
      nil
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
    #      the gold, then locks to a solid block.
    #   2. Glint: a narrow bright band sweeps the same diagonal once — light
    #      catching the finished gold mark.
    #   3. The wordmark, then the tagline, fade in beneath it (see render_list).
    # Every timeline constant derives from BRAND_ART, so swapping the art re-times
    # the entrance. ART_ANIM_DONE is the frame at which everything has resolved —
    # the run loop freezes @art_frame there, and past it the same code paints the
    # identical static logo (band swept out, full gold, text at full strength).
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

    # --- starfield ------------------------------------------------------------
    # A sparse field of stars behind the picker — the space backdrop the gold
    # mark floats on. Whether a cell holds a star (and its glyph + twinkle
    # phase) is a pure hash of (x, y), so the field is stable across frames and
    # resizes with no stored state; everything drawn later (card, logo,
    # overlays) simply paints over it. Twinkle steps once per
    # 2^STAR_TWINKLE_SHIFT frames, so a star's cell changes colour well under
    # twice a second and the per-frame diff flush stays tiny.
    STAR_DENSITY       = 61_u32                               # ~1 star per this many cells (prime → no visible lattice)
    STAR_TWINKLE_SHIFT =      4                               # frames per twinkle step (2^4 ≈ 0.8 s at the 50 ms poll)
    STAR_LEVELS        = {0.18, 0.30, 0.42, 0.55, 0.42, 0.30} # blend ratios toward the star hue: dim → bright → dim
    STAR_FADE          =    8                                 # frames the field takes to fade in with the entrance
    STAR_GOLD_BOOST    = 0.15                                 # extra brightness for the rare gold ✦ so it reads as a glint

    # Deterministic per-cell mix deciding star existence, glyph, and phase.
    # Wrapping ops only — must be pure and total for any cell at any size.
    private def star_hash(x : Int32, y : Int32) : UInt32
      h = (x.to_u32! &* 0x9E3779B1_u32) ^ (y.to_u32! &* 0x85EBCA77_u32)
      h ^= h >> 15
      h &*= 0xC2B2AE3D_u32
      h ^ (h >> 13)
    end

    # Paint the starfield across the whole canvas (right after the bg fill,
    # before any content). Mostly muted '·' dots; ~1 in 8 is a gold '✦' echoing
    # the mark. Colours blend toward Theme.bg so the field stays subtle on
    # every palette, light themes included. The fade-in rides the entrance
    # clock, so the sky appears just before the logo materialises.
    private def draw_starfield(screen : Screen, w : Int32, h : Int32) : Nil
      intro = (@art_frame / STAR_FADE.to_f).clamp(0.0, 1.0)
      return if intro <= 0
      step = @star_frame.to_u32! >> STAR_TWINKLE_SHIFT
      y = 0
      while y < h
        x = 0
        while x < w
          hash = star_hash(x, y)
          if hash % STAR_DENSITY == 0
            phase = ((step &+ (hash >> 5)) % STAR_LEVELS.size.to_u32).to_i
            gold = ((hash >> 8) & 7_u32) == 0
            t = STAR_LEVELS[phase]
            t += STAR_GOLD_BOOST if gold
            hue = gold ? Theme.focus_gold : Theme.muted
            screen.cell(x, y, gold ? '✦' : '·', Theme.blend(hue, Theme.bg, {t * intro, 1.0}.min), Theme.bg)
          end
          x += 1
        end
        y += 1
      end
    end

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)
      draw_starfield(screen, w, h)
      cw = {w - 4, MENU_WIDTH}.min
      cx = {(w - cw) // 2, 0}.max
      case @mode
      when :new
        render_new(screen, cx, cw, w, h)
      when :rename
        render_rename(screen, cx, cw, w, h)
      else
        render_list(screen, cx, cw, w, h)
        @confirm.try(&.render(screen, Rect.new(0, 0, w, h))) if @mode == :confirm
        @preferences.render(screen, Rect.new(0, 0, w, h)) if @mode == :settings
        @theme_card.render(screen, Rect.new(0, 0, w, h)) if @mode == :theme
        render_space_menu(screen, w, h) if @mode == :space
        @compact.try(&.render(screen, Rect.new(0, 0, w, h))) if @mode == :compress
        render_compressing(screen, w, h) if @mode == :compressing || @mode == :measuring
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
      # cells, especially for the centered layout); a cheap diff otherwise. The
      # backend forwards only the cells that changed this frame.
      @backend.flush(sync: @resized)
      @resized = false
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
      # The logo stack (art + wordmark + tagline) draws straight on the starred
      # canvas — no lifted panel band, and no band re-fill, which would punch a
      # starless hole across the backdrop render already painted.
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

      # Row above the hint (h-3): a transient compaction result when present, else
      # the once-per-release "update available" notice. The compaction flash is a
      # direct response to a keypress, so it takes the row; the notice returns when
      # the flash clears on the next keystroke.
      if flash = @flash
        centered(screen, h - 3, flash, @flash_ok ? Theme.green : Theme.red, w)
      elsif notice = @update_notice
        centered(screen, h - 3, notice, Theme.yellow, w)
        # Mark this release "read" only once it has actually reached the screen, so a
        # fetch that lands as the user opens a project doesn't burn the one showing.
        unless @notice_persisted
          @notice_persisted = true
          Settings.update_notified_version = @update_notice_version
          Settings.save
        end
      end

      if tokens = list_hint_tokens
        render_hint(screen, tokens, h - 2, w)
      else
        hint = case
               when @mode == :compress
                 "↑/↓ select   ‹/› keep   space toggle   ↵ compress   esc close"
               when @mode == :compressing
                 "compressing …"
               else # :space
                 "↑/↓ select   ↵ run   o open   r rename   c compress   d delete   esc close"
               end
        centered(screen, h - 2, hint, Theme.muted, w)
      end
    end

    # Gap between footer-hint tokens — the same three cells the flat hint string used, so
    # tokenizing the row for click support left it pixel-identical to before.
    HINT_GAP = 3

    # The footer hint for the project LIST, split into tokens so the pressable ones can be
    # tinted and hit-tested. nil in the modal modes (:compress/:compressing/:space), which
    # keep the old flat string — their hints describe keys inside an overlay that already
    # owns the mouse, so there's nothing here to press.
    private def list_hint_tokens : Array(HintToken)?
      return nil unless @mode == :list
      tokens = [
        HintToken.new("↑/↓ select"),
        HintToken.new("↵ open", :open),
      ]
      # A project row is selected → `space` opens its action menu; on the New/Temp/Search
      # rows that chord does something else entirely, so the token (and its button) is
      # offered only where it applies, exactly as the flat hint used to switch.
      tokens << HintToken.new("space actions", :space) if @selected >= 3
      tokens << HintToken.new("type to search")
      if @selected < 3
        tokens << HintToken.new("ctrl-n new", :new)
        tokens << HintToken.new("ctrl-t temp", :temp)
      end
      tokens << HintToken.new("ctrl-d delete", :delete)
      tokens << HintToken.new("ctrl-, settings", :settings)
      tokens << HintToken.new("ctrl-c quit", :quit)
      tokens
    end

    # The tokens' cell rects, centered on row `y`. THE single geometry source — `render_hint`
    # draws from it and `hint_action_at` hit-tests against it, so the cells a token occupies
    # and the cells that respond to a click are the same cells by construction.
    private def hint_rects(tokens : Array(HintToken), y : Int32, w : Int32) : Array(Rect)
      total = tokens.sum { |t| Screen.display_width(t.label) } + HINT_GAP * {tokens.size - 1, 0}.max
      x = {(w - total) // 2, 0}.max
      tokens.map do |t|
        tw = Screen.display_width(t.label)
        rect = Rect.new(x, y, tw, 1)
        x += tw + HINT_GAP
        rect
      end
    end

    private def render_hint(screen : Screen, tokens : Array(HintToken), y : Int32, w : Int32) : Nil
      rects = hint_rects(tokens, y, w)
      tokens.each_with_index do |token, i|
        rect = rects[i]
        break if rect.x >= w
        screen.text(rect.x, y, token.label, Theme.muted, Theme.bg, width: {w - rect.x, 1}.max)
      end
    end

    # The action under a footer click, or nil (not the hint row / an inert token / a mode
    # whose hint isn't tokenized).
    private def hint_action_at(mx : Int32, my : Int32, w : Int32, h : Int32) : Symbol?
      return nil unless my == h - 2
      return nil unless tokens = list_hint_tokens
      rects = hint_rects(tokens, h - 2, w)
      tokens.each_with_index do |token, i|
        action = token.action
        return action if action && rects[i].contains?(mx, my)
      end
      nil
    end

    # Run a footer button. Each arm mirrors its chord in `handle_list_key` exactly — notably
    # `:new`, which (like ctrl-n) direct-creates when the search box already holds a name
    # rather than opening the form with it retyped.
    private def run_hint_action(action : Symbol) : Project | Symbol | Nil
      case action
      # `return`, not a bare call: `activate`'s Project IS how the picker says "open
      # this" (see `run`). Without it the footer button did nothing, and on the Temp row
      # it silently created a project directory on disk and abandoned it, once per click.
      when :open  then return activate
      when :space then open_space_menu
      when :temp  then return open_temp
      when :quit  then return :quit
      when :new
        name = @query.strip
        return safe_create(name) unless name.empty?
        start_new
      when :delete then request_delete
      when :settings
        @preferences.open_default
        @mode = :settings
      end
      nil
    end

    # Bottom-right space menu over the project list — open / rename / delete.
    # Mirrors the in-session SpaceMenu chrome (card + mnemonic + ▎ selection).
    private def space_menu_box(w : Int32, h : Int32) : Rect
      label_w = SPACE_ENTRIES.max_of(&.label.size)
      mw = {label_w + 6, 16}.max # border + ▎ + key + gap + label + border
      mh = SPACE_ENTRIES.size + 2
      x = {w - mw - 2, 0}.max
      y = {h - mh - 3, 1}.max # above the hint row
      Rect.new(x, y, mw, mh)
    end

    private def space_row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      i = my - (box.y + 1)
      return nil if i < 0 || i >= SPACE_ENTRIES.size
      return nil if mx <= box.x || mx >= box.right - 1
      i
    end

    private def render_space_menu(screen : Screen, w : Int32, h : Int32) : Nil
      box = space_menu_box(w, h)
      Frame.card(screen, box, "SPACE", border: Theme.border_focus)
      SPACE_ENTRIES.each_with_index do |entry, i|
        ry = box.y + 1 + i
        active = i == @space_selected
        bg = active ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(box.x + 1, ry, box.w - 2, 1), bg)
        screen.cell(box.x + 1, ry, active ? '▎' : ' ', Theme.accent, bg)
        screen.text(box.x + 2, ry, entry.key.to_s, Theme.accent, bg, Attribute::Bold)
        screen.text(box.x + 4, ry, entry.label, active ? Theme.text_bright : Theme.text, bg,
          width: {box.w - 5, 0}.max)
      end
    end

    # A small centered busy card painted while a synchronous blocking step runs (the picker
    # has no background jobs / spinner), so the freeze reads as work — the measure scan on a
    # multi-GB project, then the VACUUM.
    private def render_compressing(screen : Screen, w : Int32, h : Int32) : Nil
      msg = @mode == :measuring ? " Measuring … " : " Compressing … "
      bw = {msg.size + 4, 22}.max
      bh = 3
      box = Rect.new({(w - bw) // 2, 0}.max, {(h - bh) // 2, 0}.max, bw, bh)
      Frame.card(screen, box, border: Theme.border_focus)
      screen.text(box.x + (box.w - msg.size) // 2, box.y + 1, msg, Theme.text_bright, Theme.panel, Attribute::Bold)
    end

    private def render_rename(screen : Screen, cx : Int32, cw : Int32, w : Int32, h : Int32) : Nil
      top = {(h - 4) // 2, 1}.max
      Chrome.render_wordmark(screen, 0, top, center_w: w, bg: Theme.bg)
      proj = @pending_rename
      subtitle = proj ? %(rename "#{proj.name}") : "rename project"
      centered(screen, top + 2, subtitle, Theme.muted, w)
      iy = top + 3
      screen.fill(Rect.new(cx, iy, cw, 1), Theme.panel)
      prefix = "name › "
      screen.text(cx + 2, iy, prefix, Theme.text_bright, Theme.panel)
      nbase = cx + 2 + Screen.display_width(prefix)
      nwidth = {cw - Screen.display_width(prefix) - 2, 1}.max
      screen.input_line(nbase, iy, @rename_name, @rename_name.size, @preedit, Theme.text_bright, Theme.panel, width: nwidth)
      centered(screen, h - 2, "↵ save   esc cancel", Theme.muted, w)
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
    # up to the gold before locking solid; the glint band then sweeps the same
    # diagonal once. Past ART_ANIM_DONE every cell is solid gold, so the same
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
    # ░▒▓ ramping from a dim gold up toward full strength, then a solid block.
    private def art_cell(prog : Int32) : {Char, Color}
      return {'█', Theme.focus_gold} if prog > ART_SHADES.size
      t = 0.35 + 0.65 * prog / (ART_SHADES.size + 1)
      {ART_SHADES[prog - 1], Theme.blend(Theme.focus_gold, Theme.bg, t)}
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
          fg: Theme.blend(Theme.focus_gold, Theme.bg, t))
      end
      if (t = fade_t(TAGLINE_START)) > 0
        centered(screen, top + 1, TAGLINE, Theme.blend(Theme.muted, Theme.bg, t), w)
      end
    end

    # The glint: a GLINT_BAND-wide highlight band sweeping down the diagonal after
    # the reveal — the bright accent catching the gilded mark at its leading edge,
    # trailing back off to the base gold (`fg`). A no-op before the sweep starts and
    # after the band has left the art, so the frozen frame is pure gold.
    private def glint_tint(d : Int32, frame : Int32, fg : Color) : Color
      return fg if frame <= REVEAL_DONE
      dist = (frame - REVEAL_DONE) * GLINT_SPEED - d
      return fg if dist < 0 || dist >= GLINT_BAND
      Theme.blend(Theme.accent, fg, 1.0 - dist / GLINT_BAND.to_f)
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
