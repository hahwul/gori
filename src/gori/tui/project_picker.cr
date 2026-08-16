require "termisu"
require "../capture_lock"
require "../open_lock"
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
require "./project_marks"
require "./notifications"
require "./companion"
require "./settings_view"
require "./preferences_view"
require "./compact_overlay"
require "./viewport"

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
  #
  # The list also MARKS (ProjectMarks): Tab / ⇧Tab flip a project's mark and step, ⇧↑/⇧↓
  # extend a range, ctrl-a marks the whole filter, esc clears. The space menu's Delete then
  # acts on the marks if any are set, else the cursor row — the one target rule History and
  # the Issues list use. The chords deviate from the app-wide `t` / ⇧T ON PURPOSE and cannot
  # be "fixed" back: on this screen every printable key types into the search box (see
  # handle_list), so `t` would filter rather than mark. Tab is fzf's toggle in exactly this
  # shape of list, and ctrl-a is the same select-all everything else spells ⇧T.
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

    # The menu while marks are set. Delete is the batch verb and says so; the other three
    # are named SINGLE-target explicitly, the way the Runner tags its HISTORY_CURSOR_ONLY
    # verbs, so a menu opened over 3 marks can't read as an offer to do all three:
    #   • Open returns ONE project (that is the picker's whole return value).
    #   • Rename edits one display name.
    #   • Compress measures and VACUUMs synchronously on this event loop, with a per-project
    #     byte estimate in its popup — N of those is N multi-second freezes and an estimate
    #     that would be a fiction for every individual project.
    # Clear marks mirrors the in-app `*.mark-clear` entry, mnemonic and all.
    #
    # Class-level and pure so the labels a destructive menu shows can be pinned in a spec:
    # the picker holds a live Termisu and cannot be built in one.
    def self.space_entries(marked : Int32) : Array(SpaceEntry)
      return SPACE_ENTRIES if marked <= 0
      [
        SpaceEntry.new('o', "Open (cursor)", :open),
        SpaceEntry.new('r', "Rename (cursor)", :rename),
        SpaceEntry.new('c', "Compress (cursor)", :compress),
        SpaceEntry.new('d', "Delete #{plural_projects(marked)}", :delete),
        SpaceEntry.new('n', "Clear marks", :mark_clear),
      ]
    end

    def self.plural_projects(n : Int32) : String
      "#{n} project#{n == 1 ? "" : "s"}"
    end

    # The mark count appended to the list divider, or "" with nothing marked (so an unmarked
    # picker's divider stays byte-identical to what it always drew).
    def self.mark_chip(marked : Int32, hidden : Int32) : String
      return "" if marked <= 0
      hidden > 0 ? " · #{marked} marked (#{hidden} hidden)" : " · #{marked} marked"
    end

    # `notice` is why the caller is showing the picker rather than a project — a session
    # that failed to open (a bad `--db`, an unreadable store). It rides the same h-3 row as
    # the update notice but in red, because without it a failed open is indistinguishable
    # from an empty gori: the operator lands on "no projects yet" and concludes their
    # capture is gone. See App#open_and_run.
    def initialize(@term : Termisu, @registry : ProjectRegistry, notice : String? = nil)
      @open_error = notice
      # Held as the base Backend: TermisuBackend is generic over the terminal type.
      @backend = TermisuBackend.new(@term).as(Backend)
      @projects = @registry.list
      @query = "" # current search filter; only editable when Search row selected
      @selected = 0
      @results_scroll = 0
      @mode = :list # :list | :new | :confirm | :space | :rename | :settings | :theme | :compress | + BUSY_LABELS
      @name = ""
      @desc = ""
      @new_field = :name # :name | :desc (only in :new mode)
      @resized = false   # set on a Resize event → next frame full-repaints
      @preedit = ""      # live IME composing text for the active field (search/name/desc)
      # Delete confirmation (project deletion is irreversible — wipes its dir).
      @confirm = nil.as(ConfirmDialog?)
      # The projects a confirmed delete will wipe — a LIST because the space menu's Delete
      # acts on the mark set (see target_projects). Captured when the confirm opens, so a
      # cursor move or a peer's write between the question and the answer can't retarget it.
      @pending_deletes = [] of Project
      # Multi-select over the project rows; every batch verb reads it through target_projects.
      @marks = ProjectMarks.new
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
      # Miss Ring (settings:companion), same widget the session runs — off by default, and the
      # same zero-cost no-op while off. She has no notification ring to watch here (the
      # picker exists before any project), so the one thing she has to say beyond her
      # hello is handed to her directly — see announce_update / Companion#say.
      @companion = Companion.new(Notifications.new)
      @companion_started_at = nil.as(Time::Instant?) # when she first ticked — the hello's t0
      @update_line = nil.as(String?)                 # her form of the update notice, until she says it
      @update_spoken = false                         # she has said it → her line counts as the notice's paint
    end

    # Once-a-day cache window: skip the network probe when the last successful check
    # is this recent (still surfaces a not-yet-notified update from the cached value).
    UPDATE_CHECK_TTL = 24 * 60 * 60

    def run : Project?
      start_update_check
      loop do
        reconcile_update_check
        tick_companion
        render
        # Drive the entrance animation off the idle poll cadence (~50 ms/frame):
        # the loop re-renders whenever poll_event times out, so bumping the clock
        # here plays the reveal once, then freezes at ART_ANIM_DONE (static after).
        @art_frame += 1 if @art_frame < ART_ANIM_DONE
        @star_frame &+= 1
        # Own event loop, so the Runner's ⌥-alias fold doesn't reach it — apply it here too
        # or ⌥N (new project) / ⌥, (preferences) would be dead on this screen.
        case ev = Keybind.dealias_event(@term.poll_event(50))
        when Termisu::Event::Resize
          # termisu already resized its buffer to these dims; re-fit the backend grids in
          # lockstep off the same event dims, and force a full repaint next frame.
          @backend.resize(ev.width, ev.height)
          @resized = true
        when Termisu::Event::Key
          @companion.wake_on_input # any key re-arms Miss Ring's idle clock (self-gated while off)
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
          @companion.wake_on_input
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
        announce_update(nv)
      end
    end

    # Hand the update to Miss Ring, to be said a beat after her hello (see #speak_update).
    # Deliberately NOT merged into the hello itself: a greeting that opens with a version
    # bump is a banner wearing a face, whereas hello-then-news is her telling you
    # something, which is the whole point of routing it through her.
    #
    # @update_notice stays set either way. She is off by default and needs room the card
    # doesn't always leave (see #companion_rect), so the row is still the notice's home — she
    # takes the row while she is talking and hands it back when she stops.
    private def announce_update(version : String) : Nil
      return unless Settings.companion? && Settings.companion_notices?
      @update_line = "heads up: v#{version} is out · run: gori update"
    end

    # --- Miss Ring -----------------------------------------------------------

    # Beat between her hello and the update line. Long enough that "hi!" reads as a
    # greeting rather than as a header on the notice, short enough to land while the
    # operator is still on this screen (her hello holds for Companion::GREET_TTL = 8s).
    UPDATE_SPEAK_AFTER = 3.seconds

    # Held back until the entrance animation has resolved, so the hero lands first and she
    # walks on afterwards rather than popping in mid-reveal. @art_frame advances on every
    # frame whether or not the art is shown, so short terminals get the same beat.
    #
    # No dirty-tracking around the tick (unlike the Runner's): this loop already repaints
    # every poll, so her `changed` verdict has nothing here to gate.
    private def tick_companion : Nil
      return if @art_frame < ART_ANIM_DONE
      now = Time.instant
      @companion_started_at ||= now
      @companion.tick(now)
      speak_update(now)
    end

    private def speak_update(now : Time::Instant) : Nil
      return unless line = @update_line
      return unless started = @companion_started_at
      return if now - started < UPDATE_SPEAK_AFTER
      @update_line = nil
      @update_spoken = true
      @companion.say(line, now, :warn)
    end

    # Where Miss Ring stands, or nil when she has no room. Her stage is the canvas down to
    # the row above the notice row, which puts her plate on h-6..h-4 — clear of both footer
    # rows, with her bubble on the three rows above that.
    #
    # THE SPRITE is dropped OUTRIGHT rather than moved when that lands her on the picker
    # card: she paints last, and a mascot parked on the project list for the whole session
    # is a rendering bug rather than a mascot. With the 50-column card centred that needs
    # roughly 75 columns — under it she simply doesn't appear, the same bargain
    # `art_shown?` makes for the brand block.
    #
    # THE BUBBLE is held to no such rule, and floats over the card when what she is saying
    # is wider than the margin she stands in. That is the same trade `placement: body`
    # makes in the session, where she speaks over the tab body: a bubble is a few seconds
    # of her talking, it carries its own border rather than eating the card's, and a bubble
    # narrowed to a 20-column margin would truncate every line she has to say — which is
    # the one thing a speech bubble may not do.
    private def companion_rect(w : Int32, h : Int32) : Rect?
      return nil unless Settings.companion?
      ProjectPicker.companion_place(w, h)
    end

    # The placement rule itself, free of Settings and of any picker instance so a spec can
    # sweep it over terminal sizes — the one thing about her here that geometry can get
    # wrong. `companion_stage` is the rect Companion.place measures from; the caller hands the SAME
    # rect to Companion.draw, so what is tested is what is painted.
    def self.companion_stage(w : Int32, h : Int32) : Rect
      Rect.new(0, 0, w, h - 1)
    end

    def self.companion_place(w : Int32, h : Int32) : Rect?
      return nil unless rect = Companion.place(companion_stage(w, h))
      box, _ = card_metrics(w, h)
      # rect.x - 1: Companion.draw claims a column of plate either side of the sprite.
      return nil if rect.x - 1 < box.right && rect.y < box.bottom
      rect
    end

    # Whether she is mid-sentence. Not the text — nothing here paints her line, she says it
    # in her own bubble — only whether the notice row must stand down while she does.
    private def companion_speaking? : Bool
      !@companion.frame.try(&.bubble).nil?
    end

    # --- input ---------------------------------------------------------------

    private def entry_count : Int32
      entry_count_for(filtered_projects) # New, Temp, Search, then (filtered) projects
    end

    # `entry_count` off a list already in hand. `filtered_projects` re-runs the whole fuzzy
    # scoring on every call, so the mark gestures — which need both the list and its bound —
    # would otherwise score the registry twice per keystroke.
    private def entry_count_for(fp : Array(Project)) : Int32
      3 + fp.size
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

    private def handle_list(ev : Termisu::Event::Key) : Project | Symbol?
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
        ev.shift? ? mark_extend(-1) : move_selection(-1)
      elsif key.down?
        ev.shift? ? mark_extend(1) : move_selection(1)
      elsif (key.tab? || key.back_tab?) && !ev.ctrl? && !ev.alt?
        # BEFORE the printable arm below: Tab reaches it as '\t' (Event::Key#char falls back
        # to key.to_char), which would type a tab into the search query instead of marking.
        # Modifier-guarded like every other arm here: ^I is byte-identical to Tab (0x09, so
        # termisu hands back Key::Tab), and ^I is not a request to mark anything.
        mark_toggle(key.tab? ? 1 : -1)
      elsif key.enter?
        return activate
      elsif key.space? && !ev.ctrl? && !ev.alt?
        if space_opens_menu?
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
        # Marks first — esc is the reflex for dropping a selection everywhere else in gori,
        # and a set that outlived the esc meant to clear it would go on aiming the next
        # delete. Only then does esc mean "clear the query", and only then "quit".
        if !@marks.empty?
          @marks.clear
        elsif @query.empty?
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
      elsif ev.ctrl? && key.lower_a?
        mark_all
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
    private def handle_preferences(ev : Termisu::Event::Key) : Project | Symbol?
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
        if Settings.mouse
          @term.enable_mouse
          MouseDrag.enable # mode 1002 rides the same toggle — see MouseDrag
        else
          MouseDrag.disable
          @term.disable_mouse
        end
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
    private def handle_theme(ev : Termisu::Event::Key) : Project | Symbol?
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
    #
    # This is the picker's OWN key ladder — it drives ConfirmDialog as a plain state object
    # and never reaches `ConfirmDialog#handle_key`, so the answer rule comes from the shared
    # `ConfirmDialog.affirmative?` rather than being spelled out a second time here. It has to
    # be shared: the two ladders drifted once already, and the arm that missed the ctrl/alt
    # guard was this one — where "yes" means `rm_rf` on the project directory or a VACUUM,
    # neither of which can be taken back.
    private def handle_confirm(ev : Termisu::Event::Key) : Project | Symbol?
      @preedit = ""
      dlg = @confirm
      key = ev.key
      case
      when key.escape?, key.n?, ev.ctrl_c?                then cancel_confirm
      when ConfirmDialog.affirmative?(ev)                 then commit_confirmed
      when key.left?, key.right?, key.tab?, key.back_tab? then dlg.try(&.move)
      when key.enter?
        dlg.try(&.confirm_selected?) ? commit_confirmed : cancel_confirm
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
    private def handle_space(ev : Termisu::Event::Key) : Project | Symbol?
      key = ev.key
      entries = space_entries
      @preedit = ""
      if key.escape? || ev.ctrl_c?
        close_space_menu
      elsif key.up?
        @space_selected = (@space_selected - 1).clamp(0, entries.size - 1)
      elsif key.down?
        @space_selected = (@space_selected + 1).clamp(0, entries.size - 1)
      elsif key.enter?
        return activate_space_entry(entries[@space_selected])
      elsif (c = ev.char || key.to_char) && !ev.ctrl? && !ev.alt?
        if entry = entries.find { |e| e.key == c.downcase }
          return activate_space_entry(entry)
        end
      end
      nil
    end

    # Rename prompt: type a new display name, ↵ commit, esc cancel.
    private def handle_rename(ev : Termisu::Event::Key) : Project | Symbol?
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
        if filtered_projects.present?
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

    # Open the delete-confirmation modal for the target set — the marks if any are set, else
    # the cursor project (project deletion wipes the directory, so it's always confirmed).
    # The ONE entry point: ctrl-d, the footer button and the space menu all land here, so
    # there is no path on which "delete" means something other than target_projects.
    private def request_delete : Nil
      targets = target_projects
      return if targets.empty?
      # Split off what can't be deleted BEFORE asking, so the dialog only ever offers a
      # delete that can actually happen. Two ways to be in use: another live instance
      # capturing into it, and a peer (an MCP server takes no capture lock) merely holding
      # the database open. `registry.delete` refuses both as the TOCTOU backstop.
      blocked = [] of Project
      deletable = targets.reject do |p|
        in_use = probe_running(p)[0] || OpenLock.in_use?(p.db_path)
        blocked << p if in_use
        in_use
      end
      if deletable.empty?
        # Said out loud even for the capture-lock case the green "● on" dot already flags:
        # a ctrl-d that does nothing at all reads as delete being broken rather than refused
        # — the same reasoning the post-confirm refusal below is written for.
        set_flash(ProjectPicker.delete_blocked_flash(blocked.map(&.name)), ok: false)
        return
      end
      # Hoisted: `filtered_projects` re-runs the fuzzy scoring on every call.
      shown = filtered_projects.map(&.dir).to_set
      hidden = deletable.count { |p| !shown.includes?(p.dir) }
      dialog = ConfirmDialog.new(deletable.size == 1 ? "DELETE PROJECT" : "DELETE PROJECTS",
        ProjectPicker.delete_confirm_body(deletable.map(&.name), hidden, blocked.size),
        confirm_label: "delete", cancel_label: "cancel", danger: true)
      # ConfirmDialog DECLINES to draw on a terminal too small for its card (render and
      # overlay_box share the guard, the latter answering with a 0×0 rect). Its mouse path
      # already takes that as "not showing"; the key path never did, so on a short window
      # ctrl-d used to arm an invisible dialog that `y` then committed — an unattended,
      # unreadable rm_rf. Refuse to arm it at all instead: a delete you cannot read is a
      # delete you cannot have confirmed.
      w, h = @backend.size
      if dialog.overlay_box(Rect.new(0, 0, w, h)).w == 0
        set_flash("window too small to confirm a delete — make it taller", ok: false)
        return
      end
      @confirm = dialog
      @pending_deletes = deletable
      @confirm_kind = :delete
      @mode = :confirm
    end

    # How many projects the confirm names outright before falling back to the count.
    NAMED_DELETE_MAX = 3

    # …and how wide those names may run. ConfirmDialog caps its card at 60 columns and draws
    # each line with `width: box.w - 6`, so anything past this is ELLIPSIZED — which on this
    # dialog means the operator confirms an irreversible wipe having read `Delete "acme-01",
    # "acme-02", "acme-…`, with a project name and the question mark cut off. A count is a
    # worse sentence than three names but an honest one, so the width decides, not the count
    # alone. (Kept in step with ConfirmDialog#overlay_box / #render by the spec below.)
    NAMED_DELETE_WIDTH = 54

    # The last sentence read before N project directories are wiped, so it has to name the
    # whole set — including the marks the current filter is hiding, which is the one thing
    # the list itself cannot show.
    # Pure + class-level so a spec can pin it without a Termisu.
    def self.delete_confirm_body(names : Array(String), hidden : Int32, blocked : Int32) : String
      one = names.size == 1
      head = "Delete #{plural_projects(names.size)}?"
      if names.size <= NAMED_DELETE_MAX
        named = %(Delete #{names.map { |n| %("#{n}") }.join(", ")}?)
        # A single project is named whatever it costs: "Delete 1 project?" names nothing at
        # all, and ConfirmDialog ellipsizes a long name the same way the list row does.
        head = named if one || Screen.display_width(named) <= NAMED_DELETE_WIDTH
      end
      String.build do |io|
        io << head
        io << '\n' << "This permanently removes all of " << (one ? "its" : "their") << " captured data."
        if hidden > 0
          io << '\n'
          # "them" needs a plural to refer to; with one target the sentence is about it.
          one ? (io << "It is hidden by the current search.") : (io << hidden << " of them " << (hidden == 1 ? "is" : "are") << " hidden by the current search.")
        end
        io << '\n' << blocked << " more " << (blocked == 1 ? "is" : "are") << " in use and will be kept." if blocked > 0
      end
    end

    # Why a delete never got as far as the confirm: every target is in use.
    def self.delete_blocked_flash(names : Array(String)) : String
      return "nothing to delete" if names.empty?
      return %(can't delete "#{names.first}" — it's open in another gori instance) if names.size == 1
      "can't delete #{plural_projects(names.size)} — they're open in another gori instance"
    end

    private def commit_delete : Nil
      targets = @pending_deletes
      unless targets.empty?
        deleted = [] of String # dirs — only these are unmarked (a refusal stays marked to retry)
        refused = [] of String
        first_error = nil.as(String?)
        # N synchronous rm_rf calls, each potentially over a multi-GB project directory, on
        # the same event loop that draws. Paint the busy card first for the same reason the
        # compress path does (see commit_compress) — otherwise the picker freezes on the
        # stale confirm frame and reads as hung rather than as working.
        @mode = :deleting
        render
        targets.each do |project|
          @registry.delete(project) # refuses if it went live since request_delete
          deleted << project.dir
        rescue ex : Gori::Error
          # Became live (capturing, or opened by a peer) between the confirm and here. The
          # message names WHICH, and it has to reach the screen: swallowed, the dialog just
          # closed with the project still listed and nothing said, so the operator saw delete
          # as broken rather than as refused.
          refused << project.name
          first_error ||= ex.message
        rescue ex : IO::Error
          # rm_rf hit a real filesystem failure (permission, locked file) — keep the TUI
          # alive; the directory may be partially removed, so the reload below re-reads it.
          # Its message is captured too: reported as the generic refusal it is NOT, this
          # reads as "close the other gori" and sends the operator after an instance that
          # was never there.
          refused << project.name
          first_error ||= %(can't delete "#{project.name}" — #{ex.message})
        end
        @marks.unmark(deleted)
        reload_projects
        @selected = 2 unless deleted.empty?
        if msg = ProjectPicker.delete_result_flash(deleted.size, refused, first_error)
          set_flash(msg, ok: refused.empty?)
        end
      end
      cancel_confirm
    end

    # What a committed delete says afterwards. A clean single delete stays silent (the row
    # is gone from the list — that IS the report, and the notice row belongs to the open
    # error); anything partial or refused has to say so.
    def self.delete_result_flash(deleted : Int32, refused : Array(String), first_error : String?) : String?
      return nil if refused.empty? && deleted <= 1
      if refused.empty?
        return "deleted #{plural_projects(deleted)}"
      end
      if deleted == 0 && refused.size == 1
        return first_error || %(can't delete "#{refused.first}")
      end
      # No cause named on the batch line: the refusals can be a mix of in-use and filesystem
      # failures, and one sentence cannot claim both. The single-target line above says which,
      # because there it can (it carries the raising error's own message).
      kept = refused.size == 1 ? %("#{refused.first}") : refused.size.to_s
      deleted == 0 ? "deleted nothing — kept #{kept}" : "deleted #{plural_projects(deleted)} — kept #{kept}"
    end

    private def cancel_confirm : Nil
      @mode = :list
      @confirm = nil
      @confirm_kind = :delete
      @pending_deletes = [] of Project
      @pending_compact = nil
      @compact_project = nil
    end

    # --- marks (multi-select) -------------------------------------------------

    # A plain arrow ends a ⇧arrow range gesture and hands its marks back, the way a GUI list
    # collapses its highlight when you let go of ⇧. Nothing is said about it: the picker's
    # one message row belongs to the open error (the only trace that a project failed to
    # open) and to the compaction flash, and the divider chip already carries a live count.
    private def move_selection(delta : Int32) : Nil
      @marks.end_gesture
      @selected = (@selected + delta).clamp(0, entry_count - 1)
    end

    # Tab / ⇧Tab — flip the cursor project's mark, then step, so a run of Tab marks
    # consecutive rows. From an action row it acts on the TOP VISIBLE match instead of doing
    # nothing: "type a filter, Tab Tab Tab" is the gesture this list is shaped for, and
    # after a keystroke of typing the cursor is parked on the Search row by definition.
    #
    # @results_scroll, not 0: it is the top drawn row by construction (see render_list), so
    # the mark lands on the row the operator is looking at. The two agree today — a render
    # runs between every keystroke, and `ensure_results_visible` zeroes the scroll while the
    # cursor sits on an action row — but that is an ordering argument, not an invariant this
    # method establishes, and it is one refactor away from marking an off-screen project.
    private def mark_toggle(step : Int32) : Nil
      fp = filtered_projects
      return if fp.empty?
      idx = @selected < 3 ? @results_scroll : @selected - 3
      return unless proj = fp[idx]?
      @marks.toggle(proj.dir)
      @selected = (idx + step + 3).clamp(3, entry_count_for(fp) - 1)
    end

    # ⇧↑/⇧↓ — extend a contiguous range from the anchor. Until the cursor is on a project
    # row there is nothing to anchor on, so it just moves, exactly like the plain arrow.
    private def mark_extend(delta : Int32) : Nil
      fp = filtered_projects
      if @selected < 3 || fp.empty?
        @selected = (@selected + delta).clamp(0, entry_count_for(fp) - 1)
        return
      end
      @selected = @marks.extend(fp.map(&.dir), @selected - 3, delta) + 3
    end

    # ctrl-a — mark everything the current filter shows (the list's ⇧T, respelled: see the
    # class comment for why the app-wide letter chords can't reach this screen).
    private def mark_all : Nil
      fp = filtered_projects
      return if fp.empty?
      @marks.mark_all(fp.map(&.dir), selected_project.try(&.dir))
    end

    # The set every batch verb acts on: the marks if any are set, else the cursor row. One
    # rule, so no verb here needs a notion of "batch mode" — the same shape as
    # HistoryView#target_ids. Marks outlive the fuzzy filter, so this deliberately reaches
    # projects the list is not currently showing; what that means for a delete is spelled
    # out in the confirm (see delete_confirm_body).
    private def target_projects : Array(Project)
      return [selected_project].compact if @marks.empty?
      by_dir = @projects.to_h { |p| {p.dir, p} }
      @marks.ordered(filtered_projects.map(&.dir)).compact_map { |dir| by_dir[dir]? }
    end

    # Re-read the registry after a mutation, dropping marks whose project is gone with it.
    private def reload_projects : Nil
      @projects = @registry.list
      @marks.retain(@projects.map(&.dir))
      invalidate_running_cache
    end

    # --- space menu (project row actions) ------------------------------------

    private def selected_project : Project?
      return nil if @selected < 3
      filtered_projects[@selected - 3]?
    end

    private def space_entries : Array(SpaceEntry)
      ProjectPicker.space_entries(@marks.size)
    end

    # Where `space` opens the action menu: a project row, marks or no marks. It was briefly
    # allowed from New/Temp while marks were set, and that was wrong twice over — three of the
    # five entries (Open/Rename/Compress) are cursor-only, so they closed the menu in silence
    # with no cursor project to act on, and the footer had to grow "space actions" on the row
    # that already carries ctrl-n/ctrl-t, pushing `ctrl-c quit` off an 80-column terminal.
    # Marks still reach a delete from anywhere via ctrl-d, which needs no cursor row.
    #
    # THE single source of the rule: the key ladder and the footer hint (whose "space actions"
    # token is clickable) both read it, so the row can never offer a button the chord doesn't
    # honour. The Search row is excluded by the same rule — it is a text field, so space types.
    private def space_opens_menu? : Bool
      @selected >= 3
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

    # Delete reads target_projects (marks, else the cursor) rather than the row the menu was
    # opened on, so it is the SAME resolver ctrl-d and the footer button go through. The
    # other three are single-target by design and stay on the cursor project — the menu says
    # so while marks are set (see ProjectPicker.space_entries).
    private def activate_space_entry(entry : SpaceEntry) : Project | Symbol?
      project = @space_project || selected_project
      close_space_menu
      case entry.action
      when :delete
        request_delete
        return nil
      when :mark_clear
        @marks.clear
        return nil
      end
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
          reload_projects # the dir slug is untouched by a rename, so any mark on it survives
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
    private def handle_compress(ev : Termisu::Event::Key) : Project | Symbol?
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
        reload_projects
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

    private def handle_new(ev : Termisu::Event::Key) : Project | Symbol?
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
      box, res_rows = ProjectPicker.card_metrics(w, h)
      return nil unless box.contains?(mx, my)
      arow = my - (box.y + 1)
      return arow if 0 <= arow < 3 # New / Temp / Search action rows
      list_top = box.y + 1 + 3 + 1 # action rows + divider
      vi = my - list_top
      return nil if vi < 0 || vi >= res_rows
      ri = @results_scroll + vi
      ri < filtered_projects.size ? ri + 3 : nil
    end

    private def handle_picker_mouse(ev : Termisu::Event::Mouse) : Project | Symbol?
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
      when :new, :rename then nil # text form — keyboard only (cursor placement is Phase 2)
      else
        # A blocking step (VACUUM, measure, the batch rm_rf) owns the loop — ignore clicks
        # rather than let one land on the list drawn under the busy card.
        BUSY_LABELS.has_key?(@mode) ? nil : handle_list_mouse(mx, my)
      end
    end

    # Click a compress-popup row to focus + toggle it (or open the confirm on the
    # Compress row); a click outside the card dismisses, like the other overlays.
    private def handle_compress_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Project | Symbol?
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
    private def handle_list_mouse(mx : Int32, my : Int32) : Project | Symbol?
      w, h = @backend.size
      if action = hint_action_at(mx, my, w, h)
        return run_hint_action(action)
      end
      return nil unless idx = entry_at(mx, my)
      if idx == @selected
        activate
      else
        # Like a plain arrow, moving the cursor by click ends a ⇧arrow range and hands its
        # marks back; deliberate Tab marks stay. (So does the wheel — on this screen it moves
        # the selection rather than scrolling under it. See picker_wheel.)
        @marks.end_gesture
        @selected = idx
        @results_scroll = 0 if idx < 3 # focusing an action row shows the list from the top
        nil
      end
    end

    private def picker_wheel(delta : Int32) : Nil
      case @mode
      when :settings               then @preferences.wheel(delta)
      when :theme                  then (@theme_card.move_field(delta); preview_theme)
      when :space                  then @space_selected = (@space_selected + delta.sign).clamp(0, space_entries.size - 1)
      when :compress               then @compact.try(&.move(delta.sign))
      when :new, :confirm, :rename then nil # nothing to scroll
      when .in?(BUSY_LABELS.keys)  then nil # a blocking step owns the loop
      else
        # The picker's wheel moves the SELECTION (it has no independent scroll of its own),
        # so it is an arrow by another name and ends a ⇧arrow range exactly as one does.
        # Without this the anchor outlived a scroll: wheel down five rows, press ⇧↓ once,
        # and the range snapped back to the stale anchor — marking six projects on one key.
        move_selection(delta)
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

    private def handle_space_mouse(w : Int32, h : Int32, mx : Int32, my : Int32) : Project | Symbol?
      entries = space_entries
      box = space_menu_box(w, h)
      return close_space_menu unless box.contains?(mx, my) # click away → dismiss
      if idx = space_row_at(box, mx, my)
        if idx == @space_selected
          return activate_space_entry(entries[idx])
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
    #      art; each cell scrambles through ART_NOISE while its colour fades from
    #      near-canvas up to the gold, then settles on the mark's own block.
    #   2. Glint: a narrow bright band sweeps the same diagonal once — light
    #      catching the finished gold mark.
    #   3. The wordmark, then the tagline, fade in beneath it (see render_list).
    # Every timeline constant derives from BRAND_ART, so swapping the art re-times
    # the entrance. ART_ANIM_DONE is the frame at which everything has resolved —
    # the run loop freezes @art_frame there, and past it the same code paints the
    # identical static logo (band swept out, full gold, text at full strength).
    #
    # ART_NOISE is where the mark's personality lives: the resting figure is plain
    # blocks (legible, font-proof, same as the SVG — see Brand::ART), so the
    # scatter goes into the one second it takes to arrive. One band per reveal
    # stage, ordered light → heavy, so the cell still reads as ink accumulating
    # the way the old ░▒▓ ramp did while looking like noise resolving into a ring.
    # ASCII only: these land in real cells, so a two-cell glyph would smear the row.
    ART_NOISE = {
      {'.', ':', '\'', '`', ',', ';', '-'},
      {'+', '=', '*', '?', '/', '\\', '|', '<', '>'},
      {'#', '%', '&', '@', '8', '$', 'W', 'M'},
    }
    ART_ROW_SLOPE = 2 # diagonal metric d = col + row * SLOPE — the front's tilt
    ART_STAGGER   = 4 # d-units the wave front advances per frame
    ART_MAX_D     = BRAND_ART.map_with_index { |line, row| line.rstrip.size - 1 + row * ART_ROW_SLOPE }.max
    REVEAL_DONE   = ART_MAX_D // ART_STAGGER + ART_NOISE.size + 1
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
    # tall enough to keep a usable project list beneath the logo and wide enough
    # to fit the block without clipping; otherwise fall back to the wordmark.
    #
    # Both bounds derive from the figure, because it gets redrawn and a literal
    # stops matching it. Height: `card_metrics` spends `ART_H + 4` rows on the
    # brand block and 10 more on the card's chrome and margins, so `ART_H + 18`
    # is the shortest terminal that still leaves 4 project rows — go lower and the
    # card slides under the hint row. Width: ART_MIN_W plus a little air, so the
    # figure never sits flush against both edges.
    ART_MIN_H = Brand::ART_H + 18
    ART_MIN_W = Brand::ART_MIN_W + 6

    def self.art_shown?(w : Int32, h : Int32) : Bool
      h >= ART_MIN_H && w >= ART_MIN_W
    end

    # Rows reserved above the picker card for the brand block. With the art the
    # stack is [art][ART_GAP][gori][subtitle][gap]; without it just [gori][subtitle][gap].
    def self.brand_h(w : Int32, h : Int32) : Int32
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
        render_busy(screen, w, h) if BUSY_LABELS.has_key?(@mode)
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
    def self.card_metrics(w : Int32, h : Int32) : {Rect, Int32}
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
      box, res_rows = ProjectPicker.card_metrics(w, h)
      top = box.y - 3 # the "𝓰𝓸𝓻𝓲" wordmark sits 3 rows above the card

      # The decorative art (when it fits) sits ART_GAP rows above the wordmark;
      # card_metrics reserved ART_H + ART_GAP rows above `top` for exactly this.
      # The logo stack (art + wordmark + tagline) draws straight on the starred
      # canvas — no lifted panel band, and no band re-fill, which would punch a
      # starless hole across the backdrop render already painted.
      draw_brand_art(screen, top - ART_H - ART_GAP, w, @art_frame) if ProjectPicker.art_shown?(w, h)
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
      # The live mark count rides the divider the way the in-app mark chip rides the filter
      # row — including how much of the set the current search is hiding, since a mark
      # outlives the query that scrolled it off screen and still aims the next delete.
      # Guarded rather than relying on hidden_count's own empty fast path: the argument is
      # built BEFORE the call, so an unmarked picker — the overwhelmingly common state —
      # would allocate a full dir array 20 times a second for a chip that renders as "".
      count += ProjectPicker.mark_chip(@marks.size, @marks.hidden_count(fp.map(&.dir))) unless @marks.empty?
      screen.text(box.x + 2, div_y, " #{count} ", Theme.muted, Theme.panel, width: {cw - 4, 1}.max)
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
          # A marked row reads as a dim band with a FULLER gutter bar, so it stays legible
          # as marked next to the cursor row (accent band + ▎) and on the cursor row that is
          # ALSO marked (accent band + ▌) — the same two glyphs every marking list in gori
          # uses. Both are single-width, so the row never shifts.
          marked = @marks.marked?(proj.dir)
          bg = is_selected ? Theme.accent_bg : (marked ? Theme.selection_dim : Theme.panel)
          screen.fill(Rect.new(box.x + 1, py, cw - 2, 1), bg) if is_selected || marked
          screen.cell(box.x + 1, py, marked ? '▌' : (is_selected ? '▎' : ' '), Theme.accent, bg)
          meta, meta_fg = project_meta(proj)
          mdw = Screen.display_width(meta)
          name_w = cw - 3 - (mdw + 2)
          screen.text(box.x + 3, py, proj.name, is_selected || marked ? Theme.text_bright : Theme.text, bg, width: [name_w, 1].max)
          meta_x = box.right - mdw - 2
          screen.text(meta_x, py, meta, meta_fg, bg) unless meta.empty?
        end
      end

      companion = draw_companion(screen, w, h)
      render_notice_row(screen, companion, w, h)

      if tokens = list_hint_tokens
        render_hint(screen, tokens, h - 2, w)
      else
        hint = case
               when @mode == :compress
                 "↑/↓ select   ‹/› keep   space toggle   ↵ compress   esc close"
               when label = BUSY_LABELS[@mode]?
                 # Every blocking mode, off the one table — :measuring used to fall through
                 # to the :space arm below and label its busy card with the action menu's
                 # mnemonics, and :deleting would have joined it.
                 label.strip.downcase
               else # :space — mnemonics read off the live menu, so a mark-only entry
                 # (Clear marks) can't be missing from the row that lists them.
                 keys = space_entries.map { |e| "#{e.key} #{e.label.split(' ').first.downcase}" }.join("   ")
                 "↑/↓ select   ↵ run   #{keys}   esc close"
               end
        centered(screen, h - 2, hint, Theme.muted, w)
      end
    end

    # Miss Ring stands in the bottom-right corner, over the starfield and beside the card
    # — but only on the plain list: every other mode floats something of its own (the space
    # menu shares her corner outright), and the picker draws those AFTER the list, which
    # would clip her box and leave an orphaned corner behind.
    #
    # Returns her SPOT on this screen, which the notice row turns on — non-nil from the
    # frame she has room to stand on, not from the frame she first paints on. The gap is
    # the second the entrance animation holds her back for (see #tick_companion): the row must
    # already know she is coming, or it flashes the update notice she is about to deliver.
    private def draw_companion(screen : Screen, w : Int32, h : Int32) : Rect?
      return nil unless @mode == :list
      return nil unless rect = companion_rect(w, h)
      if frame = @companion.frame
        Companion.draw(screen, ProjectPicker.companion_stage(w, h), frame)
      end
      rect
    end

    # The row above the hint (h-3): a transient compaction result when present, else why
    # the last open failed, else the once-per-release "update available" notice. The
    # compaction flash is a direct response to a keypress, so it takes the row; the others
    # return when the flash clears on the next keystroke. The open error outranks the
    # update notice — one explains the screen the operator is looking at, the other is an
    # aside — and it persists rather than fading, since it is the ONLY on-screen trace that
    # a project failed to open.
    #
    # Miss Ring paints nothing here. She takes the row off the update notice while she is
    # saying it (and while she still owes it), because for those seconds her bubble IS the
    # notice — the row would otherwise carry the same news a second time, in a second
    # wording, three rows below the bubble carrying it.
    private def render_notice_row(screen : Screen, companion : Rect?, w : Int32, h : Int32) : Nil
      if flash = @flash
        centered(screen, h - 3, flash, @flash_ok ? Theme.green : Theme.red, w)
      elsif open_error = @open_error
        # Capped rather than left to run off the edge: a db path makes this the one notice
        # of unbounded length. The leading words carry the meaning, and gori.log has it all.
        centered(screen, h - 3, open_error, Theme.red, w, width: w - 2)
      elsif companion && (@update_line || companion_speaking?)
        # Her saying it IS the notice reaching the screen — the marker must burn here too,
        # or the row's own paint (seconds later, and only if the operator is still on this
        # screen) would be the sole path that ever records it.
        persist_update_notice if @update_spoken
      elsif notice = @update_notice
        centered(screen, h - 3, notice, Theme.yellow, w)
        persist_update_notice
      end
    end

    # Mark this release "read", once it has actually reached the screen — so a fetch that
    # lands as the user opens a project doesn't burn the one showing. Called from whichever
    # path painted it (the notice row, or Miss Ring saying it), hence the guard here rather
    # than at the call sites.
    private def persist_update_notice : Nil
      return if @notice_persisted
      @notice_persisted = true
      Settings.update_notified_version = @update_notice_version
      Settings.save
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
      tokens << HintToken.new("space actions", :space) if space_opens_menu?
      # On a project row the mark gesture TAKES the search hint's place rather than joining
      # it (and takes esc's new first meaning with it once marks are live). This row is the
      # widest thing the picker draws and it trims from the right, so a token added without
      # one given back pushes `ctrl-c quit` off the end — and on the action rows, where the
      # row is at its longest (ctrl-n/ctrl-t ride there), the search hint is the one that
      # applies and marking is not offered at all. Both are inert, like every token that
      # describes a gesture rather than a button.
      if @selected >= 3
        tokens << HintToken.new("tab mark")
        tokens << HintToken.new("esc clear") unless @marks.empty?
      else
        tokens << HintToken.new("type to search")
      end
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
    private def run_hint_action(action : Symbol) : Project | Symbol?
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
      ProjectPicker.space_menu_box(w, h, space_entries, space_menu_title)
    end

    # "SPACE · 3 MARKED" while a mark set is live — the picker's form of the Runner's space
    # menu banner, so opening the menu over marks announces up front that Delete below is
    # plural. Sized for BOTH the widest label and this title: Frame.card ellipsizes a title
    # past `w - 4`, and a menu that silently truncates its own count is worse than no count.
    private def space_menu_title : String
      @marks.empty? ? "SPACE" : "SPACE · #{@marks.size} MARKED"
    end

    def self.space_menu_box(w : Int32, h : Int32, entries : Array(SpaceEntry), title : String) : Rect
      label_w = entries.max_of { |e| Screen.display_width(e.label) }
      mw = {label_w + 6, Screen.display_width(title) + 5, 16}.max # border + ▎ + key + gap + label + border
      mw = {mw, w - 2}.min
      mh = entries.size + 2
      x = {w - mw - 2, 0}.max
      y = {h - mh - 3, 1}.max # above the hint row
      Rect.new(x, y, mw, mh)
    end

    private def space_row_at(box : Rect, mx : Int32, my : Int32) : Int32?
      i = my - (box.y + 1)
      return nil if i < 0 || i >= space_entries.size
      return nil if mx <= box.x || mx >= box.right - 1
      i
    end

    private def render_space_menu(screen : Screen, w : Int32, h : Int32) : Nil
      box = space_menu_box(w, h)
      Frame.card(screen, box, space_menu_title, border: Theme.border_focus)
      space_entries.each_with_index do |entry, i|
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
    # The blocking steps the picker runs on its own event loop, and what the busy card calls
    # each. Keyed by @mode so `render` needs no growing `||` chain, and so a mode added
    # without a label can't silently paint a blank card.
    BUSY_LABELS = {
      :measuring   => " Measuring … ",
      :compressing => " Compressing … ",
      :deleting    => " Deleting … ",
    }

    private def render_busy(screen : Screen, w : Int32, h : Int32) : Nil
      msg = BUSY_LABELS[@mode]? || " Working … "
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

    # `width` caps the drawn text (Screen#text ellipsizes past it). Uncapped by default,
    # matching every caller that passes a message it has already sized; pass it for text
    # of unbounded length (a db path in an open error), which would otherwise clamp to
    # x=0 and run off the right edge into the hint row.
    private def centered(screen : Screen, y : Int32, text : String, fg : Color, w : Int32,
                         attr : Attribute = Attribute::None, width : Int32? = nil) : Nil
      screen.text({(w - text.size) // 2, 0}.max, y, text, fg, Theme.bg, attr: attr, width: width)
    end

    # Draw BRAND_ART as one centered block: every line starts at the same left
    # edge (derived from the ink extent — see ART_LEFT/ART_INK_W) so the figure
    # keeps its shape rather than each row centering on its own width. Accent
    # colour so it reads as a logo mark distinct from the wordmark beneath it.
    #
    # `frame` drives the entrance (see the timeline constants above): the diagonal
    # wave front reveals cells by their d-coordinate, each scrambling through
    # ART_NOISE and fading up to the gold before settling on the figure's own
    # glyph; the glint band then sweeps the same diagonal once. Past ART_ANIM_DONE
    # every cell has settled, so the same call renders the final static logo — the
    # one Help → About draws.
    private def draw_brand_art(screen : Screen, y : Int32, w : Int32, frame : Int32) : Nil
      x = {(w - ART_INK_W) // 2 - ART_LEFT, 0}.max
      BRAND_ART.each_with_index do |line, i|
        line.each_char_with_index do |ch, col|
          next if ch == ' '
          d = col + i * ART_ROW_SLOPE
          prog = frame - d // ART_STAGGER
          next if prog <= 0 # not yet reached by the wave front
          settled = prog > ART_NOISE.size
          glyph, fg = art_cell(prog, ch, col, i, frame)
          fg = glint_tint(d, frame, fg) if settled
          screen.cell(x + col, y + i, glyph, fg, Theme.bg, attr: Attribute::Bold)
        end
      end
    end

    # Glyph + colour for a cell `prog` frames after the wave front reached it: a
    # scrambled ART_NOISE glyph from the band matching the stage, colour ramping
    # up toward full strength, then the cell's settled ink.
    #
    # `Brand.ink` resolves that settled pair — which for a far-ring cell is a
    # dimmed gold — and the ramp aims at it rather than at focus_gold, so the far
    # ring arrives at its own shade instead of reaching full gold and dropping
    # back a frame later.
    private def art_cell(prog : Int32, ch : Char, col : Int32, row : Int32, frame : Int32) : {Char, Color}
      glyph, settled_fg = Brand.ink(ch, Theme.focus_gold)
      return {glyph, settled_fg} if prog > ART_NOISE.size
      t = 0.35 + 0.65 * prog / (ART_NOISE.size + 1)
      {noise_glyph(col, row, frame, prog - 1), Theme.blend(settled_fg, Theme.bg, t)}
    end

    # A cell's scramble glyph. A pure hash of (col, row, frame, band) the way
    # star_hash is of (x, y): the reveal repaints several times per frame on a
    # resize or an overlay redraw, and a stored/random pick would make the same
    # frame render differently each time.
    private def noise_glyph(col : Int32, row : Int32, frame : Int32, band : Int32) : Char
      h = (col.to_u32! &* 0x9E3779B1_u32) ^ (row.to_u32! &* 0x85EBCA77_u32) ^ (frame.to_u32! &* 0xC2B2AE3D_u32)
      h ^= h >> 15
      h &*= 0x27D4EB2F_u32
      set = ART_NOISE[band]
      set[((h ^ (h >> 13)) % set.size.to_u32)]
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
      unless ProjectPicker.art_shown?(w, h)
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
      # The list is offset by the three pinned action rows, so the WINDOW tracks `@selected - 3`
      # against `filtered_projects` — the same array render_list windows from `@results_scroll`.
      @results_scroll = Viewport.scroll_to_show(@selected - 3, @results_scroll, list_h,
        filtered_projects.size)
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
