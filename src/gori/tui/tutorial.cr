require "termisu"
require "./geometry"
require "./screen"
require "./theme"
require "./frame"
require "./chrome"
require "./layout"
require "./mascot"
require "./notifications"
require "./companion"
require "./palette"
require "../settings"
require "../verb"

module Gori::Tui
  # A guided, standalone tour of gori's TUI, shown right after the setup wizard
  # (when the user opts in) and re-runnable via `gori tutorial`. It is NOT wired
  # into the live Runner: like SetupWizard it owns its own full-screen run loop,
  # so it fully captures input and can't disturb any real session.
  #
  # It teaches the four moves a new user reaches for most — moving between
  # tabs/panes, the action menu (space), the command palette (^P), and edit mode
  # (READ/INS) — each on a harmless MOCK of the real UI (nothing here is real),
  # drawn with the same Screen/Frame/Theme primitives the app uses. Then the traffic
  # itself (#1382): where to point a client and trust the CA, the capture switch, and
  # intercept — the lesson that also untangles `i` (INS in an editor, intercept elsewhere).
  #
  # The menu comes before the palette because the palette's hint column SPELLS menu paths
  # (`Hotkeys.menu_path`, #1282): a search result tells you the letters that reach it next
  # time, and those read as noise to someone who has not yet opened the menu once. The two
  # mocks' rows are real verbs read from the registry, so their letters and keys are the
  # app's, and move when the app's do.
  #
  # Flow: short explanation + looping demo on each lesson, with a soft "try it"
  # goal so users make the whole move at least once; the two traffic lessons; a
  # hands-on Practice sandbox for the four UI moves; Help and quitting; finally a
  # "first session" checklist.
  # Progression is never blocked — clickable Prev/Next buttons always work.
  class Tutorial
    # The mock tab bar: the real bar's first five NUMBERED SLOTS, in the order a default
    # install has them (Chrome::DEFAULT_HIDDEN leaves Project·Target·History·Intercept·
    # Repeater in slots 1-5).
    #
    # Five, not the nine the real bar holds, because a numbered chip costs two cells more
    # than a bare one and the card is 78 columns at its widest: nine would overflow the
    # strip and `tab_chip_rects` would drop the right-hand chips — a mock bar whose last
    # digits point at nothing, in the lesson about the digits. Five fit at 80 columns with
    # the focus badge beside them, which is the terminal the new users this tour exists for
    # are most likely to be running.
    TABS = %w[Project Target History Intercept Repeater]

    # The mock tab the menu and palette lessons stand on: their rows are History's, so the bar
    # has to say History, not whichever tab the previous lesson left highlighted.
    HISTORY_TAB = 2

    # Short labels for the progress rail — keep them narrow: all ten chips fit at 80 columns
    # (`rail_width`, spec-gated), below that the rail falls back to dots.
    STEP_RAIL = [
      {"intro", Step::Welcome},
      {"nav", Step::Navigate},
      {"menu", Step::SpaceMenu},
      {"palette", Step::Palette},
      {"edit", Step::Edit},
      {"proxy", Step::Capture},
      {"catch", Step::Intercept},
      {"try", Step::Practice},
      {"exit", Step::Leave},
      {"done", Step::Done},
    ]

    # Interior content rows the tallest lesson wants (explanation + gap + the mock
    # shell). The card is sized to this when the terminal allows and degrades
    # gracefully below it (every mock draw guards on its rect).
    CONTENT_ROWS = 15
    MIN_CARD_H   = 12 # below this the card can't hold a legible mock → "too small"
    CARD_W       = 78
    HEADER_ROWS  =  2 # brand + progress rail
    FOOTER_ROWS  =  2 # hint + Prev/Next buttons

    # Rows the mock wants: the tab bar, the keyhint row under it, and panes tall enough to
    # show every FLOW_ROWS row. `render_shell` refuses to draw at all below 5 (its panes are
    # clamped to 3 rows and would spill past the rect), and `lesson_split` hands it these
    # rows BEFORE the prose so it can never fall through that floor.
    SHELL_ROWS = 7

    # Columns Miss Ring's stand claims at the right edge, when she is on: the sprite, the
    # GUTTER Companion.place already keeps clear of it, and ONE more for the plate strip
    # Companion.draw paints at `rect.x - 1`.
    #
    # She stands only where the card keeps its full CARD_W beside this band (#1381). She is
    # on by default since #1096, and narrowing the card to seat her at 80 columns cost the
    # lesson its own content there: the Navigate lines truncated, the mock bar lost its fifth
    # chip while the footer still said "1-5", and the Done card fell back to its short form.
    # The lesson outranks the mascot, so below ~94 columns she is simply not drawn.
    COMPANION_BAND = Companion::GUTTER + Mascot::W + 1

    # Fake palette rows used by the palette lesson + practice overlay: sigil, label, and the
    # fake tab index the row switches to (nil = the row only closes the palette). The action
    # rides its own slot so the label is free to be reworded or translated without the
    # practice step's "Go to …" quietly turning into a no-op.
    #
    # Every index here must name a chip the mock bar actually draws (spec-gated): a row
    # pointing past TABS set @p_tab to a tab no chip matches, so the palette closed onto a
    # bar with NOTHING highlighted. Help is the tab that lost its index — it starts off the
    # bar now (Chrome::DEFAULT_HIDDEN), which is exactly why its row still reads "Open Help"
    # and carries no number: the palette is one of the doors (`?`, `0`, ^P) that reach a tab
    # no digit does.
    #
    # These are the APP half, the one an empty query browses. `Settings: Companion` is there so
    # the lesson's query (PALETTE_DEMO_QUERY) finds a row in both groups, as it does in the app.
    PALETTE_ROWS = [
      {"»", "Go to Repeater", 4},
      {"≡", "Settings: Theme", nil},
      {"≡", "Settings: Companion", nil},
      {"×", "Quit gori", nil},
      {"»", "Go to History", 2},
      {"?", "Open Help", nil},
    ]

    # The palette's THIS TAB half (#1282): real History verbs, read from the registry when the
    # tour starts. Each row's hint is the one the real palette prints beside it — the direct
    # key, else the space-menu path — so a rebind or a moved letter moves it here too. Send to
    # Comparer comes first because it has NO key: its hint is the menu path, which is the
    # lesson (search once, and the palette tells you the short route for next time).
    PALETTE_TAB_VERBS = %w[history.compare history.fuzz history.repeater history.copy history.query]

    # What the palette lesson asks the user to type, and what its demo types: it finds Send to
    # Comparer under THIS TAB and a Settings row under APP, so both groups are on screen.
    PALETTE_DEMO_QUERY = "comp"

    # The mock space menu over History's list: its level-1 rows, and the second card that the
    # Send flow to… family row opens (#1274). Verb ids, never letters — the letters come from
    # the registry (`Tutorial.space_rows`), and a hand-typed one is what
    # spec/verb/hint_token_expands_spec.cr exists to refuse.
    SPACE_VERBS = %w[body.open history.repeater history.copy history.query]
    SEND_VERBS  = %w[history.repeater history.fuzz history.compare]

    # Where the family row sits among SPACE_VERBS: after the Repeater row, as in the real card's
    # SEND group, and high enough to stay drawn when a short card clips the list.
    SEND_ROW_AT = 2

    # Cap on the mock menu's width: enough for the second card's `SPACE › SEND FLOW TO` title.
    SPACE_MENU_W = 30

    # One row of the mock space menu: the letter that runs it, the verb's title, the right-hand
    # column (the direct key, or `›` on a row that opens a second card), and whether it opens
    # one instead of running.
    record MenuRow, key : Char, title : String, hint : String, opens : Bool = false

    # One command of the mock palette: sigil, label, hint column, the fake tab a "Go to …" row
    # switches to, and whether it is one of the focused tab's own actions (THIS TAB).
    record PalRow, sigil : String, label : String, hint : String, tab : Int32?, this_tab : Bool

    def self.space_rows(registry : Verb::Registry) : Array(MenuRow)
      rows = SPACE_VERBS.compact_map { |id| level1_row(registry, id) }
      fam = Verbs::SEND_FLOW
      rows.insert({SEND_ROW_AT, rows.size}.min, MenuRow.new(fam.key, fam.title, "›", opens: true))
    end

    # The family's card, lettered by the family table (`Registry#l2_key`), which is the same on
    # every tab — the thing worth seeing once.
    def self.send_rows(registry : Verb::Registry) : Array(MenuRow)
      SEND_VERBS.compact_map do |id|
        next unless (v = registry[id]?) && (k = registry.l2_key(v))
        MenuRow.new(k, v.title, chord_hint(registry, id, k))
      end
    end

    # The second card's title, as the real one reads (`SPACE › SEND FLOW TO`).
    def self.send_card_title : String
      "SPACE › #{Verbs::SEND_FLOW.title.rchop('…').upcase}"
    end

    # The same column `PaletteState#fast_path` draws for a tab row: the chord's label, else the
    # compact menu path.
    def self.palette_tab_rows(registry : Verb::Registry) : Array(PalRow)
      PALETTE_TAB_VERBS.compact_map do |id|
        next unless v = registry[id]?
        hint = Hotkeys.binding_for(registry, id).try(&.label) ||
               Hotkeys.menu_path(registry, id, compact: true) || ""
        PalRow.new("▸", v.title, hint, nil, true)
      end
    end

    # The palette's commands for `query`, THIS TAB first. An empty query is the app-wide
    # browse and lists no tab rows, as in the app.
    def self.palette_matches(query : String, tab_rows : Array(PalRow)) : Array(PalRow)
      app = PALETTE_ROWS.map { |(sig, label, tab)| PalRow.new(sig, label, "", tab, false) }
      q = query.downcase
      return app if q.empty?
      (tab_rows + app).select(&.label.downcase.includes?(q))
    end

    # The drawn rows: a group header, or an index into `matches`. Grouped only when a tab row
    # matched, the rule `PaletteState#display_rows` follows, so the browse stays a flat list.
    def self.palette_display(matches : Array(PalRow)) : Array({String, Int32?})
      tab = matches.count(&.this_tab)
      rows = [] of {String, Int32?}
      if tab > 0
        rows << {PaletteState::TAB_HEADER, nil}
        tab.times { |i| rows << {"", i} }
        rows << {PaletteState::APP_HEADER, nil} if matches.size > tab
        (tab...matches.size).each { |i| rows << {"", i} }
      else
        matches.each_index { |i| rows << {"", i} }
      end
      rows
    end

    private def self.level1_row(registry : Verb::Registry, id : String) : MenuRow?
      return nil unless (v = registry[id]?) && (keys = registry.menu_keys(id)) && keys.size == 1
      MenuRow.new(keys[0], v.title, chord_hint(registry, id, keys[0]))
    end

    # The rule `SpaceMenu#chord_hint` draws by: a chord equal to the row's own letter is not
    # repeated beside it (the real card reads `y Copy flow`, never `y Copy flow y`).
    private def self.chord_hint(registry : Verb::Registry, id : String, key : Char) : String
      return "" unless c = Hotkeys.binding_for(registry, id)
      label = Hotkeys.display_label(c)
      label == key.to_s || label == key.to_s.upcase ? "" : label
    end

    # How to reach `id` from memory: its effective chord, else its menu path (`Hotkeys.route`),
    # else the palette search that finds it (`^P → Open browser`). Read from the registry, so
    # a rebind or a moved row moves every line of the tour that names it (#1380).
    def self.reach(registry : Verb::Registry, id : String) : String
      if chord = Hotkeys.binding_for(registry, id)
        return Hotkeys.display_label(chord)
      end
      Hotkeys.route(registry, id) ||
        "#{Hotkeys.binding_label(registry, "app.palette", "^P")} → #{registry[id]?.try(&.title) || id}"
    end

    # POST first, so the REQUEST pane a lesson opens on is a request with a body to type into.
    FLOW_ROWS = [{"POST", "/login", 401}, {"GET ", "/api/users", 200}, {"GET ", "/admin", 500}]

    # The mock tabs that carry a SUBTABS strip, and its chips: the real Project and Target
    # sets. As in the app, a digit lands on the bar, ↓ on the strip, and ↓ again in the body
    # (Runner#enter_content) — so the Navigate lesson, which starts on Target, passes one.
    def self.strip_labels(tab : Int32) : Array(String)?
      case tab
      when 0 then ProjectView::PANE_LABELS
      when 1 then TargetController::SUBS
      end
    end

    # The Navigate lesson's looping demo: {tab, focus level, pane, the key shown}. It walks
    # the path the lesson asks for — a digit onto Target, down through its strip into the
    # body, and back up — on the two chips every card size draws (spec-gated).
    NAV_DEMO = [
      {0, :menu, 0, ""},
      {1, :menu, 0, "2"},
      {1, :strip, 0, "↓"},
      {1, :body, 0, "↓"},
      {1, :body, 1, "⇥"},
      {1, :strip, 0, "esc"},
      {1, :menu, 0, "esc"},
      {0, :menu, 0, "1"},
    ]

    enum Step
      Welcome
      Navigate
      SpaceMenu
      Palette
      Edit
      Capture   # proxy address, CA trust, the capture switch
      Intercept # hold, forward/drop, release
      Practice  # hands-on sandbox: the user drives the mock
      Leave     # Help, quitting, closing a project
      Done
    end

    # The tour can lead to four different places. Its last card must describe the
    # actual next screen, especially on first launch (wizard → tour → project picker
    # or the --db session, with a picker fallback on open failure).
    enum Handoff
      Picker
      Direct
      Shell
      Session
    end

    # Every key here is the registry's (`Tutorial.reach`), never a literal: a rebound chord, or
    # a palette-only verb, is taught the way the app answers it now (#1380). Only the first
    # line is prose, and it goes through `Hotkeys.retag` for its ^P.
    def self.first_session_steps(handoff : Handoff, width : Int32,
                                 registry : Verb::Registry = Verbs.registry) : Array(String)
      browser, ca = reach(registry, "browser.open"), reach(registry, "ca.export")
      cap, ins = reach(registry, "capture.toggle"), reach(registry, "editor.insert")
      to_rep, send = reach(registry, "history.repeater"), reach(registry, "repeater.send")
      help, tour = reach(registry, "tab.help"), reach(registry, "help.tour")
      if width < 66
        first = case handoff
                when Handoff::Picker  then "New project → name → ↵ twice"
                when Handoff::Direct  then "--db opens · picker if it fails"
                when Handoff::Shell   then "gori → New project → name → ↵↵"
                when Handoff::Session then "Back in session · ^P palette"
                else                       raise "unknown tutorial handoff"
                end
        return [
          Hotkeys.retag(first),
          "#{browser} (trusts CA)",
          "CA: #{ca}",
          "#{cap} if off · visit site → History",
          "Flow → #{to_rep} Repeater · #{ins} · #{send} send",
          "#{help} Help · #{tour}",
        ]
      end
      first = case handoff
              when Handoff::Picker
                "At the picker: New project → name → ↵ twice (description optional)"
              when Handoff::Direct
                "Open your --db project; if picker appears, choose a project"
              when Handoff::Shell
                "Run gori → New project → name → ↵ twice (description optional)"
              when Handoff::Session
                "Back in your session: open the command palette with ^P"
              else
                raise "unknown tutorial handoff"
              end
      [
        Hotkeys.retag(first),
        "#{browser} — proxied, and it already trusts gori's CA",
        "Other clients: trust the CA — #{ca}",
        "If capture is off, press #{cap} · visit a site you may test · History",
        "Pick a flow · #{to_rep} → Repeater · edit (#{ins}) · #{send} send",
        "#{help} for Help · #{tour} anytime",
      ]
    end

    # The footer is the tour's exit route at the advertised 40-column floor. Its
    # long lesson hints can be ellipsized there, so keep a short, truthful one for
    # each state rather than losing the keys at the right-hand end.
    def self.compact_footer_hint(step : Step, overlay : Symbol = :none,
                                 insert : Bool = false, armed : Bool = false,
                                 registry : Verb::Registry = Verbs.registry) : String
      return "esc again to leave · any key stays" if armed
      return "↵ run · esc close · then n next" unless overlay == :none
      return "type · esc READ · then n next" if insert
      compact_step_hint(step, registry)
    end

    private def self.compact_step_hint(step : Step, registry : Verb::Registry) : String
      case step
      when Step::Welcome   then "↵/n start · esc esc leave"
      when Step::Navigate  then "2/↓/↑ move · n next · b back"
      when Step::SpaceMenu then "space menu · n next · b back"
      when Step::Palette   then Hotkeys.retag("^P palette · n next · b back")
      when Step::Edit      then "i INS · n next · b back"
      when Step::Capture   then "#{reach(registry, "capture.toggle")} capture · n next · b back"
      when Step::Intercept then "#{reach(registry, "intercept.toggle")} hold · n next · b back"
      when Step::Practice  then "n next · b back · keep trying"
      when Step::Leave     then "↵/n next · b back · esc esc leave"
      when Step::Done      then "↵/n finish · esc esc leave"
      else                      raise "unknown tutorial step"
      end
    end

    # No `i` here: outside an editor it is intercept, and a cheat-sheet line has no room to
    # say which (#1380). The Intercept lesson is where that is taught.
    def self.done_extra_lines(width : Int32, registry : Verb::Registry = Verbs.registry) : {String, String}
      pal, help = reach(registry, "app.palette"), reach(registry, "tab.help")
      if width < 50
        {"Keys: 1-9 · space · #{pal} · #{help} help", "Re-run: gori tutorial"}
      elsif width < 71
        {"Keys: 1-9 tabs · space menu · #{pal} find · #{help} help", "Re-run: gori tutorial"}
      else
        {"Cheat-sheet: 1-9 tabs · space menu · #{pal} find · #{help} help · ^D ×2 quit",
         "Re-run this tour anytime:  gori tutorial"}
      end
    end

    # What the too-small screen says, shortened to what fits: its exit key is the one thing
    # that must survive the cut (#1381).
    def self.too_small_message(w : Int32) : String
      ["terminal too small for tutorial — min 40x16, resize & retry (esc to leave)",
       "too small — min 40x16 · esc leaves",
       "40x16 · esc leaves"].find { |m| Screen.draw_width(m) <= w } || "esc"
    end

    # `registry` is the session's when the tour runs from inside one (Runner#open_tutorial), so
    # the mock menus read the same letters and keys the user just left.
    def initialize(@term : Termisu, @handoff : Handoff = Handoff::Shell,
                   @registry : Verb::Registry = Verbs.registry)
      registry = @registry
      @space_rows = Tutorial.space_rows(registry)
      @send_rows = Tutorial.send_rows(registry)
      @pal_tab_rows = Tutorial.palette_tab_rows(registry)
      # Held as the base Backend: TermisuBackend is generic over the terminal type.
      @backend = TermisuBackend.new(@term).as(Backend)
      @step = Step::Welcome
      @tick = 0        # loop counter driving the demo animations (advances ~20/s)
      @resized = false # forces a full repaint after a resize
      @running = false

      # Soft per-lesson try-it flags (encouraged, not blocking — Next always works). Each is set
      # only by the WHOLE move its try line asks for, never by the first key of it (#1382).
      @tried_nav = false
      @tried_palette = false
      @tried_space = false
      @tried_edit = false
      @tried_capture = false
      @tried_intercept = false
      @practice_completed = false # latched: Practice's goals reset each time it is entered

      # The rail tells "been there" from "done that": a step is ✓ only when completed
      # (#step_completed?), and merely visited otherwise (#1382).
      @visited = Set{Step::Welcome}

      # A one-line answer to a key the mock does not do what the app does with — `i` outside
      # an editor, `0`, ↵ in INS — shown in the footer's hint row for ~3s (#nudge).
      @nudge = nil.as(String?)
      @nudge_until = 0

      # Shared live mock state (Navigate takeover + Practice sandbox).
      @p_level = :menu # :menu (tab bar) | :strip (SUBTABS) | :body
      @p_tab = 0
      @p_pane = 0       # 0 = FLOWS, 1 = REQUEST
      @p_flow = 0       # selected row in FLOWS
      @p_sub = 0        # selected chip on a SUBTABS strip
      @p_switch = false # switched tabs
      @p_enter = false  # reached a tab's body
      @p_up = false     # climbed back to the tab bar with ↑ or esc

      # The traffic lessons' mock: the capture switch, and an intercept with its held queue.
      @m_capture = true
      @m_cap_off = false # capture was switched off this lesson (the first half of its try)
      @m_intercept = false
      @m_held = 0
      @m_held_on = false  # intercept was switched on this lesson
      @m_released = false # a held request was forwarded or dropped with its own key

      # Practice-only goals for palette / space / edit (lessons use @tried_*).
      @p_palette = false
      @p_space = false
      @p_edit = false

      # Overlay / edit sandbox driven by the user (lessons + practice).
      @overlay = :none # :none | :palette | :space
      @pal_sel = 0
      @pal_query = "" # live filter string (palette lesson + practice)
      @space_sel = 0
      @space_level = 1 # 1 = the menu, 2 = the Send flow to… card its family row opens
      @edit_insert = false
      @edit_typed = ""
      # Once the user touches keys on Navigate, stop the auto-demo and hand over.
      @nav_live = false
      # esc at the top level arms the leave-the-tour prompt; a second esc leaves. See
      # #handle_escape for why one press is not enough.
      @esc_armed = false

      # Hit-test rects rebuilt every frame for mouse (0-based screen coords).
      @prev_btn = Rect.new(0, 0, 0, 0)
      @next_btn = Rect.new(0, 0, 0, 0)
      @shell_rect = Rect.new(0, 0, 0, 0)
      @tab_hits = [] of {Rect, Int32}  # mock tab chip → index
      @rail_hits = [] of {Rect, Int32} # progress-rail chip → step value
      @flows_rect = Rect.new(0, 0, 0, 0)
      @request_rect = Rect.new(0, 0, 0, 0)
      @strip_rect = Rect.new(0, 0, 0, 0)
      @palette_rect = Rect.new(0, 0, 0, 0)
      @space_rect = Rect.new(0, 0, 0, 0)

      # Miss Ring (settings:companion), the same widget the session and the picker run — off by
      # default, and the same zero-cost no-op while off. Like the picker she has no
      # notification ring here (the tour opens no project), so everything she says beyond
      # her hello is handed to her directly via Companion#say.
      #
      # SHE REACTS; THE CARD TEACHES. Every lesson's explanation stays in the card where
      # it already is, and she only ever confirms a move the user just made. That is what
      # keeps her honest against Companion#say's `companion_notices?` gate: a reader who turned her
      # speech off gets a tour missing some encouragement, never a tour missing the
      # lesson. Teaching content may not live in a bubble.
      @companion = Companion.new(Notifications.new)
      @companion_said = Set(Symbol).new # goals she has already reacted to (rising edge, once each)
    end

    # Whether the user left through Done's Finish, rather than esc/^C. `gori tutorial` prints
    # its "next:" line only then.
    getter? finished = false

    # Run the tour to completion (Done + Next/Finish) or until the user leaves
    # (esc). Returns when done; the caller continues after.
    def run : Nil
      @running = true
      loop do
        @practice_completed ||= @step.practice? && practice_done?
        tick_companion
        render
        # Own event loop — fold ⌥P onto ^P so the "try the palette" goal below can be
        # completed with whichever modifier the user configured.
        case ev = Keybind.dealias_event(@term.poll_event(50))
        when Termisu::Event::Resize then (@backend.resize(ev.width, ev.height); @resized = true)
        when Termisu::Event::Key    then (@companion.wake_on_input; handle_key(ev))
        when Termisu::Event::Mouse  then (@companion.wake_on_input; handle_mouse(ev))
        end
        @tick &+= 1
        break unless @running
      end
    end

    # --- Miss Ring -----------------------------------------------------------

    # No dirty-tracking around the tick (unlike the Runner's): this loop already repaints
    # every poll, so her `changed` verdict has nothing here to gate — the same bargain
    # ProjectPicker#tick_companion makes.
    private def tick_companion : Nil
      companion_watch_goals
      @companion.tick(Time.instant)
    end

    # What she says, per goal. Retagged (^P → ⌥P) at the say site so she names the chord
    # the user actually configured, exactly as the card titles do.
    COMPANION_LINES = [
      {:nav, "that's it — tab bar up top, body below"},
      {:space, "space acts on whatever's selected"},
      {:palette, "type a name, and it shows you the key"},
      {:edit, "INS to type, esc back to READ"},
      {:capture, "that dot is the recorder"},
      {:intercept, "held, decided, released — nice"},
      {:practice, "all six! you're ready"},
      {:done, "that's the tour — go break something"},
    ]

    # Rising-edge watch over the tour's OWN goal flags, run once per frame.
    #
    # The flags are set at a dozen scattered sites (lesson try-its, practice, the mock's
    # mouse handlers), and threading a reaction through each of them would put her in the
    # middle of code that has nothing to do with her. Watching the flags instead keeps
    # every line she says in one table, and means a goal reached by a route nobody thought
    # about still gets its reaction.
    #
    # ONE AT A TIME, AND ONLY WHILE SHE IS SILENT. Several goals can be reached before she
    # has said anything — a user who jumps straight to Practice via the rail, or a single
    # keystroke on the REQUEST pane that sets @p_edit and completes the practice set at
    # once — and firing them together would let the last line stomp the rest.
    #
    # "One per frame" is NOT enough to pace that, which is what this originally did: the
    # run loop polls on a 50ms timeout, so the next frame is ~50ms away while a :success
    # bubble lives for 3500ms. The queued line would replace the previous one before it
    # could be read. Waiting for the bubble to clear is the only pacing that matches how
    # long she actually speaks for, so the backlog drains one readable line at a time.
    private def companion_watch_goals : Nil
      return unless Settings.companion?
      return if companion_speaking?
      COMPANION_LINES.each do |(goal, line)|
        next unless companion_goal_reached?(goal)
        return if companion_react(goal, Hotkeys.retag(line))
      end
    end

    # Whether a bubble is still on screen. Not the text — nothing here paints her line, she
    # says it in her own bubble — only whether the next reaction has to wait its turn.
    private def companion_speaking? : Bool
      !@companion.frame.try(&.bubble).nil?
    end

    private def companion_goal_reached?(goal : Symbol) : Bool
      case goal
      when :nav       then @tried_nav
      when :palette   then @tried_palette
      when :space     then @tried_space
      when :edit      then @tried_edit
      when :capture   then @tried_capture
      when :intercept then @tried_intercept
      when :practice  then practice_done?
      when :done      then @step.done?
      else                 false
      end
    end

    # React to a goal the user just completed, ONCE per tour; true when she actually spoke.
    # `goal` is the latch, not the step: the lessons set @tried_* and Practice sets @p_*,
    # and a user who does the same move in both should not be congratulated for it twice.
    #
    # Set#add? IS the latch — the caller must not pre-check membership, or the same fact
    # ends up spelled two ways and a later edit has to prove they agree. Loop-internal:
    # companion_watch_goals owns the Settings.companion? gate. Companion#say is gated on `companion_notices?` for
    # the rest, which is deliberate (see the note on @companion above).
    private def companion_react(goal : Symbol, line : String, level : Symbol = :success) : Bool
      return false unless @companion_said.add?(goal)
      @companion.say(line, Time.instant, level)
      true
    end

    # --- input ---------------------------------------------------------------

    # The character a keystroke carries WHEN IT IS NOT A CHORD, else nil.
    #
    # `Event::Key#char` is `@char || key.to_char`, so ^P arrives carrying 'p' and ⌥L
    # carrying 'l'. Every bare `ev.char == …` guard in this file was firing on the chord:
    # ^L switched a tab in Practice and ticked its "switch" goal, ^O ran the space menu's
    # `o Open` row, and both text-entry sites typed the chord's letter — ^P then ^T in the
    # palette lesson's filter left "pt" in the query box, on the lesson whose whole subject
    # is ^P. The real app guards this at every one of these sites
    # (Runner#handle_palette_key's `c && !ev.ctrl? && !ev.alt?`,
    # Runner#handle_space_menu_key's, TextField#handle_edit_key's); the tour guarded it
    # nowhere. ONE home for the rule, spec-able without a tty, so they cannot drift apart
    # again.
    #
    # The chords the tour DOES bind are matched on `ev.ctrl?` + `ev.key` before this is ever
    # reached (`palette_open_key?`), so nothing that wants a modifier comes through here.
    # `Keybind.dealias` composes: it rebuilds the ⌥P event with `char: nil` and Ctrl set, so
    # `to_char` still yields 'p' and this catches the aliased path too.
    def self.bare_char(ev : Termisu::Event::Key) : Char?
      return nil if ev.ctrl? || ev.alt?
      ev.char
    end

    # …and the text-entry half: what a keystroke should INSERT, or nil.
    #
    # Non-control rather than the printable-ASCII window this replaced (`ord >= 32 && < 127`),
    # matching `TextField#insert`: the tour's INS demo asks the user to "type a username" and
    # then silently dropped every Hangul/CJK/accented character they typed. Enter and
    # Backspace are handled by their own branches ahead of this and carry control chars
    # anyway.
    def self.typed_char(ev : Termisu::Event::Key) : Char?
      return nil unless ch = bare_char(ev)
      ch.control? ? nil : ch
    end

    private def handle_key(ev : Termisu::Event::Key) : Nil
      key = ev.key

      if ev.ctrl_c?
        @running = false
        return
      end

      # The too-small screen paints no overlay, INS or footer, so esc there leaves at once,
      # whatever is open underneath: the first press used to close an overlay nobody could
      # see (#1381). Nothing on that screen is a lesson worth guarding with a second press.
      if key.escape? && too_small?
        @running = false
        return
      end

      # Anything but esc disarms the leave-the-tour confirmation (see #handle_escape). Set
      # here rather than per-branch so a key handled deep in an overlay still counts. A nudge
      # answers the key that raised it, so the next one clears it (and may raise its own).
      @esc_armed = false unless key.escape?
      @nudge = nil

      # Tour navigation is independent of the mock — available so the user can
      # never get stuck (n/b, ⇧⇥). Letter keys are suppressed while typing.
      if tour_nav_key?(ev)
        handle_tour_nav(ev)
        return
      end

      # Overlay owns keys while open (esc/↵ close; ↑↓ move; type filters palette).
      return handle_overlay_key(ev) unless @overlay == :none

      # INS owns printables + esc (leave READ). Tour nav already handled above.
      if @edit_insert
        return handle_edit_key(ev)
      end

      # Esc: pop one level when the mock is live; leave the tour at the top.
      if key.escape?
        return handle_escape
      end

      # Practice / Navigate live: shell keys first. When practice goals are done,
      # ↵ matches the Next button so the keyboard path isn't a dead end.
      if @step.practice?
        if practice_done? && key.enter?
          advance
          return
        end
        handle_live_shell_key(ev, practice: true)
        return
      end
      if @step.navigate? && @nav_live
        handle_live_shell_key(ev, practice: false)
        return
      end

      # Soft try-it on passive lessons (before Next advances).
      case @step
      when Step::Navigate
        ch = Tutorial.bare_char(ev)
        if nav_switch_key?(ev) || digit_tab_key?(ev) || key.down? || key.enter? || ch == 'j' ||
           ch == '0' || edit_enter_key?(ev)
          start_nav_live
          handle_live_shell_key(ev, practice: false)
          return
        end
        # Opening either one is not the try-it: the ✓ waits for the move each lesson is about —
        # a search that turns up THIS TAB rows and runs one, a second card or a row run
        # (#run_overlay_selection, #open_send_card, #run_space_row).
      when Step::SpaceMenu
        if space_open_key?(ev)
          open_space
          return
        end
        if send_open_key?(ev)
          open_send_card
          return
        end
      when Step::Palette
        if palette_open_key?(ev)
          open_palette
          return
        end
      when Step::Edit
        if edit_enter_key?(ev) || key.enter?
          enter_insert
          return
        end
      when Step::Capture
        if verb_key?(ev, "capture.toggle")
          toggle_mock_capture
          return
        end
      when Step::Intercept
        return if handle_intercept_key(ev)
      end

      # Enter advances when the mock is not capturing it (welcome / done / skip).
      advance if key.enter?
    end

    # Keys that move the tutorial itself (not the mock UI). Checked first so
    # lessons can never trap the user. Uses letter keys every keyboard has:
    #   n = next · b = back · ⇧⇥ = back
    # (⇥ alone stays free for pane cycle in the mock.)
    # While typing in INS or with ANY overlay open (palette filter, or the space
    # menu that owns its own keys), n/b are NOT tour nav — the overlay consumes
    # them (the palette types them; the space menu ignores non-mnemonics) instead
    # of snapping the lesson forward/back. ⇧⇥ still escapes (checked first).
    #
    # Body focus in the mock does NOT suppress them, though it used to "to prevent
    # accidental jumps". Nothing in the mock's body binds n or b — the shell reads arrows,
    # hjkl, ⇥, ↵, i, space, ^P and digits — so the suppression protected no gesture and
    # only made two advertised keys dead: `footer_hint` goes on printing "n next · b back" in
    # exactly that state, and on a short terminal, where the mock does not draw at all, one ↓
    # left the user pressing them at a blank card with nothing to explain why. Free keys, and
    # this whole method exists so a lesson can never trap anyone.
    private def tour_nav_key?(ev : Termisu::Event::Key) : Bool
      return true if ev.key.back_tab?
      return false if @edit_insert
      return false unless @overlay == :none
      ch = Tutorial.bare_char(ev) # nil for ^P etc. — leave the chords alone
      ch == 'n' || ch == 'N' || ch == 'b' || ch == 'B'
    end

    private def handle_tour_nav(ev : Termisu::Event::Key) : Nil
      if ev.key.back_tab?
        back
        return
      end
      case Tutorial.bare_char(ev)
      when 'n', 'N' then advance
      when 'b', 'B' then back
      end
    end

    # Reached only with INS closed and no overlay open — `handle_key` dispatches both of those
    # ahead of this, and each owns its own esc (leave INS / close the overlay). This is the
    # rest: pop one level of the mock, or leave the tour.
    private def handle_escape : Nil
      if live_shell? && @p_level != :menu
        step_out
        return
      end
      # Top level, where esc leaves the tour — but only on a DELIBERATE second press.
      #
      # This tour spends two steps teaching esc as "go back" and Practice names `esc back` as
      # one of its six goals, so the press that arrives here is nearly always someone who
      # meant back and had already run out of levels: one step too far in Practice, or the
      # second half of the double-tap that dismisses an overlay (^P, esc to close, esc). A
      # single press ended the whole tour on the spot, and on the first-run path that is
      # permanent — App offers it only while settings.json is absent (which the wizard has
      # just written), and the Done step it discards is the only screen that names
      # `gori tutorial` as the way back.
      #
      # `footer_hint` announces the armed state, and any other key disarms it (#handle_key,
      # #handle_mouse), so this can't strand anyone in a mode they can't see — which is also
      # why the resize-and-retry screen, the one path that paints no footer, opts out (in
      # `handle_key`, ahead of every overlay and INS).
      if @esc_armed
        @running = false
      else
        @esc_armed = true
      end
    end

    private def live_shell? : Bool
      @step.practice? || (@step.navigate? && @nav_live)
    end

    # Shared shell keyboard model for Navigate (live) and Practice — the real app's:
    # ←/→ on the bar and 1-9 from anywhere switch tabs, esc back to tabs, ⇥ panes, ↑/↓
    # list, ↵ opens detail / INS on the request, ^P / space openers.
    #
    # No [ / ] here: the mock used to cycle tabs on them, and the lesson advertised it as
    # "[ / ] from anywhere" — a binding the real app does not have (there, [ / ] switch a
    # tab's SUB-tabs, e.g. Rewriter's rules/extract/bindings). A move that works only in the
    # tutorial is the one thing a tutorial must not teach.
    private def handle_live_shell_key(ev : Termisu::Event::Key, *, practice : Bool) : Nil
      key = ev.key
      # Bare, never the letter a chord happens to carry — ^L used to switch a tab and tick
      # Practice's "switch" goal. See Tutorial.bare_char.
      bare = Tutorial.bare_char(ev)

      # Digit jump (real app: 1-9 from anywhere). A digit past the mock's last chip is
      # SWALLOWED rather than passed on: on the real bar those slots exist, so the one thing
      # it must not do is fall through to another binding and teach that `7` means something
      # else. It lands on the BAR, as the app's does (a "select" gesture there too):
      # ↓ is what goes in.
      if (ch = bare) && ch >= '1' && ch <= '9'
        if idx = digit_tab(ch)
          @p_tab = idx
          @p_sub = 0
          @p_level = :menu
          mark_switch
        end
        return
      end
      # `0` is the app's Go to tab… picker, which the mock has no tabs beyond these for. Say
      # so, rather than let a key the lesson names do nothing at all (#1382).
      if bare == '0'
        nudge("#{reach("nav.goto")} opens Go to tab… in gori — this mock has only these")
        return
      end

      if palette_open_key?(ev)
        open_palette
        @p_palette = true if practice
        return
      end
      if space_open_key?(ev)
        open_space
        @p_space = true if practice
        return
      end
      # The bare family key opens its card from a pane, as in the app (#1295). Practice only:
      # Navigate is about moving, and a card popping up there would be a lesson out of turn.
      if practice && @p_level == :body && send_open_key?(ev)
        open_send_card
        @p_space = true
        return
      end

      # `i` is INS only in an editor; anywhere else in the app it is Global "hold all
      # traffic". The mock has no intercept to turn on, so it says what the press would have
      # done instead of doing nothing (#1380).
      if edit_enter_key?(ev) && !(@p_level == :body && @p_pane == 1)
        nudge("#{reach("intercept.toggle")} here = intercept on (holds traffic) · ⇥ to REQUEST first")
        return
      end

      case @p_level
      when :menu  then return practice_menu_key(ev)
      when :strip then return strip_key(ev)
      end

      # --- body --------------------------------------------------------------
      if key.tab?
        @p_pane = @p_pane == 0 ? 1 : 0
        return
      end

      # INS only on the REQUEST pane (matches real editors).
      if @p_pane == 1 && (edit_enter_key?(ev) || key.enter?)
        enter_insert
        @p_edit = true if practice
        return
      end

      # ↵ on FLOWS focuses the REQUEST pane (open the selected flow).
      if @p_pane == 0 && key.enter?
        @p_pane = 1
        return
      end

      if key.down? || bare == 'j'
        @p_flow = {@p_flow + 1, FLOW_ROWS.size - 1}.min if @p_pane == 0
        return
      end
      # ↑ / k: REQUEST always climbs out. FLOWS moves the list first, and at the top row also
      # climbs out (same focus-ring as real History).
      if key.up? || bare == 'k'
        if @p_pane == 1 || @p_flow == 0
          step_out
        else
          @p_flow -= 1
        end
        return
      end
      if key.left? || bare == 'h'
        @p_pane = 0 if @p_pane == 1
        return
      end
      if key.right? || bare == 'l'
        @p_pane = 1 if @p_pane == 0
        return
      end
    end

    # One level up, as ↑ and esc climb in the app: body → the tab's strip (when it has one) →
    # the tab bar. Reaching the bar from below is the Navigate lesson's last move.
    private def step_out : Nil
      if @p_level == :body && Tutorial.strip_labels(@p_tab)
        @p_level = :strip
      else
        @p_level = :menu
        @p_up = true
        mark_nav_tried
      end
    end

    # …and one level down: a tab with a strip stops on it first (Runner#enter_content).
    private def step_in : Nil
      if @p_level == :menu && Tutorial.strip_labels(@p_tab)
        @p_level = :strip
      else
        @p_level = :body
        @p_pane = 0
        @p_enter = true
        mark_nav_tried
      end
    end

    private def practice_menu_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      bare = Tutorial.bare_char(ev)
      if key.left? || bare == 'h'
        switch_tab(-1)
      elsif key.right? || bare == 'l'
        switch_tab(1)
      elsif key.down? || key.enter? || bare == 'j'
        step_in
      end
    end

    # The strip owns ←/→ (its chips) and ↓/↑ (in and out), as Runner#handle_subtabs_key does.
    private def strip_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      bare = Tutorial.bare_char(ev)
      n = Tutorial.strip_labels(@p_tab).try(&.size) || 1
      if key.left? || bare == 'h'
        @p_sub = {@p_sub - 1, 0}.max
      elsif key.right? || bare == 'l'
        @p_sub = {@p_sub + 1, n - 1}.min
      elsif key.down? || key.enter? || bare == 'j'
        step_in
      elsif key.up? || bare == 'k'
        step_out
      end
    end

    private def switch_tab(delta : Int32) : Nil
      @p_tab = (@p_tab + delta) % TABS.size
      @p_sub = 0
      mark_switch
    end

    private def mark_switch : Nil
      @p_switch = true
      mark_nav_tried
    end

    # The Navigate lesson's ✓ (and Miss Ring's :nav line): all three moves its try line asks
    # for — switch a tab, reach the body, climb back to the bar — not the first of them
    # (#1382). Gated to the lesson: the shared shell code that sets the three flags runs on
    # Practice too, which keeps its own goals, and an Edit-lesson click is not a nav move.
    private def mark_nav_tried : Nil
      @tried_nav = true if @step.navigate? && @p_switch && @p_enter && @p_up
    end

    # The Edit lesson's ✓: the whole of "press i, type a username, esc back to READ" — leaving
    # INS having typed something (#1382). Entering INS alone used to pass it.
    private def mark_edit_tried : Nil
      @tried_edit = true if (@step.edit? || @step.practice?) && !@edit_typed.empty?
    end

    # The three doors into the mock's INS mode — the Edit lesson's `i`/↵, the shared shell's
    # `i`/↵ on the REQUEST pane, and a click on the Edit lesson's NOR/INS chip — spelled the
    # same three lines each. One home, so they cannot disagree about the field.
    private def enter_insert : Nil
      @edit_insert = true
      @edit_typed = ""
    end

    # …and one home for the way out, which `esc` and the chip take.
    private def exit_insert : Nil
      @edit_insert = false
      mark_edit_tried
    end

    # Show `msg` in the footer's hint row for ~3s (the loop polls at 50ms).
    private def nudge(msg : String) : Nil
      @nudge = msg
      @nudge_until = @tick + 60
    end

    private def live_nudge : String?
      (n = @nudge) && @tick < @nudge_until ? n : nil
    end

    private def reach(id : String) : String
      Tutorial.reach(@registry, id)
    end

    # Whether `ev` is `id`'s effective chord — bare letters only, which is all the traffic
    # lessons bind (c, i, f, d) — so a rebind moves the mock's key with the app's.
    private def verb_key?(ev : Termisu::Event::Key, id : String) : Bool
      return false unless ch = Tutorial.bare_char(ev)
      return false unless chord = Hotkeys.binding_for(@registry, id)
      !chord.ctrl && !chord.alt && !chord.shift && chord.key == ch.to_s
    end

    # The mock REQUEST card's NOR/INS chip, inverted at `render_request_pane`'s own three
    # numbers — and behind its own `w < 8 || h < 3` bail — so the live cells are exactly the
    # painted ones, and a card too small to draw a badge cannot answer for one.
    private def edit_badge_hit?(mx : Int32, my : Int32) : Bool
      r = @request_rect
      return false if r.w < 8 || r.h < 3
      Frame.mode_badge_hit(mx, my, r.y, r.right - 1, r.x + 10, @edit_insert)
    end

    # The chip is a TOGGLE, the way every real editor's is (`NotesController#handle_click`
    # and its four siblings), rather than a one-way door into INS.
    private def toggle_edit_insert : Nil
      @edit_insert ? exit_insert : enter_insert
    end

    private def handle_edit_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if key.escape?
        exit_insert
        return
      end
      # ↵ does NOT leave INS: in the real editor it types a newline, and a user who learned
      # "↵ → READ" here broke their first request line (#1380). The mock body is one line, so
      # it says so instead of inserting one.
      if key.enter?
        nudge("↵ types a newline in a real editor — esc leaves INS")
        return
      end
      if key.backspace?
        @edit_typed = @edit_typed[0...-1] unless @edit_typed.empty?
        return
      end
      if (ch = Tutorial.typed_char(ev)) && @edit_typed.size < 16
        @edit_typed += ch
      end
    end

    private def handle_overlay_key(ev : Termisu::Event::Key) : Nil
      key = ev.key
      if ev.ctrl_c?
        @running = false
        return
      end
      # esc steps back ONE level, as in the app: out of the second card to the menu, then shut.
      if key.escape?
        @overlay == :space && @space_level == 2 ? space_back : close_overlay
        return
      end
      if key.enter?
        run_overlay_selection
        return
      end

      case @overlay
      when :palette
        # ONE `rows.size` for both arrows. The ↑ arm used to take the modulo BEFORE its
        # empty-list guard — `(@pal_sel - 1) % 0` — so typing a character that matches no
        # PALETTE_ROWS label and then pressing ↑ killed the tour with an unhandled
        # DivisionByZeroError, while the ↓ arm three lines below had always computed `n`
        # first. `render_fake_palette` already paints "(no matches)" and `footer_hint`
        # advertises ↑/↓ in exactly that state, so the empty list was expected everywhere
        # except on that one line. Hoisted rather than re-guarded so the two cannot drift
        # apart again. (Crystal's `%` is floored, so -1 wraps to the last row.)
        n = filtered_palette.size
        # ARROWS ONLY, and everything else types — the rule Runner#handle_palette_key has.
        # j/k used to move the selection here, in a field the lesson's own key line calls
        # "type to fuzzy-filter": two letters the real palette accepts were the two this
        # mock refused, teaching a model gori does not have. (The space menu below is the
        # surface that DOES fall back to j/k, and it keeps it.)
        if key.up?
          @pal_sel = Tutorial.wrap_sel(@pal_sel, -1, n)
        elsif key.down?
          @pal_sel = Tutorial.wrap_sel(@pal_sel, +1, n)
        elsif key.backspace?
          @pal_query = @pal_query[0...-1] unless @pal_query.empty?
          @pal_sel = 0
        elsif (ch = Tutorial.typed_char(ev)) && @pal_query.size < 20
          @pal_query += ch
          @pal_sel = 0
        end
      when :space
        # Mnemonic FIRST, then the j/k fallback — the helix-leader order
        # Runner#handle_space_menu_key spells out. No menu row is lettered h/j/k/l
        # (`Family::NAV_LETTERS`, checked at boot), so the fallback can never shadow a row.
        rows = space_level_rows
        bare = Tutorial.bare_char(ev)
        if bare && (row = rows.find { |r| r.key == bare })
          run_space_row(row)
        elsif key.backspace? && @space_level == 2
          space_back # the app's other way back a level
        elsif key.up? || bare == 'k'
          @space_sel = Tutorial.wrap_sel(@space_sel, -1, rows.size)
        elsif key.down? || bare == 'j'
          @space_sel = Tutorial.wrap_sel(@space_sel, +1, rows.size)
        end
      end
    end

    private def filtered_palette : Array(PalRow)
      Tutorial.palette_matches(@pal_query, @pal_tab_rows)
    end

    private def run_overlay_selection : Nil
      if @overlay == :space
        if row = space_level_rows[@space_sel]?
          run_space_row(row)
        else
          close_overlay
        end
        return
      end
      if @overlay == :palette
        rows = filtered_palette
        if row = rows[@pal_sel]?
          # The palette lesson's ✓ is its whole try line — a search that turned up this tab's
          # own actions, then ↵ — not the first character typed (#1382).
          @tried_palette = true if @step.palette? && rows.any?(&.this_tab)
          # Mirror a couple of real "Go to …" actions so the palette feels alive.
          if tab = row.tab
            @p_tab = tab
            mark_switch
          end
        end
      end
      close_overlay
    end

    # The rows of the card on screen: the menu, or the second card its family row opened.
    private def space_level_rows : Array(MenuRow)
      @space_level == 2 ? @send_rows : @space_rows
    end

    # A row that opens a card opens it; any other row "runs", which in a mock means the menu
    # closes, as the real one does after running a row.
    private def run_space_row(row : MenuRow) : Nil
      if row.opens
        open_send_card
      else
        @tried_space = true if @step.space_menu?
        close_overlay
      end
    end

    private def practice_done? : Bool
      @p_switch && @p_enter && @p_up && @p_palette && @p_space && @p_edit
    end

    # Practice's goals and every lesson's live mock start from the same clean slate; the two
    # differ only in where the mock stands.
    private def reset_practice : Nil
      reset_mock
      @p_tab = 0
    end

    private def reset_lesson_try : Nil
      reset_mock
      @p_tab = @step.space_menu? || @step.palette? ? HISTORY_TAB : 0
    end

    private def reset_mock : Nil
      @p_level = :menu
      @p_pane = 0
      @p_flow = 0
      @p_sub = 0
      @p_switch = false
      @p_enter = false
      @p_up = false
      @p_palette = false
      @p_space = false
      @p_edit = false
      @overlay = :none
      @pal_sel = 0
      @pal_query = ""
      @space_sel = 0
      @space_level = 1
      @edit_insert = false
      @edit_typed = ""
      @nav_live = false
      @nudge = nil
      @m_capture = true
      @m_cap_off = false
      @m_intercept = false
      @m_held = 0
      @m_held_on = false
      @m_released = false
    end

    private def start_nav_live : Nil
      return if @nav_live
      @nav_live = true
      @p_level = :menu
      @p_tab = 0
      @p_pane = 0
      @p_flow = 0
      @p_sub = 0
    end

    # --- traffic lessons -------------------------------------------------------

    # The Capture lesson's switch. Its ✓ is the try line's whole ask: off, then back on — a
    # user who leaves the lesson with capture off has learned the wrong half.
    private def toggle_mock_capture : Nil
      @m_capture = !@m_capture
      if !@m_capture
        @m_cap_off = true
      elsif @m_cap_off
        @tried_capture = true
      end
    end

    # The Intercept lesson's keys: its mock stands on the Intercept tab, where the app answers
    # `i` with Global intercept, `f`/`d` with the queue, and `c` with Catch direction — NOT
    # capture, which is the one surprise on that tab worth saying out loud. True when the key
    # was the lesson's.
    private def handle_intercept_key(ev : Termisu::Event::Key) : Bool
      if verb_key?(ev, "intercept.toggle")
        toggle_mock_intercept
      elsif verb_key?(ev, "intercept.forward") || verb_key?(ev, "intercept.drop")
        if @m_held > 0
          @m_held -= 1
          @m_released = true
        else
          nudge("nothing is held — #{reach("intercept.toggle")} starts holding")
        end
      elsif verb_key?(ev, "intercept.direction")
        nudge("on Intercept, #{reach("intercept.direction")} picks what to hold — not capture")
      else
        return false
      end
      @tried_intercept = true if @m_held_on && @m_released && !@m_intercept
      true
    end

    # Turning intercept on queues the mock browser's next requests; turning it off sends every
    # one still held, as the app does (Interceptor#toggle), and says so.
    private def toggle_mock_intercept : Nil
      @m_intercept = !@m_intercept
      if @m_intercept
        @m_held_on = true
        @m_held = 2
      elsif @m_held > 0
        nudge("intercept off — the #{@m_held} still held went out unedited")
        @m_held = 0
      end
    end

    private def open_palette : Nil
      @overlay = :palette
      @pal_sel = 0
      @pal_query = ""
      @edit_insert = false
    end

    private def open_space : Nil
      @overlay = :space
      @space_level = 1
      @space_sel = 0
      @edit_insert = false
    end

    # The Send flow to… card — from its menu row, or straight from the pane on the bare family
    # key. Reaching it is the space lesson's try-it: a second level is the one thing about the
    # menu a user cannot guess from the first.
    private def open_send_card : Nil
      @overlay = :space
      @space_level = 2
      @space_sel = 0
      @edit_insert = false
      @tried_space = true if @step.space_menu?
    end

    # Back from the card to the menu, on the row that opened it.
    private def space_back : Nil
      @space_level = 1
      @space_sel = @space_rows.index(&.opens) || 0
    end

    private def close_overlay : Nil
      @overlay = :none
      @space_level = 1
      @pal_query = ""
    end

    # The three below read a BARE character (Tutorial.bare_char), never the letter a chord
    # carries — ⌥I is not "press i", and ^Space is not the action menu.
    private def nav_switch_key?(ev : Termisu::Event::Key) : Bool
      key = ev.key
      return true if key.left? || key.right?
      ch = Tutorial.bare_char(ev)
      ch == 'h' || ch == 'l'
    end

    # The tab a digit reaches, or nil — both for a bare `Char` and for a whole event, since
    # the Navigate lesson has to recognise one BEFORE it hands the shell its first key (a
    # digit is how the lesson now asks the user to move, so it has to be one of the presses
    # that takes the demo live — see `handle_key`).
    private def digit_tab(ch : Char) : Int32?
      return nil unless '1' <= ch <= '9'
      idx = ch.ord - '1'.ord
      # The chips the strip actually PAINTED this frame, not TABS.size: a narrow card — Miss
      # Ring's band at 80 columns, or a small terminal — packs fewer chips than the mock has,
      # and a digit past the last one would move a highlight nobody can see while ticking the
      # lesson's try-it on the way past. @tab_hits is rebuilt every frame by `render_tab_bar`,
      # and empty on the lessons that draw no bar at all.
      @tab_hits.any? { |(_, i)| i == idx } ? idx : nil
    end

    private def digit_tab_key?(ev : Termisu::Event::Key) : Bool
      return false unless ch = Tutorial.bare_char(ev)
      !digit_tab(ch).nil?
    end

    private def palette_open_key?(ev : Termisu::Event::Key) : Bool
      ev.ctrl? && ev.key.lower_p?
    end

    private def space_open_key?(ev : Termisu::Event::Key) : Bool
      Tutorial.bare_char(ev) == ' '
    end

    # The Send flow to… family's own key (`Family#key`, the same as its chord), read from the
    # family rather than spelled here.
    private def send_open_key?(ev : Termisu::Event::Key) : Bool
      Tutorial.bare_char(ev) == Verbs::SEND_FLOW.key
    end

    private def edit_enter_key?(ev : Termisu::Event::Key) : Bool
      ch = Tutorial.bare_char(ev)
      ch == 'i' || ch == 'I'
    end

    private def handle_mouse(ev : Termisu::Event::Mouse) : Nil
      return unless ev.press? && !ev.wheel?
      @esc_armed = false          # a click is intent to stay (see #handle_escape)
      mx, my = ev.x - 1, ev.y - 1 # termisu mouse coords are 1-based

      # Footer buttons always win (never stuck — Skip/Next/Finish/Prev).
      if @next_btn.contains?(mx, my)
        advance
        return
      end
      if @prev_btn.contains?(mx, my) && prev_enabled?
        back
        return
      end

      # Progress rail: click any step chip to jump there (tour navigation).
      @rail_hits.each do |(rect, step_val)|
        if rect.contains?(mx, my)
          jump_to(Step.new(step_val))
          return
        end
      end

      # Overlay click: inside keeps focus; outside dismisses (real popup UX).
      unless @overlay == :none
        rect = @overlay == :palette ? @palette_rect : @space_rect
        if rect.contains?(mx, my)
          handle_overlay_click(mx, my)
        else
          close_overlay
        end
        return
      end

      # Mock shell clicks (Navigate live + Practice + lesson demos with shell).
      return unless shell_clickable?
      handle_shell_click(mx, my)
    end

    private def shell_clickable? : Bool
      @step.practice? || @step.navigate? || @step.palette? || @step.space_menu? || @step.edit?
    end

    private def handle_overlay_click(mx : Int32, my : Int32) : Nil
      case @overlay
      when :palette
        # Click a row → select + run (same as ↵). Bounded by the rows actually PAINTED and
        # offset by the same scroll window `render_fake_palette` used, not by `rows.size`:
        # the two disagreed, so a click on the overlay's bottom border ran a command the user
        # could not see.
        # A group header is not a command: a click on one does nothing.
        display, top, vis = palette_window(@palette_rect, filtered_palette, @pal_sel)
        row = my - (@palette_rect.y + 3)
        if row >= 0 && row < {vis, display.size - top}.min && (idx = display[top + row][1])
          @pal_sel = idx
          run_overlay_selection
        end
      when :space
        rows = space_level_rows
        vis = {@space_rect.h - 2, 0}.max
        top = Tutorial.palette_scroll(@space_sel, rows.size, vis)
        row = my - (@space_rect.y + 1)
        if row >= 0 && row < {vis, rows.size - top}.min
          @space_sel = top + row
          run_space_row(rows[@space_sel])
        end
      end
    end

    private def handle_shell_click(mx : Int32, my : Int32) : Nil
      # Ensure live takeover when interacting with the Navigate demo.
      start_nav_live if @step.navigate?

      # The Edit lesson draws ONLY the REQUEST pane, and its whole ask is "press i". A click
      # on it used to fall through to the body-focus branch below — which `render_edit`
      # ignores entirely, since it always draws that pane focused and reads @edit_insert for
      # the mode — so the pointer did nothing at all, while still ticking the NAVIGATE
      # lesson's try-it on the way past.
      #
      # What the pointer means here is what it means in the app it is teaching (#1124): a
      # press on the card's NOR/INS chip toggles the mode, and a press anywhere else places a
      # caret and changes no mode. This card has no caret to place, so the body is inert —
      # which is the honest mock of "a click does not open the editor". The chip that used to
      # be painted and dead is the live cell instead, and the lesson's ask is still `i`.
      if @step.edit?
        toggle_edit_insert if edit_badge_hit?(mx, my)
        return
      end

      @tab_hits.each do |(rect, idx)|
        if rect.contains?(mx, my)
          @p_tab = idx
          @p_sub = 0
          @p_level = :menu # clicking a tab focuses the bar (real app)
          mark_switch
          return
        end
      end

      # Pane clicks only where the mock RENDERS focus: Navigate (made live just above) and
      # Practice. The Palette and SpaceMenu lessons hand `render_shell` a fixed focus so
      # their panes have nothing to move — moving @p_level/@p_pane there changed nothing on
      # screen, and the @p_flow it also moved left the REQUEST pane showing a flow the FLOWS
      # pane was not marking as selected.
      return unless live_shell?

      if @strip_rect.contains?(mx, my)
        @p_level = :strip
        return
      end

      if @flows_rect.contains?(mx, my)
        @p_level = :body
        @p_pane = 0
        @p_enter = true
        mark_nav_tried
        # Row hit: interior starts at y+1.
        row = my - (@flows_rect.y + 1)
        @p_flow = row.clamp(0, FLOW_ROWS.size - 1) if row >= 0
        return
      end

      if @request_rect.contains?(mx, my)
        @p_level = :body
        @p_pane = 1
        @p_enter = true
        mark_nav_tried
        return
      end
    end

    private def prev_enabled? : Bool
      !@step.welcome?
    end

    private def advance : Nil
      if @step.done?
        @finished = true
        @running = false
      else
        jump_to(Step.new(@step.value + 1))
      end
    end

    private def back : Nil
      return if @step.welcome?
      jump_to(Step.new(@step.value - 1))
    end

    # Jump to an arbitrary lesson (progress-rail click or sequential next/prev).
    private def jump_to(step : Step) : Nil
      return if step == @step
      @practice_completed ||= @step.practice? && practice_done?
      @step = step
      @visited << step
      @tick = 0
      if @step.practice?
        reset_practice
      else
        reset_lesson_try
      end
    end

    # --- rendering -----------------------------------------------------------

    private def render : Nil
      screen = Screen.new(@backend)
      w, h = screen.width, screen.height
      screen.fill(Rect.new(0, 0, w, h), Theme.bg)

      # Clear hit targets each frame (rebuilt by render helpers).
      @prev_btn = Rect.new(0, 0, 0, 0)
      @next_btn = Rect.new(0, 0, 0, 0)
      @shell_rect = Rect.new(0, 0, 0, 0)
      @tab_hits = [] of {Rect, Int32}
      @rail_hits = [] of {Rect, Int32}
      @flows_rect = Rect.new(0, 0, 0, 0)
      @request_rect = Rect.new(0, 0, 0, 0)
      @strip_rect = Rect.new(0, 0, 0, 0)
      @palette_rect = Rect.new(0, 0, 0, 0)
      @space_rect = Rect.new(0, 0, 0, 0)

      # Derived ONCE and reused below. step_card now runs the whole placement decision
      # (companion_band → companion_place → Companion.place, plus a nested step_card), and this loop repaints
      # on every 50ms poll — calling it for the guard and again for the card doubled that
      # work ~20x/second to answer a question whose inputs had not changed.
      box = step_card(w, h)
      if too_small?(w, h)
        screen.text(0, 0, Tutorial.too_small_message(w), Theme.red, width: w)
        @term.hide_cursor
        flush
        return
      end

      render_header(screen, w)
      render_progress_rail(screen, w)
      Frame.card(screen, box, Hotkeys.retag(card_title), border: Theme.border_focus)
      case @step
      when Step::Welcome   then render_welcome(screen, box)
      when Step::Navigate  then render_navigate(screen, box)
      when Step::SpaceMenu then render_spacemenu(screen, box)
      when Step::Palette   then render_palette(screen, box)
      when Step::Edit      then render_edit(screen, box)
      when Step::Capture   then render_capture(screen, box)
      when Step::Intercept then render_intercept(screen, box)
      when Step::Practice  then render_practice(screen, box)
      when Step::Leave     then render_leave(screen, box)
      when Step::Done      then render_done(screen, box)
      end
      render_footer(screen, w, h)
      render_companion(screen, w, h)

      @term.hide_cursor
      flush
    end

    # She paints LAST — anything she is allowed to occupy she occupies opaquely, so drawing
    # her earlier would let a mock's pane border cut through her. step_card has already held
    # her band back, so the sprite lands on bare background, and her bubble never reaches the
    # card (#companion_draw_stage): it used to float over it, and covered the palette lesson's
    # `␣ > c` hint — the point of that lesson — and the Welcome card's tour-nav line (#1381).
    private def render_companion(screen : Screen, w : Int32, h : Int32) : Nil
      return unless Settings.companion?
      # companion_draw_stage, NOT companion_stage: the bare stage seats her at every size
      # Companion.place accepts, including the ones companion_place stands her down at.
      return unless seat = Tutorial.companion_draw_stage(w, h)
      return unless frame = @companion.frame
      stage, speaks = seat
      Companion.draw(screen, stage, speaks ? frame : frame.copy_with(bubble: nil))
    end

    private def flush : Nil
      @backend.flush(sync: @resized)
      @resized = false
    end

    # Whether `render` will paint the resize-and-retry line instead of the tour.
    #
    # Shared with `handle_escape`, which must not arm its leave-the-tour confirmation on that
    # screen: `footer_hint` is what announces the armed state and this path returns before
    # `render_footer`, so a first esc there would change nothing a user could see while the
    # red line goes on advertising "esc to leave". Nothing on that screen is a lesson worth
    # protecting from an accidental press, so esc simply leaves.
    private def too_small?(w : Int32, h : Int32) : Bool
      !(Layout.usable?(w, h) && Tutorial.step_card(w, h, companion_band(w, h)).h >= MIN_CARD_H)
    end

    private def too_small? : Bool
      w, h = @backend.size
      too_small?(w, h)
    end

    # Card sits between the 2-row header and the 2-row footer, centred in whatever width
    # Miss Ring's stand leaves it (COMPANION_BAND, or the full width while she is off).
    private def step_card(w : Int32, h : Int32) : Rect
      Tutorial.step_card(w, h, companion_band(w, h))
    end

    # The placement rules themselves, free of Settings and of any Tutorial instance so a
    # spec can sweep them over terminal sizes — the one thing about her here that geometry
    # can get wrong. `band` is threaded through rather than read from Settings for the same
    # reason: the card's width and her stand are two halves of one decision, and a spec has
    # to be able to check they agree.
    def self.step_card(w : Int32, h : Int32, band : Int32 = 0) : Rect
      avail_w = {w - band, 40}.max
      cw = { {avail_w - 4, CARD_W}.min, 40 }.max
      avail = {h - HEADER_ROWS - FOOTER_ROWS, 3}.max
      ch = {CONTENT_ROWS + 3, avail}.min
      cx = {(avail_w - cw) // 2, 0}.max
      cy = HEADER_ROWS + {(avail - ch) // 2, 0}.max
      Rect.new(cx, cy, cw, ch)
    end

    # Her stage is the canvas down to the row above the footer, so Companion.place's own
    # BOTTOM_MARGIN keeps her plate clear of both footer rows with a row to spare.
    def self.companion_stage(w : Int32, h : Int32) : Rect
      Rect.new(0, 0, w, h - FOOTER_ROWS)
    end

    # Move a wrapping selection by `delta` over `n` rows, and 0 when there are none.
    #
    # A class method rather than two inline expressions because the two arrows had already
    # drifted: ↑ took `(@pal_sel - 1) % filtered_palette.size` BEFORE its empty-list guard, so
    # filtering the tour's fake palette down to no matches and pressing ↑ (or `k`) killed the
    # process with an unhandled DivisionByZeroError — on the first-run path that is after
    # `SetupWizard#finish` has written settings.json, so the tour never auto-launched again.
    # ↓ three lines below had always computed the size first. `render_fake_palette` clamps for
    # an empty list and paints "(no matches)", and `footer_hint` advertises ↑/↓ in exactly that
    # state, so the empty list was expected everywhere but that one line. One home, spec-able
    # without a tty. (Crystal's `%` is floored, so -1 wraps to the last row.)
    def self.wrap_sel(sel : Int32, delta : Int32, n : Int32) : Int32
      return 0 if n <= 0
      (sel + delta) % n
    end

    # Rows `render_fake_palette` can actually paint in `rect`: its interior between the query
    # divider (rect.y + 2) and the bottom border.
    #
    # ONE home for the draw loop, the scroll window and the click hit-test, which had drifted
    # apart. `draw_palette_overlay` capped the overlay at 8 rows — four short of what five
    # PALETTE_ROWS need — and there was no scrolling, so "Open Help" could not be drawn at any
    # terminal size while ↑/↓ still selected it: the ▎ marker simply vanished off the bottom
    # and ↵ ran a command that had never been on screen. The click path was worse, bounding
    # the row by `rows.size` instead of by what was painted, so a click on the card's own
    # bottom border ran an undrawn row. In the one lesson whose subject is "↑/↓ move · ↵ run".
    def self.palette_rows_visible(rect : Rect) : Int32
      {rect.h - 4, 0}.max
    end

    # First row of the scroll window that keeps `sel` on screen.
    #
    # Stateless, so the selection rides the window's BOTTOM edge once the list is scrolled at
    # all: moving up one row scrolls the list up with it rather than leaving it parked. A
    # sticky window (keep the previous top unless `sel` would fall outside it) would move less,
    # but it needs the previous top carried across frames, and this is a five-row fake palette
    # in a tutorial — the thing worth guaranteeing here is that draw, click and ↑/↓ agree on
    # one window, which they can only do if any of them can recompute it.
    def self.palette_scroll(sel : Int32, n : Int32, visible : Int32) : Int32
      return 0 if visible <= 0 || n <= visible
      { {sel - visible + 1, 0}.max, n - visible }.min
    end

    # Her stand, or nil when the terminal cannot seat her BESIDE A FULL-WIDTH CARD: she stands
    # down wherever her band would narrow it below CARD_W (~94 columns), and #companion_band
    # then returns 0 so the card takes the full width it would have had if she were off.
    def self.companion_place(w : Int32, h : Int32) : Rect?
      return nil unless rect = Companion.place(companion_stage(w, h))
      # COMPANION_BAND, not #companion_band: the card measured here is the one she would get if
      # she stands, which is exactly what this decides. She never costs it its width (#1381).
      card = step_card(w, h, COMPANION_BAND)
      return nil if card.w < CARD_W
      # Her plate claims a column left of the sprite (Companion.draw), so that — not rect.x — is
      # the edge the card has to clear.
      return nil if rect.x - 1 < card.right
      rect
    end

    # Columns to hold back from the card. Not circular with step_card: companion_place measures
    # against a card sized by the CONSTANT band, never by this.
    def self.companion_band(w : Int32, h : Int32) : Int32
      companion_place(w, h) ? COMPANION_BAND : 0
    end

    # The stage to hand Companion.draw and whether she may speak on it, or nil when she must
    # not be drawn at all.
    #
    # ONE function, so the render path cannot drift from the placement rule. Companion.draw
    # re-derives Companion.place from whatever rect it is handed and knows nothing about the
    # card, so handing it the bare stage seats her at every size Companion.place accepts —
    # including the ones companion_place deliberately rejects. Routing the render through
    # this makes "may she be drawn" and "where does she stand" the same answer, and gives the
    # spec something it can assert without a Screen.
    #
    # Her BUBBLE may not reach the card either (#1381). Companion.bubble_box keeps it inside
    # the stage, so when the columns right of the card can hold a stage (Companion::MIN_W) she
    # gets exactly those, and speaks there; the sprite's seat is the same, since
    # Companion.place measures from the stage's right and bottom edges. Narrower than that she
    # stands silent — a reaction is encouragement, never the lesson.
    def self.companion_draw_stage(w : Int32, h : Int32) : {Rect, Bool}?
      return nil unless companion_place(w, h)
      full = companion_stage(w, h)
      right = step_card(w, h, COMPANION_BAND).right
      return {full, false} if w - right < Companion::MIN_W
      {Rect.new(right, full.y, w - right, full.h), true}
    end

    # …and the live gate. While she is off, or stands down, the card takes the full width.
    private def companion_band(w : Int32, h : Int32) : Int32
      Settings.companion? ? Tutorial.companion_band(w, h) : 0
    end

    private def render_header(screen : Screen, w : Int32) : Nil
      x = screen.text(2, 0, "gori", Theme.text_bright, Theme.bg, attr: Attribute::Bold)
      screen.text(x + 1, 0, "· tutorial", Theme.muted, Theme.bg)
      prog = "#{@step.value + 1}/#{Step.values.size}"
      screen.text({w - prog.size - 2, 0}.max, 0, prog, Theme.muted, Theme.bg)
    end

    # Cells the labelled rail takes: each chip is ` ● label`, with one trailing cell so the
    # current chip's highlight can close on a space. No connectors between chips — ten of
    # them fit at 80 columns this way, and the connectors were what did not.
    def self.rail_width : Int32
      STEP_RAIL.sum { |(lab, _)| lab.size + 3 } + 1
    end

    # Visual "where am I" rail under the brand line. Each chip is clickable (jump_to) so the
    # tour itself can be browsed without finishing every try-it. ✓ means COMPLETED, not
    # passed: a lesson whose try-it was skipped reads ◐ (visited), so pressing n ten times no
    # longer paints a rail of ticks (#1382).
    private def render_progress_rail(screen : Screen, w : Int32) : Nil
      y = 1
      @rail_hits = [] of {Rect, Int32}
      labelled_w = Tutorial.rail_width
      if labelled_w + 4 <= w
        cx = {(w - labelled_w) // 2, 2}.max
        here_at = nil
        STEP_RAIL.each do |(lab, st)|
          chip = " #{rail_mark(st)} #{lab}"
          @rail_hits << {Rect.new(cx, y, chip.size, 1), st.value}
          if st == @step
            here_at = {cx, "#{chip} "}
          else
            screen.text(cx, y, chip, rail_color(st), Theme.bg)
          end
          cx += chip.size
        end
        # The current chip last, one cell wider, so its highlight is not cut by its neighbour.
        if at = here_at
          hx, chip = at
          screen.fill(Rect.new(hx, y, chip.size, 1), Theme.accent_bg)
          screen.text(hx, y, chip, Theme.text_bright, Theme.accent_bg, attr: Attribute::Bold)
        end
      else
        # Compact dots, each cell still a jump target: ● here, green ● completed, ◐ visited.
        unit = 2
        total_w = Step.values.size * unit - 1
        cx = {(w - total_w) // 2, 2}.max
        Step.values.each do |st|
          ch = st == @step || step_completed?(st) ? '●' : rail_mark(st)[0]
          @rail_hits << {Rect.new(cx, y, unit, 1), st.value}
          screen.cell(cx, y, ch, rail_color(st), Theme.bg)
          cx += unit
        end
      end
    end

    private def rail_mark(st : Step) : String
      return "●" if st == @step
      return "✓" if step_completed?(st)
      @visited.includes?(st) ? "◐" : "○"
    end

    private def rail_color(st : Step) : Color
      return Theme.accent if st == @step
      step_completed?(st) ? Theme.green : Theme.muted
    end

    # A lesson is completed by its try-it, not by being passed. The prose steps (Welcome,
    # Leave, Done) have none, so reading them is the step.
    private def step_completed?(st : Step) : Bool
      case st
      when Step::Navigate  then @tried_nav
      when Step::SpaceMenu then @tried_space
      when Step::Palette   then @tried_palette
      when Step::Edit      then @tried_edit
      when Step::Capture   then @tried_capture
      when Step::Intercept then @tried_intercept
      when Step::Practice  then @practice_completed || (@step.practice? && practice_done?)
      else                      @visited.includes?(st)
      end
    end

    private def card_title : String
      case @step
      when Step::Welcome   then "WELCOME"
      when Step::Navigate  then "MOVE AROUND · 1-9, tabs & panes"
      when Step::Palette   then "COMMAND PALETTE · ^P"
      when Step::SpaceMenu then "ACTION MENU · space"
      when Step::Edit      then "EDIT MODE · READ / INS"
      when Step::Capture   then "CONNECT & CAPTURE · proxy, CA, #{reach("capture.toggle")}"
      when Step::Intercept then "INTERCEPT · #{reach("intercept.toggle")} hold, #{reach("intercept.forward")} forward"
      when Step::Practice  then "TRY IT · four moves, six checks"
      when Step::Leave     then "HELP & LEAVING · #{reach("tab.help")} · ^D"
      else                      "YOU'RE READY"
      end
    end

    private def next_btn_label : String
      case @step
      when Step::Welcome then " Start "
      when Step::Done    then " Finish "
      when Step::Practice
        practice_done? ? " Next " : " Skip "
      else " Next "
      end
    end

    private def prev_btn_label : String
      " Prev "
    end

    private def render_footer(screen : Screen, w : Int32, h : Int32) : Nil
      hint = footer_hint
      hint = Tutorial.compact_footer_hint(@step, @overlay, @edit_insert, @esc_armed, @registry) if Screen.draw_width(hint) > w
      hy = h - 2
      screen.text({(w - Screen.draw_width(hint)) // 2, 0}.max, hy, hint, Theme.muted, Theme.bg)

      by = h - 1
      prev_l = prev_btn_label
      next_l = next_btn_label
      # " ← Prev " / " Next → " with arrow affordances
      prev_text = " ←#{prev_l}"
      next_text = "#{next_l}→ "
      pad = 2
      @prev_btn = Rect.new(pad, by, prev_text.size, 1)
      @next_btn = Rect.new({w - pad - next_text.size, 0}.max, by, next_text.size, 1)

      if prev_enabled?
        draw_btn(screen, @prev_btn, prev_text, primary: false)
      else
        screen.text(@prev_btn.x, by, prev_text, Theme.muted, Theme.bg)
      end
      draw_btn(screen, @next_btn, next_text, primary: true)
    end

    private def draw_btn(screen : Screen, rect : Rect, text : String, *, primary : Bool) : Nil
      if primary
        screen.fill(rect, Theme.accent_bg)
        screen.text(rect.x, rect.y, text, Theme.text_bright, Theme.accent_bg, attr: Attribute::Bold)
      else
        screen.fill(rect, Theme.elevated)
        screen.text(rect.x, rect.y, text, Theme.text, Theme.elevated)
      end
    end

    # Contextual mock hint; tour nav (n/b · Prev/Next · rail click) is separate.
    private def footer_hint : String
      tour = "n next · b back"
      # The armed esc outranks every lesson's hint: it is the only state in the tour where
      # the next keystroke can end it, and it lasts exactly until the next key or click.
      # The three hints that name the exit spell it "esc esc" for the same reason — a footer
      # promising what one press does when it takes two is the defect this whole change is
      # about, just pointed the other way.
      return "esc again to leave the tour · any other key stays" if @esc_armed
      if n = live_nudge
        return n
      end
      case @step
      when Step::Welcome
        "↵/n start · click Start · esc esc leave"
      when Step::Done
        "↵/n finish · click Finish · esc esc leave"
      when Step::Practice
        if @overlay != :none
          # NOT `tour`: `tour_nav_key?` hands n/b to an open overlay (the palette types
          # them, the space menu ignores them), so printing "n next · b back" here named two
          # keys that do nothing — the same defect as the esc note above, pointed the other
          # way. The Palette lesson's own overlay hint already used the "then" form; these
          # two were the branches that didn't.
          "↑/↓ · ↵ run · esc close · then n/Next"
        elsif @edit_insert
          "type · esc → READ · then n/Next"
        elsif practice_done?
          "✓ done — ↵/n/Next · or keep exploring"
        else
          "roam the mock · #{tour} / Skip anytime"
        end
      when Step::Navigate
        if @edit_insert
          # Reachable here, not just on Edit/Practice — see the note in `render_navigate`.
          "type · esc → READ · then n/Next"
        elsif @tried_nav
          "✓ #{tour} · or keep exploring"
        elsif @nav_live
          # The try line's next move, one at a time, so the ✓ that waits for all three is
          # never a mystery (#1382).
          next_move = if !@p_switch
                        "press 2"
                      elsif !@p_enter
                        "↓ until BODY"
                      else
                        "↑ or esc until TABS"
                      end
          "next: #{next_move} · #{tab_span} / ←→ tabs · ⇥ panes · #{tour}"
        else
          "try 2, then ↓ · #{tour} to skip"
        end
      when Step::SpaceMenu
        if @overlay == :space
          # n/b belong to the menu here — see Practice.
          @space_level == 2 ? "letter runs · esc back a level · then n/Next" : "letter runs · › opens a card · esc close · then n/Next"
        elsif @tried_space
          "✓ #{tour}"
        else
          "try space, then #{Verbs::SEND_FLOW.key} · #{tour} to skip"
        end
      when Step::Palette
        if @overlay == :palette
          "type a name · ↑/↓ · ↵ run · esc close"
        elsif @tried_palette
          "✓ #{tour}"
        else
          Hotkeys.retag("try ^P, then type #{PALETTE_DEMO_QUERY} · #{tour} to skip")
        end
      when Step::Edit
        if @edit_insert
          "type · esc → READ · then n/Next"
        elsif @tried_edit
          "✓ #{tour}"
        else
          "try i · #{tour} to skip"
        end
      when Step::Capture
        cap = reach("capture.toggle")
        if @tried_capture
          "✓ #{tour}"
        elsif @m_cap_off
          "capture is off — #{cap} again turns it back on"
        else
          "try #{cap} twice · #{tour} to skip"
        end
      when Step::Intercept
        icpt = reach("intercept.toggle")
        if @tried_intercept
          "✓ #{tour}"
        elsif !@m_intercept && !@m_released
          "try #{icpt} · #{tour} to skip"
        elsif !@m_released
          "#{reach("intercept.forward")} forward · #{reach("intercept.drop")} drop the held request"
        else
          "#{icpt} again stops holding · #{tour}"
        end
      else
        "#{tour} · click Prev/Next · esc esc leave"
      end
    end

    # --- lessons -------------------------------------------------------------

    # Split a lesson's interior between its prose and its mock.
    #
    # THE MOCK IS THE LESSON, so it claims SHELL_ROWS off the bottom first and the prose
    # gives way — the muted key-hint rows restate what `footer_hint` already says, while a
    # lesson whose mock did not draw teaches nothing. The old fixed walk did the opposite,
    # and the card MIN_CARD_H admits is three rows shorter than CONTENT_ROWS asks for: at a
    # 12-row card (an 80x16 terminal — the size the "too small" message NAMES as the
    # minimum) it left the shell 4 rows, one under `render_shell`'s floor, so Navigate and
    # Practice painted an EMPTY card under "roam the mock" and "Try: switch a tab, enter
    # body". At 13 and 14 rows the FLOWS pane showed 1 and 2 of its 3 rows, teaching "↓ list"
    # over a list that could not move.
    #
    # Returns {rows of `detail` the prose may keep, the row the mock starts on}. `fixed` is
    # prose rows the lesson always draws (headline, try line, goal chips); `pad` is rows it
    # keeps BELOW the mock.
    # Class methods, like step_card and wrap_sel, so a spec can sweep them over card heights
    # without a tty — this is geometry, and the way it breaks is silently, at one end of a
    # size range nobody renders by hand.
    def self.lesson_split(box : Rect, fixed : Int32, detail : Int32, pad : Int32 = 0) : {Int32, Int32}
      floor = box.bottom - 1 - pad
      keep = { {floor - SHELL_ROWS - prose_top(box) - fixed, 0}.max, detail }.min
      y = prose_top(box) + fixed + keep
      y += 1 if y + 1 + SHELL_ROWS <= floor # blank spacer, only when the mock keeps its rows
      {keep, y}
    end

    # Blank spacer rows a lesson can still afford, given the `content` rows it always draws.
    #
    # The prose lessons (Welcome / Done) call this for their own spacing — what they overran
    # was the card's bottom border, which their eleventh row painted straight over
    # ("╰─Re-run this tour anytime: gori tutorial──╯" at 80x16). Practice calls it for the
    # status row UNDER its mock, passing `fixed + SHELL_ROWS` as content: same question, since
    # that row is spacing the mock's list rows outrank.
    def self.prose_gaps(box : Rect, content : Int32, want : Int32) : Int32
      { {box.bottom - 1 - prose_top(box) - content, 0}.max, want }.min
    end

    # First interior row a lesson writes on — one blank under the card's top border. ONE home
    # for it: both helpers above measure from here, and they disagreeing is how the card grew
    # a row past its own frame the last time.
    def self.prose_top(box : Rect) : Int32
      box.y + 2
    end

    private def render_welcome(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      moves = [
        "1.  tabs & panes     1-9  ·  ←/→  ·  ↓  ·  esc  ·  ⇥",
        "2.  action menu      space — what you do most, right here",
        Hotkeys.retag("3.  command palette  ^P   — find any action by name"),
        "4.  edit mode        READ / INS — browse, then type",
        "5.  traffic          proxy & CA · capture #{reach("capture.toggle")} · intercept #{reach("intercept.toggle")}",
      ]
      gaps = Tutorial.prose_gaps(box, moves.size + 4, 2)
      screen.text(ix, y, "Welcome to gori — a keyboard-driven HTTP/HTTPS proxy.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      y += 1 if gaps > 0
      screen.text(ix, y, "You'll learn the moves you'll use every session:", Theme.text, Theme.panel, width: iw)
      y += 1
      moves.each do |ln|
        screen.text(ix + 2, y, ln, Theme.text, Theme.panel, width: {iw - 2, 1}.max)
        y += 1
      end
      y += 1 if gaps > 1
      screen.text(ix, y, "Each step demos a move, then lets you try it on a live mock.", Theme.muted, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, "Tour nav: n next · b back · click Prev/Next · click the step rail.", Theme.muted, Theme.panel, width: iw)
    end

    private def render_navigate(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      # Every key named here is one the real app binds the same way (Help → TABS & FOCUS).
      # The LAST line names the SUBTABS level Project and Target (and Repeater, Notes…) put
      # between the bar and the body — the first tab a new user lands on has one, and the
      # try line below passes through Target's. It is last because it is the line a short
      # card drops first, and the mock shows the strip anyway.
      detail = [
        "1-9 jump to a tab · ←/→ walk the bar · #{reach("nav.goto")} lists every tab, slot or not",
        "↓ or ↵ steps in · ↑ or esc steps out · ↓ list · ⇥ panes",
        "Project/Target put a SUBTABS strip between the bar and the body",
      ]
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: detail.size)
      screen.text(ix, y, "Every screen is a tab; most tabs split into panes.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      detail[0, keep].each do |ln|
        screen.text(ix, y, ln, Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      # `2`, and only `2`, because a narrow card packs fewer chips than the mock has and the
      # second is the last one drawn at every size the tour renders at. Target has a strip, so
      # "↓ into the body" is two presses there, which the footer walks through (#1382).
      draw_try_line(screen, ix, y, iw, "Try: press 2, ↓ into the body, then ↑ back up to the tabs.", @tried_nav)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      if @nav_live
        # INS included, because the SHARED shell handler can enter it here: ↵ or i on the
        # REQUEST pane sets @edit_insert on this lesson exactly as it does on Practice, and
        # an invisible INS mode would swallow n and b with nothing on screen to say why.
        render_shell(screen, shell, @p_tab, @p_level, @p_pane, "",
          flow: @p_flow, insert: @edit_insert, typed: @edit_typed, sub: @p_sub)
      else
        active, level, pane, keyhint = NAV_DEMO[(@tick // 12) % NAV_DEMO.size]
        render_shell(screen, shell, active, level, pane, keyhint, flow: 0)
      end
    end

    private def render_spacemenu(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      fam = Verbs::SEND_FLOW
      detail = [
        "a letter runs its row · › opens a second card · esc goes back",
        "the key on the right is the row's shortcut, for next time",
      ]
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: detail.size)
      screen.text(ix, y, "space lists what you do most in the pane you're in.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      detail[0, keep].each do |ln|
        screen.text(ix, y, ln, Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, "Try: space, then #{fam.key} for #{fam.title} — esc steps back.", @tried_space)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      live = @overlay == :space
      demo = live || @tried_space ? nil : space_demo_frame
      # @p_tab, not a hardcoded tab: `render_tab_bar` registers a hit rect for every chip it
      # draws, so a click on one moves @p_tab — this lesson used to ignore it, leaving the
      # chips looking clickable and behaving dead.
      render_shell(screen, shell, @p_tab, :body, 0, demo.try(&.[2]) || "", flow: 0)
      if live
        draw_space_overlay(screen, shell, @space_level, @space_sel, live: true)
      elsif demo
        draw_space_overlay(screen, shell, demo[0], demo[1], live: false)
      end
    end

    # The space lesson's looping demo: {level, selected row, key shown}. It walks down to the
    # family row, opens the card on the family's key, walks the card, and steps back on esc —
    # the whole of what the menu has that a user cannot guess, in about four seconds.
    private def space_demo_frame : {Int32, Int32, String}
      fam = @space_rows.index(&.opens) || 0
      last = {@send_rows.size - 1, 0}.max
      phase = (@tick // 10) % 8
      case phase
      when 0    then {1, 0, "space"}
      when 1, 2 then {1, {phase, fam}.min, ""}
      when 3    then {2, 0, Verbs::SEND_FLOW.key.to_s}
      when 7    then {1, fam, "esc"}
      else           {2, {phase - 3, last}.min, ""}
      end
    end

    private def render_palette(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      detail = [
        "this tab's actions first, each with its key or menu path (␣ means space)",
        "rarely used actions live only here — the menu stays short",
      ]
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: detail.size)
      screen.text(ix, y, Hotkeys.retag("^P finds any action by name — this tab's, then the app's."), Theme.text_bright, Theme.panel, width: iw)
      y += 1
      detail[0, keep].each do |ln|
        screen.text(ix, y, ln, Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, Hotkeys.retag("Try: press ^P, type #{PALETTE_DEMO_QUERY}, then ↵ to run it."), @tried_palette)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      # In the body, on History's list: the THIS TAB rows are History's, and the real palette
      # finds a tab's actions from wherever in it you press ^P.
      render_shell(screen, shell, @p_tab, :body, 0, "", flow: 0)
      # Demo auto-overlay only until the user has tried — after they close it,
      # leave a clean shell so it doesn't look like the palette is still open.
      if @overlay == :palette
        draw_palette_overlay(screen, shell, live: true)
      elsif !@tried_palette
        draw_palette_overlay(screen, shell, live: false)
      end
    end

    private def render_edit(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: 1)
      screen.text(ix, y, "Editors open in READ — navigate, select, copy, open the menu.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      if keep > 0
        # ≤ 74 columns: the 80-column card's interior. The longer form of this line lost its
        # closing "(safe by default)" to the ellipsis at exactly the size most users run.
        screen.text(ix, y, "i or ↵ → INS and type · esc → READ (safe by default)",
          Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, "Try: press i, type a username, esc back to READ.", @tried_edit)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      screen.fill(shell, Theme.bg)

      if @edit_insert || @tried_edit
        insert = @edit_insert
        typed = @edit_typed
      else
        phase = (@tick // 10) % 6
        insert = 1 <= phase <= 4
        typed_full = "alice"
        typed = insert ? typed_full[0, {phase, typed_full.size}.min] : ""
      end

      pw = { {shell.w - 4, 48}.min, 24 }.max
      px = shell.x + {(shell.w - pw) // 2, 0}.max
      pane = Rect.new(px, shell.y, pw, {shell.h - 1, 3}.max)
      @request_rect = pane
      render_request_pane(screen, pane, true, insert: insert, typed: typed, flow: 0)

      kh = insert ? "INS · type · esc → READ" : "READ · i or ↵ → INS"
      screen.text(shell.x + {(shell.w - Screen.draw_width(kh)) // 2, 0}.max, shell.bottom - 1, kh, Theme.muted, Theme.bg)
    end

    # Where to point a client, how HTTPS gets trusted, and the capture switch (#1382). The
    # address is the global default bind; a project can pin its own, which is why the line
    # sends the reader to the header chip for the live one.
    private def render_capture(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      detail = [
        "proxy: #{Tutorial.proxy_addr} — the header's ● chip shows the one in use",
        "HTTPS: #{reach("browser.open")} opens one proxied and trusting the CA",
        "other clients: gori ca (or #{reach("ca.export")}), then trust it",
        "● green = capturing · grey and \"off\" = gori isn't listening",
        "test only what you're authorized to · #{reach("scope.toggle-lens")} shows in-scope flows only",
      ]
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: detail.size)
      screen.text(ix, y, "Point a client's proxy at gori, and trust its CA for HTTPS.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      detail[0, keep].each do |ln|
        screen.text(ix, y, ln, Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      cap = reach("capture.toggle")
      draw_try_line(screen, ix, y, iw, "Try: press #{cap} twice — capture off, then back on.", @tried_capture)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      return if shell.h < 5
      screen.fill(shell, Theme.bg)
      # The session header's right end, as Chrome.listen_chip paints it.
      screen.text(shell.x, shell.y, "gori · demo", Theme.muted, Theme.bg)
      chip = @m_capture ? "● #{Tutorial.proxy_addr}" : "● #{Tutorial.proxy_addr} · off"
      screen.text({shell.right - Screen.draw_width(chip), shell.x}.max, shell.y, chip,
        @m_capture ? Theme.green : Theme.muted, Theme.bg)
      note = @m_capture ? "capturing: each request lands in History" : "off: the listener is closed, so proxied clients can't connect"
      screen.text(shell.x, shell.y + 1, note, @m_capture ? Theme.text : Theme.muted, Theme.bg, width: shell.w)
      render_flows_pane(screen, Rect.new(shell.x, shell.y + 2, shell.w, shell.h - 2), false, 0)
    end

    # Hold, decide, release (#1382) — and the `i` collision the Edit lesson leaves open:
    # outside an editor, `i` is this.
    private def render_intercept(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      icpt, fwd, drop = reach("intercept.toggle"), reach("intercept.forward"), reach("intercept.drop")
      detail = [
        "#{icpt} turns it on from anywhere but an editor, where #{reach("editor.insert")} means INS",
        "held requests wait on the Intercept tab: #{fwd} forward · #{drop} drop",
        "it holds your own browser too — turn it off when you're done",
      ]
      keep, sy = Tutorial.lesson_split(box, fixed: 2, detail: detail.size)
      screen.text(ix, y, "Intercept holds each request until you forward or drop it.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      detail[0, keep].each do |ln|
        screen.text(ix, y, ln, Theme.muted, Theme.panel, width: iw)
        y += 1
      end
      draw_try_line(screen, ix, y, iw, "Try: #{icpt} to hold, #{fwd} to forward one, then #{icpt} to stop.", @tried_intercept)

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - sy, 3}.max)
      return if shell.h < 5
      screen.fill(shell, Theme.bg)
      render_tab_bar(screen, shell.x, shell.y, Tutorial.bar_width(shell.w), 3, false)
      chip = @m_intercept ? "intercept:on(#{@m_held})" : "intercept off"
      screen.text({shell.right - Screen.draw_width(chip), shell.x}.max, shell.y + 1, chip,
        @m_intercept ? Theme.red : Theme.muted, Theme.bg)
      pane = Rect.new(shell.x, shell.y + 2, shell.w, shell.h - 2)
      return if pane.w < 8 || pane.h < 3
      Frame.card(screen, pane, "HELD", border: Frame.pane_border(true))
      yy = pane.y + 1
      if @m_held == 0
        msg = @m_intercept ? "nothing held right now" : "off — requests go straight through"
        screen.text(pane.x + 2, yy, msg, Theme.muted, Theme.panel, width: pane.w - 4)
        return
      end
      @m_held.times do |i|
        break if yy >= pane.bottom - 1
        method, path, _ = FLOW_ROWS[(i + 1) % FLOW_ROWS.size]
        bg = i == 0 ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(pane.x + 1, yy, pane.w - 2, 1), bg)
        screen.cell(pane.x + 1, yy, i == 0 ? '▎' : ' ', Theme.accent, bg)
        screen.text(pane.x + 3, yy, method, Theme.method_color(method.strip), bg)
        screen.text(pane.x + 8, yy, "#{path}  · held", i == 0 ? Theme.text_bright : Theme.text, bg,
          width: {pane.w - 10, 1}.max)
        yy += 1
      end
    end

    # The address to point a client at: the global default bind, with a wildcard bind read as
    # the loopback a local browser actually dials.
    def self.proxy_addr : String
      host = Settings.bind_host
      host = "127.0.0.1" if host.empty? || host == "0.0.0.0" || host == "::"
      host = "[#{host}]" if host.includes?(':')
      "#{host}:#{Settings.bind_port}"
    end

    # "1-N" for the chips this card's mock bar draws — the digits that do something at this
    # size (#1381). The shell every lesson draws is the card less its two-column margins.
    private def tab_span : String
      w, h = @backend.size
      "1-#{Tutorial.chips_drawn(step_card(w, h).w - 4)}"
    end

    def self.chips_drawn(shell_w : Int32) : Int32
      tab_chip_rects(tab_labels, 0, 0, bar_width(shell_w)).size
    end

    private def render_practice(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      # "1-N" is the chips this card's bar actually draws (#1381), and INS names where it
      # works: `i` anywhere but the REQUEST pane is intercept in the app (#1380).
      goals = [
        {"#{tab_span} tab", @p_switch}, {"↓ body", @p_enter}, {"↑/esc tabs", @p_up},
        {"space", @p_space}, {Hotkeys.retag("^P"), @p_palette}, {"⇥ i INS", @p_edit},
      ]
      # Practice carries two rows of prose the other lessons don't — the six goal chips — and
      # at the shortest card that costs the mock a FLOWS row, on the one step whose key line
      # teaches "↓ list". So the chips fold onto one row when they fit there, and the status
      # row under the mock (which restates those same chips, and `footer_hint` under it) is
      # what goes next. Both are spacing around the mock; the mock is the lesson.
      one_row = goals.sum { |(label, _)| label.size + 4 } - 2 <= iw
      fixed = one_row ? 2 : 3
      pad = Tutorial.prose_gaps(box, fixed + SHELL_ROWS, 1)
      _, sy = Tutorial.lesson_split(box, fixed: fixed, detail: 0, pad: pad)

      screen.text(ix, y, "Try six checks · Skip anytime.", Theme.text_bright, Theme.panel, width: iw)
      y += 1

      per_row = one_row ? goals.size : 3
      goals.each_slice(per_row) do |slice|
        gx = ix
        slice.each { |(label, done)| gx = draw_goal(screen, gx, y, label, done) + 2 }
        y += 1
      end

      shell = Rect.new(box.x + 2, sy, box.w - 4, {box.bottom - 1 - pad - sy, 3}.max)
      render_shell(screen, shell, @p_tab, @p_level, @p_pane, "",
        flow: @p_flow, insert: @edit_insert, typed: @edit_typed, sub: @p_sub)

      case @overlay
      when :palette then draw_palette_overlay(screen, shell, live: true)
      when :space   then draw_space_overlay(screen, shell, @space_level, @space_sel, live: true)
      end

      return if pad == 0
      msg = if practice_done?
              "✓ Nicely done — click Next or press ↵."
            elsif @overlay != :none
              "Overlay open — ↵ runs, esc closes, click outside dismisses."
            elsif @edit_insert
              "INS mode — type, then esc back to READ."
            else
              Hotkeys.retag("#{tab_span}/←→ tabs · ↓ in · ↑/esc out · ⇥ panes · space · ^P · i in REQUEST")
            end
      screen.text(ix, box.bottom - 2, msg, practice_done? ? Theme.green : Theme.muted, Theme.panel, width: iw)
    end

    private def draw_try_line(screen : Screen, x : Int32, y : Int32, w : Int32, text : String, done : Bool) : Nil
      col = done ? Theme.green : Theme.accent
      mark = done ? "✓" : "○"
      screen.text(x, y, "#{mark}  #{text}", col, Theme.panel, width: w)
    end

    private def draw_goal(screen : Screen, x : Int32, y : Int32, label : String, done : Bool) : Int32
      col = done ? Theme.green : Theme.muted
      screen.cell(x, y, done ? '✓' : '○', col, Theme.panel)
      screen.text(x + 2, y, label, done ? Theme.text : Theme.muted, Theme.panel)
      x + 2 + label.size
    end

    # Help, quitting and closing a project (#1382): the doors out, and the one key that looks
    # like one and is not (esc).
    private def render_leave(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      rows = [
        {reach("tab.help"), "Help: every key, by where you are"},
        {reach("help.hotkeys"), "the same, as a popup"},
        {"^D / ^C ×2", "quit — the first press only asks"},
        {reach("app.back-key"), "on the tab bar: back to the project picker"},
        {"esc", "one level up; never quits"},
        {reach("help.tour"), "this tour, from inside a session"},
      ]
      gaps = Tutorial.prose_gaps(box, rows.size + 1, 1)
      screen.text(ix, y, "Help is one key away; quitting takes two, so it's never an accident.", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      y += 1 if gaps > 0
      # One key column when the widest key and description fit side by side, else each
      # description follows its own key.
      kw = rows.max_of { |(key, _)| Screen.draw_width(key) }
      aligned = 2 + kw + 2 + rows.max_of { |(_, desc)| Screen.draw_width(desc) } <= iw
      rows.each do |(key, desc)|
        kx = screen.text(ix + 2, y, key, Theme.accent, Theme.panel, width: {iw - 2, 1}.max)
        dx = aligned ? ix + 2 + kw + 2 : kx + 2
        screen.text(dx, y, desc, Theme.text, Theme.panel, width: {ix + iw - dx, 1}.max)
        y += 1
      end
    end

    private def render_done(screen : Screen, box : Rect) : Nil
      ix = box.x + 2
      iw = {box.w - 4, 1}.max
      y = box.y + 2
      # The command palette owns Open browser; Project is a numbered tab, not its
      # entry point. The first line follows where this caller actually returns.
      steps = Tutorial.first_session_steps(@handoff, iw - 3, @registry)
      gaps = Tutorial.prose_gaps(box, steps.size + 3, 2)
      destination = case @handoff
                    when Handoff::Picker  then "project picker"
                    when Handoff::Direct  then "--db project or picker"
                    when Handoff::Shell   then "shell"
                    when Handoff::Session then "current session"
                    else                       raise "unknown tutorial handoff"
                    end
      screen.text(ix, y, "Finish → #{destination}", Theme.text_bright, Theme.panel, width: iw)
      y += 1
      y += 1 if gaps > 0
      steps.each_with_index do |desc, i|
        screen.text(ix, y, "#{i + 1}.", Theme.accent, Theme.panel, width: 3)
        screen.text(ix + 3, y, desc, Theme.text, Theme.panel, width: {iw - 3, 1}.max)
        y += 1
      end
      y += 1 if gaps > 1
      extra = Tutorial.done_extra_lines(iw, @registry)
      screen.text(ix, y, extra[0], Theme.muted, Theme.panel, width: iw)
      y += 1
      screen.text(ix, y, extra[1], Theme.muted, Theme.panel, width: iw)
    end

    # --- mock UI -------------------------------------------------------------

    # `level` is where focus sits — :menu (the tab bar), :strip (the tab's SUBTABS strip) or
    # :body — and the badge names it the way the real one does (Runner's focus badge).
    private def render_shell(screen : Screen, rect : Rect, active : Int32, level : Symbol,
                             pane : Int32, keyhint : String, *, flow : Int32 = 0,
                             insert : Bool = false, typed : String = "", sub : Int32 = 0) : Nil
      return if rect.h < 5
      @shell_rect = rect
      screen.fill(rect, Theme.bg)
      in_body = level == :body
      # The focus badge is painted AFTER the tab bar and would overwrite whatever chip
      # happens to reach its columns, so reserve them first (`bar_width`) — otherwise the
      # last tab that still fits gets sheared mid-word.
      scol = level == :menu ? Theme.accent : Theme.focus_gold
      slabel = " #{Tutorial.focus_badge(level, insert)} "
      sx = rect.right - Screen.draw_width(slabel)
      # ONE condition for both the reservation and the paint. Reserving columns the badge
      # then declines to use (sx <= rect.x, on a shell too narrow to hold it) would spend
      # the whole row on a chip that never appears.
      badge = rect.w > BADGE_W + 1
      render_tab_bar(screen, rect.x, rect.y, Tutorial.bar_width(rect.w), active, level == :menu)
      screen.text(sx, rect.y, slabel, Theme.ink_on(scol), scol, attr: Attribute::Bold) if badge
      if labels = Tutorial.strip_labels(active)
        render_strip(screen, Rect.new(rect.x, rect.y + 1, rect.w, 1), labels, sub, level == :strip)
      end

      py = rect.y + 2
      ph = {rect.bottom - py, 3}.max
      gap = 2
      lw = {(rect.w - gap) // 2, 1}.max
      rw = {rect.w - gap - lw, 1}.max
      flows = Rect.new(rect.x, py, lw, ph)
      req = Rect.new(rect.x + lw + gap, py, rw, ph)
      @flows_rect = flows
      @request_rect = req
      render_flows_pane(screen, flows, in_body && pane == 0, flow)
      render_request_pane(screen, req, in_body && pane == 1, insert: insert, typed: typed, flow: flow)

      # Right-aligned, clear of the strip's chips on the same row.
      unless keyhint.empty?
        kh = " #{keyhint} "
        screen.text({rect.right - Screen.draw_width(kh), rect.x}.max, rect.y + 1, kh,
          Theme.ink_on(Theme.accent), Theme.accent, attr: Attribute::Bold)
      end
    end

    # The badge's word per focus level, as the app's reads (EDITOR while INS is on).
    def self.focus_badge(level : Symbol, insert : Bool = false) : String
      case level
      when :menu  then "TABS"
      when :strip then "SUBTABS"
      else             insert ? "EDITOR" : "BODY"
      end
    end

    # The SUBTABS row under the bar: the tab's own chips, the selected one gold while the strip
    # holds focus (as `TabController#render_subtab_strip` draws it), clipped to the row.
    private def render_strip(screen : Screen, row : Rect, labels : Array(String), sel : Int32, focused : Bool) : Nil
      @strip_rect = row
      cx = row.x
      labels.each_with_index do |name, i|
        chip = " #{name} "
        cw = Screen.draw_width(chip)
        break if cx + cw > row.right
        if i == sel
          bg = focused ? Theme.focus_gold : Theme.elevated
          screen.text(cx, row.y, chip, focused ? Theme.ink_on(Theme.focus_gold) : Theme.text, bg, attr: Attribute::Bold)
        else
          screen.text(cx, row.y, chip, Theme.muted, Theme.bg)
        end
        cx += cw
      end
    end

    # Cells the tab strip gets once the focus badge has taken its own. The badge's widest word
    # is ` SUBTABS `, reserved on every frame so the chips do not shift as focus moves, and a
    # shell too narrow to seat it gives the whole row to the chips (`render_shell`'s `badge`).
    #
    # A class method because the lessons ask the same question before they draw: the footer's
    # "1-N" (`chips_drawn`) and the spec that pins the Navigate demo to chips every size draws.
    BADGE_W = 9

    def self.bar_width(w : Int32) : Int32
      w > BADGE_W + 1 ? {w - BADGE_W - 1, 1}.max : w
    end

    # The hit rect and index of each mock tab chip, laid left to right and measured in terminal
    # CELLS. The advance to the next chip is the same `draw_width` the rect and the overflow test
    # use, so a wide-glyph tab name (the point of the i18n pre-work) pushes the run and its click
    # targets by the same amount instead of drifting one cell per wide char. Stops before the
    # first chip that would overflow `w`.
    def self.tab_chip_rects(labels : Array(String), x : Int32, y : Int32, w : Int32) : Array({Rect, Int32})
      hits = [] of {Rect, Int32}
      cx = x
      labels.each_with_index do |name, i|
        lw = Screen.draw_width(" #{name} ")
        break if cx + lw > x + w
        hits << {Rect.new(cx, y, lw, 1), i}
        cx += lw + 1
      end
      hits
    end

    # Each chip wears its SLOT NUMBER, like the real bar (`Chrome.menu_layout`'s `numbered`,
    # on by default). The digit is the key this lesson is about, and a chip that does not
    # carry it leaves `1-9` as a line of prose the screen never confirms.
    #
    # Unconditional, not gated on `Settings.tab_numbers?`: the digits keep working when that
    # switch is off — it only stops the bar from SAYING so — and a tour that silently drops
    # the one affordance it is teaching, on a setting the reader has not met yet, teaches
    # nothing in its place.
    def self.tab_labels : Array(String)
      TABS.map_with_index { |name, i| "#{i + 1}:#{name}" }
    end

    private def render_tab_bar(screen : Screen, x : Int32, y : Int32, w : Int32,
                               active : Int32, focused : Bool) : Nil
      labels = Tutorial.tab_labels
      @tab_hits = Tutorial.tab_chip_rects(labels, x, y, w)
      @tab_hits.each do |(rect, i)|
        if i == active
          bg = focused ? Theme.focus_gold : Theme.accent_bg
          fg = focused ? Theme.ink_on(Theme.focus_gold) : Theme.text_bright
          screen.text(rect.x, y, " #{labels[i]} ", fg, bg, attr: Attribute::Bold)
        else
          # The `N:` run a step dimmer than the name — Chrome.menu_number_ink, the same ink
          # and the same rule the real bar paints an inactive numbered chip with, so the
          # number reads as the lesser half of the label here too.
          num = "#{i + 1}:"
          screen.text(rect.x + 1, y, num, Chrome.menu_number_ink, Theme.bg)
          screen.text(rect.x + 1 + num.size, y, TABS[i], Theme.muted, Theme.bg)
        end
      end
    end

    private def render_flows_pane(screen : Screen, rect : Rect, focused : Bool, flow : Int32) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "FLOWS", border: Frame.pane_border(focused))
      yy = rect.y + 1
      FLOW_ROWS.each_with_index do |(method, path, status), i|
        break if yy >= rect.bottom - 1
        sel = focused && i == flow
        bg = sel ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), bg)
        screen.cell(rect.x + 1, yy, sel ? '▎' : ' ', Theme.accent, bg)
        screen.text(rect.x + 3, yy, method, Theme.method_color(method.strip), bg)
        px = rect.x + 8
        pw = {rect.right - 1 - 4 - px, 1}.max
        screen.text(px, yy, path, sel ? Theme.text_bright : Theme.text, bg, width: pw)
        sts = status.to_s
        screen.text(rect.right - 1 - sts.size, yy, sts, Theme.status_color(status), bg)
        yy += 1
      end
    end

    private def render_request_pane(screen : Screen, rect : Rect, focused : Bool, *,
                                    insert : Bool, typed : String, flow : Int32) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, "REQUEST", border: Frame.pane_border(focused))
      badge_min = rect.x + 10
      Frame.mode_badge(screen, rect.right - 1, rect.y, badge_min, insert)

      ix = rect.x + 2
      iw = {rect.w - 4, 1}.max
      yy = rect.y + 1
      # Reflect the selected flow path so the two panes feel linked. The INDEX RENDER_SHELL
      # WAS HANDED, not @p_flow — its sibling `render_flows_pane` marks the row from the
      # parameter, and reading the field here meant the two panes could name different flows
      # on any lesson that draws the shell with a fixed one.
      method, path, _ = FLOW_ROWS[flow]? || FLOW_ROWS[0]
      method = method.strip
      # A well-formed request, head then a BLANK line then the body (#1382): the mock used to
      # glue `username=` straight under the headers, on a GET.
      ["#{method} #{path} HTTP/1.1", "Host: example.com", ""].each do |ln|
        break if yy >= rect.bottom - 1
        screen.text(ix, yy, ln, Theme.text, Theme.panel, width: iw)
        yy += 1
      end
      return unless yy < rect.bottom - 1
      # Only the POST carries a form body; on a GET the body row holds just what was typed.
      prefix = method == "POST" ? "username=" : ""
      if insert
        px = screen.text(ix, yy, "#{prefix}#{typed}", Theme.text_bright, Theme.panel, width: iw)
        screen.cell({px, rect.right - 2}.min, yy, ' ', Theme.bg, Theme.accent)
      elsif !typed.empty? || (!prefix.empty? && (focused || @tried_edit))
        screen.text(ix, yy, "#{prefix}#{typed}", Theme.text, Theme.panel, width: iw)
      elsif !prefix.empty?
        screen.text(ix, yy, "#{prefix}alice", Theme.muted, Theme.panel, width: iw)
      end
    end

    private def draw_palette_overlay(screen : Screen, shell : Rect, *, live : Bool) : Nil
      pw = { {shell.w - 8, 40}.min, 24 }.max
      # Tall enough for the whole browse when the shell can spare it: border + query + divider
      # + rows + border. Sized by the browse, not by the current matches, so the card does not
      # jump as the query narrows; a longer list scrolls (`palette_rows_visible`).
      ph = { {shell.h - 1, PALETTE_ROWS.size + 4}.min, 6 }.max
      px = shell.x + {(shell.w - pw) // 2, 0}.max
      py = shell.y + {(shell.h - ph) // 2, 0}.max
      rect = Rect.new(px, py, pw, ph)
      @palette_rect = rect if live
      render_fake_palette(screen, rect, live: live)
    end

    # The menu floats over the panes' bottom-right, as the real card floats over the pane.
    # Clamped to the shell, one row clear of the floor: the panes' bottom border sits on
    # `shell.bottom - 1`, and a menu whose own border landed on that row drew `╰────╰────╯╯` —
    # two frames fused where a popup should float clear of the pane it is over. A short shell
    # clips the list, which then scrolls with the selection (the family row sits high,
    # SEND_ROW_AT, so it is drawn even at the smallest card).
    private def draw_space_overlay(screen : Screen, shell : Rect, level : Int32, sel : Int32, *, live : Bool) : Nil
      rows = level == 2 ? @send_rows : @space_rows
      title = level == 2 ? Tutorial.send_card_title : "SPACE"
      mw = {SPACE_MENU_W, shell.w - 3}.min
      mh = {rows.size + 2, shell.h - 1}.min
      mx = shell.right - mw - 2 # one column clear of the pane's right border
      my = {shell.bottom - mh - 1, shell.y}.max
      return unless mx > shell.x && mh >= 3
      rect = Rect.new(mx, my, mw, mh)
      @space_rect = rect if live
      render_fake_space_menu(screen, rect, title, rows, sel)
    end

    # The drawn rows, the first one on screen, and how many fit — ONE home for the draw loop
    # and the click hit-test, which have drifted apart here before (see
    # `palette_rows_visible`). The window scrolls by the selection's DRAWN row, so a group
    # header above it counts, as in `PaletteState#ensure_visible`.
    private def palette_window(rect : Rect, rows : Array(PalRow), sel : Int32) : {Array({String, Int32?}), Int32, Int32}
      display = Tutorial.palette_display(rows)
      sel_row = display.index { |(_, i)| i == sel } || 0
      vis = Tutorial.palette_rows_visible(rect)
      {display, Tutorial.palette_scroll(sel_row, display.size, vis), vis}
    end

    private def render_fake_palette(screen : Screen, rect : Rect, *, live : Bool) : Nil
      return if rect.w < 12 || rect.h < 4
      Frame.card(screen, rect, "COMMANDS", border: Theme.border_focus)
      screen.text(rect.x + 2, rect.y + 1, "›", Theme.accent, Theme.panel)
      # The demo types the lesson's query a letter at a time, then holds it: an empty browse
      # first, then the grouped result, which is the picture the lesson is about.
      q = live ? @pal_query : PALETTE_DEMO_QUERY[0, ((@tick // 5) % 16 - 3).clamp(0, PALETTE_DEMO_QUERY.size)]
      qx = rect.x + 4
      qw = {rect.right - 2 - qx, 1}.max
      if q.empty?
        screen.cell(qx, rect.y + 1, ' ', Theme.bg, Theme.accent)
      else
        screen.text(qx, rect.y + 1, q, Theme.text_bright, Theme.panel, width: qw)
        # COLUMNS, not characters: the query accepts CJK/Hangul now (Tutorial.typed_char),
        # and each of those is two columns wide — counting them as one parked the caret
        # inside the text it is supposed to follow.
        caret_x = qx + {Screen.draw_width(q), qw - 1}.min
        screen.cell(caret_x, rect.y + 1, ' ', Theme.bg, Theme.accent) if caret_x < rect.right - 1
      end
      Frame.tee_divider(screen, rect, rect.y + 2)

      rows = live ? filtered_palette : Tutorial.palette_matches(q, @pal_tab_rows)
      sel = live && !rows.empty? ? @pal_sel.clamp(0, rows.size - 1) : 0
      display, top, vis = palette_window(rect, rows, sel)
      yy = rect.y + 3
      display[top, vis].each do |(header, idx)|
        unless idx
          screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), Theme.panel)
          screen.text(rect.x + 3, yy, "─ #{header} ─", Theme.muted, Theme.panel)
          yy += 1
          next
        end
        row = rows[idx]
        s = idx == sel
        bg = s ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), bg)
        screen.cell(rect.x + 1, yy, s ? '▎' : ' ', Theme.accent, bg)
        screen.text(rect.x + 3, yy, row.sigil, Theme.muted, bg)
        # The hint column is the lesson (the route to the row), so the label gives way to it.
        hx = rect.right - 2 - Screen.draw_width(row.hint)
        screen.text(rect.x + 5, yy, row.label, s ? Theme.text_bright : Theme.text, bg,
          width: {hx - 1 - (rect.x + 5), 1}.max)
        screen.text(hx, yy, row.hint, Theme.muted, bg) unless row.hint.empty?
        yy += 1
      end
      # A scrolled list says so, on the border row it is covering — otherwise a window showing
      # 2 of 5 reads as a palette with only 2 commands in it. Rows BELOW the window, not rows
      # hidden in total: it is painted at the bottom edge, so it can only be read as "more
      # that way", and it went on claiming "+3" with the user parked on the last row.
      below = display.size - top - vis
      if vis > 0 && below > 0
        more = "+#{below}"
        screen.text({rect.right - 1 - more.size, rect.x + 1}.max, rect.bottom - 1, more, Theme.muted, Theme.panel)
      end
      if live && rows.empty? && yy < rect.bottom - 1
        screen.text(rect.x + 3, yy, "(no matches)", Theme.muted, Theme.panel)
      end
    end

    private def render_fake_space_menu(screen : Screen, rect : Rect, title : String,
                                       rows : Array(MenuRow), sel : Int32) : Nil
      return if rect.w < 8 || rect.h < 3
      Frame.card(screen, rect, title, border: Theme.border_focus)
      vis = rect.h - 2
      top = Tutorial.palette_scroll(sel, rows.size, vis)
      yy = rect.y + 1
      rows[top, vis].each_with_index do |row, i|
        s = top + i == sel
        bg = s ? Theme.accent_bg : Theme.panel
        screen.fill(Rect.new(rect.x + 1, yy, rect.w - 2, 1), bg)
        screen.cell(rect.x + 1, yy, s ? '▎' : ' ', Theme.accent, bg)
        screen.cell(rect.x + 3, yy, row.key, Theme.accent, bg, attr: Attribute::Bold)
        hx = rect.right - 2 - Screen.draw_width(row.hint)
        screen.text(rect.x + 5, yy, row.title, s ? Theme.text_bright : Theme.text, bg,
          width: {hx - 1 - (rect.x + 5), 1}.max)
        screen.text(hx, yy, row.hint, row.opens ? Theme.accent : Theme.muted, bg) unless row.hint.empty?
        yy += 1
      end
    end
  end
end
