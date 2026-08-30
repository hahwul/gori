require "./screen"
require "./theme"
require "./frame"
require "./spark"
require "./fmt"
require "./text_area"
require "./input_mode"
require "./text_read_state"
require "./gutter"
require "./traffic_empty_state"
require "../project"
require "../project_registry"
require "../paths"
require "../store"
require "../scope"
require "../probe"
require "../host_overrides"
require "../settings"
require "../env"
require "./highlight"

module Gori::Tui
  # The Project tab (new default home on entry after create/select). Shows static
  # project metadata (name, created, sizes, counts) + an editable DESCRIPTION
  # (multi-line, persisted in store settings like Notes). Editing is live when
  # the tab body has focus (cursor visible); Esc / ^P / ^C save + exit like NotesView.
  # Description can also be provided optionally when creating via the picker.
  class ProjectView
    DESC_KEY = "description"

    @project : Project?
    @flow_count : Int64
    @issues_count : Int32
    @db_size : Int64
    @total_captured : Int64
    @created : Time?
    # AT A GLANCE viz snapshot (color-free: raw counts only, colours resolve live at
    # draw so a theme switch needs no rebuild — the Fuzzer DistData convention).
    @status_counts : Array({Int32?, Int64})
    @sev_tally : StaticArray(Int64, 5)
    @desc_area : TextArea
    # Registry sidecar facts, nil off the canonical registry db (see `overview_groups`).
    @proj_id : String?
    @workspace : String?
    @last_activity : Time?
    @probe_count : Int32
    # Live capture state. NOT snapshotted by `reload`: capture starts and stops while this tab
    # sits open, so the controller re-supplies it on every render instead.
    @capturing : Bool

    # The body shows ONE card at a time, picked by the shell's sub-tab strip (@focus ==
    # :subtabs owns ←/→; the card underneath is only focused once you drop in with ↓/↵).
    # @pane names the active sub-tab, i.e. where keys land while the body holds focus.
    getter pane : Symbol

    def initialize(@scope : Scope, @host_overrides : HostOverrides)
      @project = nil
      @flow_count = 0
      @issues_count = 0
      @probe_tech = [] of String # Probe-detected representative technologies (project facts)
      @db_size = 0
      @total_captured = 0
      @created = nil
      @status_counts = [] of {Int32?, Int64}
      @sev_tally = StaticArray(Int64, 5).new(0_i64)
      @proj_id = nil
      @workspace = nil
      @last_activity = nil
      @probe_count = 0
      @capturing = false
      @desc_area = TextArea.new
      # Soft wrap, like every other reading surface in the tree. A description is prose typed
      # as one logical line per paragraph, so the `follow_x` sideways pan this used to carry
      # showed one screenful of each and hid the rest behind ⇧←/→.
      @desc_area.wrap = true
      @desc_dirty = false
      @desc_mode = InputMode::Read
      @desc_read = TextReadState.new

      @pane = :desc    # :desc | :scope | :overrides | :env | :settings | :activity (PANES order)
      @strip_start = 0 # first visible sub-tab chip (Chrome.render_tab_strip owns the window)
      @sel = 0         # selected rule row in the SCOPE list
      # SCOPE add/edit is a centered popup (ScopeRuleOverlay), not an inline row.

      # HOST OVERRIDES pane: its own selection + inline add/edit row, fully independent
      # of the SCOPE pane above it (single-line "IP host" entry, /etc/hosts order).
      @ov_sel = 0
      @ov_adding = false
      @ov_edit_id = nil.as(Int64?) # non-nil ⇒ editing an existing override
      @ov_input = ""               # add-row text ("IP host")
      @ov_icx = 0                  # add-row cursor index
      @ov_preedit = ""             # IME preedit for the add-row

      # ACTIVITY pane: a materialized PAGE of the #124 event feed, not a live object. The
      # cursor is anchored to an event ID rather than a row index — the list is newest-first and
      # PREPENDS, so a bare index slides onto a neighbour the moment a peer's write lands and
      # `↵` then jumps somewhere the operator never selected (the failure
      # `notifications_overlay.cr` documents in full). `id` is AUTOINCREMENT and never reused.
      @act_rows = [] of Store::EventRow
      @act_sel = 0
      @act_anchor = nil.as(Int64?)      # id of the selected event
      @act_next_before = nil.as(Int64?) # resume point; nil ⇒ the feed genuinely ends here
      @act_feed_empty = true            # the FEED is empty, as opposed to the filters hiding it
      @act_scanned = 0                  # ids the scan has READ so far (for the empty sentence)
      # Whether `↓` has walked the cursor PAST page one. The one thing that tells an empty list
      # that has looked no further than the newest window from one that has walked windows back,
      # which `@act_next_before` cannot: it is nil both for a feed whose bottom the scan reached
      # and for a feed that holds nothing at all. `refresh_activity` needs the difference —
      # rewinding a walk is a bug, adopting page one's cursor when no walk exists is required.
      @act_walked = false
      # Events that landed above a cursor parked mid-list since it was last on the head. Rendered
      # on the card border: prepending under a parked cursor is silent otherwise, and a feed that
      # has quietly stopped showing its own newest rows reads as a feed that has gone quiet.
      @act_new_above = 0
      @act_source = nil.as(String?)
      @act_level = nil.as(String?)
      @act_actor = nil.as(String?)
      @act_filter = TextField.new
      @act_querying = false

      @env_items = [] of {String, String}
      @env_sel = 0
      @env_adding = false
      @env_prefix_editing = false # non-nil ⇒ the single-line prefix editor is up (shares @env_input)
      @env_edit_idx = nil.as(Int32?)
      # The KEY an open edit row targets, so `reload_env_vars` can re-anchor the index when a
      # peer process reorders or shortens the list under it.
      @env_edit_key = nil.as(String?)
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""

      # PROJECT SETTINGS pane: two policy toggles plus project network/proxy fields and the
      # target's protobuf schema. Authentication belongs to the project proxy pin, not global
      # settings.json; the schema has its own baseline and commit path.
      @set_sel = 0
      @set_values = ["", "", "", "", "", "", "", "", "", "", "", "", ""]
      @set_overridden = [false, false, false, false, false, false,
                         false, false, false, false, false, false]
      @set_baseline = {"", "", "", "", "", "", "", "", "", "", "", ""}
      @set_upstream_raw = ""
      @protos_baseline = ""
      @set_cursor = 0
      @set_preedit = ""
      load_settings_values
    end

    # Snapshot stats from the live session (called on tab enter and initial run).
    # Re-loading is cheap and keeps numbers fresh when user switches away and back
    # after more capture.
    def reload(project : Project, store : Store) : Nil
      @project = project
      @flow_count = store.count
      @issues_count = store.count_issues
      @probe_tech = scoped_tech(store.probe_tech_rows)
      @db_size = project.db_size
      @total_captured = store.total_size
      @last_activity = project.last_modified
      # AT A GLANCE aggregates: traffic status mix + Issues severity (human-confirmed
      # `issues` table only — Probe hits stay on the Probe tab, not here). That still holds for
      # the CHART; the OVERVIEW band beside it does carry a Probe *count* — see `issues_value`.
      @status_counts = store.flow_status_counts
      @sev_tally = store.issues_severity_counts
      @probe_count = store.count_probe_issues
      load_registry_facts(project)
      earliest = store.earliest_created_at
      # earliest_created_at is unix MICROSECONDS (the flows.created_at unit) — decoder
      # to seconds for Time.unix, like History's fmt_time does. (Passing micros makes
      # Time.unix raise "seconds out of range".)
      @created = earliest ? Time.unix(earliest // 1_000_000) : project.created

      # An UNSAVED buffer is not refreshed from the store: `save` only clears `@desc_dirty`
      # once the write committed, so a still-dirty buffer means the operator's text has not
      # landed yet, and re-seeding it from the stored value here is precisely the clobber that
      # loses it. Every other field on the tab still refreshes.
      unless @desc_dirty
        @desc_area.set_text(store.setting(DESC_KEY) || "")
        @desc_mode = InputMode::Read
        @desc_read.sync_from(@desc_area)
      end
      load_settings_values
      # THE one re-seed, shared with the external-change path. Tab entry is the other moment
      # the list can move under an open EDIT row — `flush_active_tab_edits` persists the
      # description and the network fields on the way out but does not cancel this row (only a
      # SUB-tab change does, via `settle_subtab`), so a top-level tab round trip past a peer's
      # write left the row indexing a list that had shifted. Re-seeding without the anchor is
      # exactly the case `env_commit`'s bound check can no longer catch: an index that is stale
      # but still IN RANGE writes the wrong row and then persists the whole array.
      reload_env_vars
    end

    # The registry's sidecar facts about this project: its short id and the workspace it is
    # bound to. Two small `File.read`s, which is why they can ride `reload`.
    #
    # Only for a REGISTRY project. A `Project` built from an explicit `--db PATH` borrows an
    # arbitrary parent directory, so the `.id`/`.workspace` probes there would read sidecars
    # describing whatever ELSE lives in that directory.
    # `Project#canonical?` is the same discriminator the sidecar paths themselves use, so the
    # two cannot drift.
    private def load_registry_facts(project : Project) : Nil
      unless registry_project?(project)
        @proj_id = @workspace = nil
        return
      end
      reg = ProjectRegistry.new(Paths.projects_dir)
      @proj_id = reg.id_of(project)
      @workspace = reg.workspace_of(project)
    rescue
      # A sidecar that vanished or is unreadable costs two rows, never the tab.
      @proj_id = @workspace = nil
    end

    # Whether this project's directory is one the REGISTRY owns.
    #
    # `Project#canonical?` alone is not that test: it only asks whether the file is named
    # `gori.db`, so `--db ~/backup/api/gori.db` passes it and would read that directory's
    # `.id`/`.workspace` — printing an id that `ProjectRegistry#find` resolves to a DIFFERENT
    # project. That is the same "a confidently wrong identifier is worse than none" this guard
    # exists for, one level out. So require both: the canonical filename AND a parent that is
    # the projects root.
    private def registry_project?(project : Project) : Bool
      project.canonical? && File.dirname(project.dir) == Paths.projects_dir
    end

    # (Re)load the PROJECT SETTINGS network fields from the effective config — the project
    # override when pinned, else the global default (Session.open populated Settings.project_*
    # from this project's DB on open). @set_overridden drives the "· project/global" marker
    # (the project-only fields use "· default" — see SETTINGS_PROJECT_ONLY_INDICES).
    #
    # The bind pair uses `configured_bind_*`, NOT `effective_bind_*`: those two differ only by
    # the process-only `-l`/`-p` layer, which is neither a project pin nor the global — so it
    # would be shown here under a "· global" marker that misnames it, and would become an
    # inherit-baseline that makes the running port unpinnable. See Settings.configured_bind_host.
    private def load_settings_values : Nil
      # The proto-schema slot has to exist before `load_network_values` writes in place.
      @set_values = network_values + [Protobuf::Schemas.spec]
      load_network_values
      load_protos_value
    end

    # The twelve NETWORK fields only, written in place so the proto-schema slot beside them
    # survives. Partial ON PURPOSE: the two halves commit separately, so each half's refresh
    # must leave the other's pending edit alone — see `refresh_settings` / `refresh_protos`.
    private def load_network_values : Nil
      network_values.each_with_index { |v, i| @set_values[i] = v }
      @set_overridden = [
        !Settings.project_bind_host.nil?,
        !Settings.project_bind_port.nil?,
        !Settings.project_upstream_proxy.nil?,
        !Settings.project_upstream_proxy.nil?,
        !Settings.project_upstream_proxy.nil?,
        !Settings.project_upstream_destination.nil?,
        !Settings.project_upstream_auth.nil?,
        !Settings.project_upstream_auth.nil?,
        !Settings.project_upstream_auth.nil?,
        !Settings.project_connect_timeout_secs.nil?,
        !Settings.project_io_timeout_secs.nil?,
        !Settings.project_capture_max_mib.nil?,
      ]
      @set_cursor = current_set_value.size
      @set_baseline = settings_values # capture the load state so "dirty" means the USER edited a field
    end

    # The project's descriptor-set path as the loader currently holds it. Blank means the
    # convention directory (`~/.gori/protos`), which is what an unconfigured project uses.
    private def load_protos_value : Nil
      @set_values[SETTINGS_PROTOS_FIELD] = Protobuf::Schemas.spec
      @set_cursor = current_set_value.size
      @protos_baseline = protos_value
    end

    private def network_values : Array(String)
      @set_upstream_raw = Settings.effective_upstream_proxy
      proxy = project_proxy_field_values(@set_upstream_raw)
      [
        Settings.configured_bind_host,
        Settings.configured_bind_port.to_s,
        proxy[0],
        proxy[1],
        proxy[2],
        Settings.effective_project_upstream_destination,
        Settings.project_upstream_auth ? "on" : "off",
        Settings.project_upstream_auth.try(&.username) || "",
        Settings.project_upstream_auth.try(&.password) || "",
        Settings.effective_connect_timeout_secs.to_s,
        Settings.effective_io_timeout_secs.to_s,
        Settings.effective_capture_max_mib.to_s,
      ]
    end

    private def project_proxy_field_values(raw : String) : {String, String, String}
      if fields = Settings.upstream_proxy_fields(raw)
        {project_proxy_protocol_label(fields[0]), fields[1], fields[2]}
      else
        {"Invalid · #{raw}", "", ""}
      end
    end

    private def project_proxy_protocol_label(kind : String) : String
      case kind
      when "http"    then "HTTP"
      when "socks5"  then "SOCKS5"
      when "socks5h" then "SOCKS5H"
      else                "None"
      end
    end

    private def current_set_value : String
      settings_text_row? ? @set_values[@set_sel - SETTINGS_FIELD_BASE] : ""
    end

    # Drop tech fingerprints seen only on out-of-scope hosts before summarizing — with
    # the scope lens ON, "representative technologies" should describe the in-scope
    # target, not every host the proxy happened to see traffic for (mirrors ProbeView).
    private def scoped_tech(rows : Array({String, String, String?})) : Array(String)
      rows = rows.select { |(_, host, _)| @scope.host_in_scope?(host) } if @scope.active?
      Probe.tech_summary(rows.map { |(code, _, ev)| {code, ev} })
    end

    # IME preedit routes to whichever pane is composing (SCOPE uses a popup overlay).
    def set_preedit(text : String) : Nil
      if @pane == :overrides && @ov_adding
        @ov_preedit = text
      elsif @pane == :env && (@env_adding || @env_prefix_editing)
        @env_preedit = text
      elsif @pane == :settings && settings_text_row?
        @set_preedit = text
      elsif @pane == :desc && desc_insert_mode?
        @desc_area.set_preedit(text)
      elsif @pane == :activity && @act_querying
        @act_filter.set_preedit(text)
      end
    end

    def desc_text : String
      @desc_area.text
    end

    getter desc_mode : InputMode

    def desc_insert_mode? : Bool
      @desc_mode == InputMode::Insert
    end

    def enter_desc_insert! : Nil
      @desc_mode = InputMode::Insert
      @desc_read.sync_from(@desc_area)
    end

    def exit_desc_insert! : Nil
      @desc_mode = InputMode::Read
      # Carry an INS ⇧arrow selection over to READ — see TextReadState#adopt_editor_selection.
      @desc_read.adopt_editor_selection(@desc_area)
    end

    def desc_read_move(dr : Int32, dc : Int32, selecting : Bool = false) : Nil
      return if desc_insert_mode?
      @desc_read.move(@desc_area, dr, dc, selecting: selecting)
    end

    # One selection model per mode — see NotesView#selection? / RepeaterView#pane_selection?.
    def desc_copy_text : String
      if desc_insert_mode?
        @desc_area.selection_text || @desc_read.copy_text(@desc_area)
      else
        @desc_read.copy_text(@desc_area)
      end
    end

    def desc_copy_all : String
      @desc_read.copy_all(@desc_area)
    end

    def desc_selection? : Bool
      return false unless @pane == :desc
      desc_insert_mode? ? @desc_area.selection? : @desc_read.selection?
    end

    def desc_select_line : Nil
      return if desc_insert_mode?
      @desc_read.select_line(@desc_area)
    end

    def desc_clear_selection : Nil
      @desc_read.clear_selection
    end

    def desc_hscroll(delta : Int32) : Nil
      return if desc_insert_mode?
      @desc_read.move(@desc_area, 0, delta * 4)
    end

    # INSERT-mode motion: the shared editor keymap (⇧arrows select, Page keys, ⌥←/→ by word,
    # ⌥⌫ deletes one) — see `TextArea#handle_motion_key`. Dirties only on a real buffer
    # change, which in this set is ⌥⌫ alone.
    def desc_motion_key(ev : Termisu::Event::Key) : Bool
      before = @desc_area.edits
      return false unless @desc_area.handle_motion_key(ev)
      @desc_dirty = true if @desc_area.edits != before
      true
    end

    # READ-mode Home/End/Page. The caret + selection this mode paints are `@desc_read`'s, so
    # Home/End go through the editor and are then mirrored back onto the read cursor.
    def desc_read_motion_key(ev : Termisu::Event::Key) : Bool
      return false if desc_insert_mode?
      key = ev.key
      shift = ev.shift?
      case
      when key.home?      then @desc_area.home(shift)
      when key.end?       then @desc_area.end_of_line(shift)
      when key.page_up?   then desc_read_move(-@desc_area.page_rows, 0, selecting: shift)
      when key.page_down? then desc_read_move(@desc_area.page_rows, 0, selecting: shift)
      else                     return false
      end
      @desc_read.sync_to(@desc_area, selecting: shift) if key.home? || key.end?
      true
    end

    def desc_word_delete_key?(ev : Termisu::Event::Key) : Bool
      @desc_area.word_delete_key?(ev)
    end

    # Mouse DRAG / DOUBLE-CLICK over the description — the click already forced INSERT, so
    # both work on the editor's own selection.
    def desc_drag_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless desc_insert_mode?
      return unless card = card_rect(rect, :desc)
      @desc_area.click_to_cursor(card.inset(1, 1), mx, my, selecting: true)
    end

    def desc_select_word(rect : Rect, mx : Int32, my : Int32) : Bool
      return false unless card = card_rect(rect, :desc)
      enter_desc_insert!
      @desc_area.select_word_at(card.inset(1, 1), mx, my)
    end

    # Sub-tab order, left to right. DESCRIPTION leads: it's the one card you WRITE rather
    # than configure, so it's both the most-visited chip and the natural landing spot when
    # the tab opens; the four configuration cards follow.
    PANES = [:desc, :scope, :overrides, :env, :settings, :activity]
    # Chip labels, in PANES order. Kept parallel rather than derived from the symbols so a
    # label can read well ("HOST OVERRIDES") without renaming the pane it addresses.
    #
    # ACTIVITY sits LAST: it is the only card that reports rather than configures, and putting
    # a live log between two settings editors would make the strip read as five settings with
    # one anomaly. Six chips want 76 columns; below that `Chrome.scroll_start` windows them and
    # keeps the active one visible, which is the same treatment every other strip gets.
    PANE_LABELS = ["Description", "Scope", "Host overrides", "Env", "Project settings", "Activity"]
    # One row for the sub-tab chips.
    STRIP_H = 1

    # PROJECT SETTINGS pane rows: two toggles (scope-lens, sandbox) over the inline project
    # fields. The auth method is inferred from the proxy kind, so its row is only off/on: HTTP
    # means Basic and SOCKS5 means RFC 1929. This prevents a method selector disagreeing with
    # the transport it is supposed to authenticate.
    #
    # "Proto schema" (#823) sits LAST and is deliberately not part of the network tuple: it is
    # committed on its own baseline, so editing it never re-applies (and re-BINDS) unchanged
    # network values. It is an engagement property for the same reason the timeouts are.
    SETTINGS_LABELS = ["Scope lens", "Sandbox", "Bind IP", "Bind Port", "Proxy protocol",
                       "Proxy host", "Proxy port", "Destination host", "Proxy auth", "Username",
                       "Password", "Connect timeout", "Idle timeout", "Capture limit", "Proto schema"]
    SETTINGS_SCOPE_ROW         =  0
    SETTINGS_SANDBOX_ROW       =  1
    SETTINGS_FIELD_BASE        =  2 # first inline-editable network-field row
    SETTINGS_PROTOCOL_ROW      =  4
    SETTINGS_PROXY_HOST_ROW    =  5
    SETTINGS_PROXY_PORT_ROW    =  6
    SETTINGS_DESTINATION_ROW   =  7
    SETTINGS_AUTH_ROW          =  8
    SETTINGS_USERNAME_ROW      =  9
    SETTINGS_PASSWORD_ROW      = 10
    SETTINGS_PROTOCOL_INDEX    = SETTINGS_PROTOCOL_ROW - SETTINGS_FIELD_BASE
    SETTINGS_PROXY_HOST_INDEX  = SETTINGS_PROXY_HOST_ROW - SETTINGS_FIELD_BASE
    SETTINGS_PROXY_PORT_INDEX  = SETTINGS_PROXY_PORT_ROW - SETTINGS_FIELD_BASE
    SETTINGS_DESTINATION_INDEX = SETTINGS_DESTINATION_ROW - SETTINGS_FIELD_BASE
    SETTINGS_AUTH_INDEX        = SETTINGS_AUTH_ROW - SETTINGS_FIELD_BASE
    SETTINGS_USERNAME_INDEX    = SETTINGS_USERNAME_ROW - SETTINGS_FIELD_BASE
    SETTINGS_PASSWORD_INDEX    = SETTINGS_PASSWORD_ROW - SETTINGS_FIELD_BASE
    SETTINGS_PROTOS_FIELD      = 12
    SETTINGS_LABEL_W           = 16 # value column starts past the widest label ("Connect timeout")
    SETTINGS_PROTOCOL_CHOICES  = ["None", "HTTP", "SOCKS5", "SOCKS5H"]
    # Fields with no global counterpart to inherit — their unset marker is "· default", not
    # "· global" (see render_settings_field).
    SETTINGS_PROJECT_ONLY_INDICES = [SETTINGS_DESTINATION_INDEX, SETTINGS_USERNAME_INDEX,
                                     SETTINGS_PASSWORD_INDEX]

    # The 's' / scope.edit jump target: focus the SCOPE pane fresh (no half-open row in
    # either list).
    def focus_scope : Nil
      @pane = :scope
      cancel_ov_add
      cancel_env_add
      cancel_env_prefix_edit
    end

    # Whether `pane_advance` would land on a pane at all. Peeked SEPARATELY because the
    # controller has to decide before it settles: settling a step that then gets refused is a
    # side effect with no navigation attached to it (see `ProjectController#move_subtab`).
    def pane_can_advance?(dir : Int32) : Bool
      i = pane_index + dir
      i >= 0 && i < PANES.size
    end

    # Step to the neighbouring sub-tab; false at either end (the strip clamps, it does not
    # wrap — same as the chips read). Driven by the strip's ←/→ via move_subtab.
    def pane_advance(dir : Int32) : Bool
      return false unless pane_can_advance?(dir)
      @pane = PANES[pane_index + dir]
      true
    end

    # Select a sub-tab directly (a chip click / ^1-9). Ignores unknown symbols.
    def focus_pane(pane : Symbol) : Nil
      @pane = pane if PANES.includes?(pane)
    end

    # --- geometry (ONE source of truth so render + every hit-test stay in lockstep) ---

    # Hard ceiling on the OVERVIEW band, so a tall terminal spends the surplus on the CARD
    # below rather than on ever-taller label columns.
    OVERVIEW_CAP = 11
    # Inner width the band needs before its rows deal into TWO columns. Measured on the width
    # OVERVIEW actually RECEIVED (i.e. after `viz_width` takes its slice), never negotiated
    # with the viz pane — this reads what it got, so the two cannot fight over the same cells.
    OVERVIEW_2COL_MIN_W = 64

    # Inner rows the band has to spend, before deciding what to spend them on.
    private def overview_budget(rect : Rect) : Int32
      { {rect.h * 2 // 5, 3}.max, OVERVIEW_CAP }.min - 2
    end

    # Width OVERVIEW is left with once the AT A GLANCE pane takes its slice — the same split
    # `render` performs, expressed once so the layout decision below cannot disagree with it.
    private def overview_inner_w(rect : Rect) : Int32
      vw = viz_width(rect.w)
      {(vw > 0 ? rect.w - vw - 1 : rect.w) - 2, 0}.max
    end

    # Height of the top OVERVIEW band. Content-driven with a cap: a band that folds its rows
    # (see `overview_plan`) needs fewer of them, and every row it gives back goes to the card
    # underneath. Still a PURE function of `rect`, which is what keeps it the single source of
    # truth `strip_rect` / `active_card` / `strip_chip_at` / `pane_at` all route through.
    private def overview_h(rect : Rect) : Int32
      plan = overview_plan(rect)
      {plan.rows + (plan.signpost ? 1 : 0) + 2, overview_budget(rect) + 2, OVERVIEW_CAP}.min
    end

    # Width carved off the RIGHT of the OVERVIEW band for the AT A GLANCE viz pane, or 0
    # to hide it (so OVERVIEW keeps its full width on a narrow terminal). Mirrors the
    # Fuzzer DIST sidebar's dist_width gating.
    VIZ_MIN_TOTAL = 64 # below this band width, no room to split without cramping OVERVIEW
    # The bars fill `inner.w` (see `render_bar_row`), so this cap is the only thing that was
    # stopping them growing on a wide terminal. The 32% proportion below still governs, so
    # OVERVIEW keeps the larger share and only a genuinely wide band reaches this ceiling.
    VIZ_MAX_W = 36
    VIZ_MIN_W = 24

    private def viz_width(w : Int32) : Int32
      return 0 if w < VIZ_MIN_TOTAL
      vw = {w * 32 // 100, VIZ_MAX_W}.min
      vw < VIZ_MIN_W ? 0 : vw
    end

    # SUB-TAB layout. The body shows ONE card at a time, under a chip strip, instead of
    # tiling all five at once.
    #
    # Tiling was the previous design and it ran out of room: five cards split a single body
    # between them, so SETTINGS got a fixed 6-row slice and ENV was DROPPED entirely below a
    # height threshold — a pane silently disappearing is a bad answer to "the terminal is
    # short". One card at full size removes the threshold, and gives each editor room to grow
    # (which is what let PROJECT SETTINGS take its per-project overrides).
    #
    # The whole content rect belongs to whichever sub-tab is showing; nil when the body is too
    # small to draw a card at all.
    private def active_card(rect : Rect) : Rect?
      oh = overview_h(rect)
      content = Rect.new(rect.x, rect.y + oh, rect.w, {rect.h - oh, 0}.max)
      return nil if content.h < 3 || content.w < 4
      Rect.new(content.x, content.y + STRIP_H, content.w, {content.h - STRIP_H, 0}.max)
    end

    # The card rect IFF `pane` is the sub-tab currently showing. Every per-pane hit-test goes
    # through this, so a sub-tab the body isn't drawing simply can't be hit — the property the
    # retired 5-tuple (active pane gets the rect, the rest get zero-height ones) encoded
    # positionally, and which a reorder of PANES would have silently repointed.
    private def card_rect(rect : Rect, pane : Symbol) : Rect?
      return nil unless @pane == pane
      active_card(rect)
    end

    # The one-row chip strip above the active card.
    private def strip_rect(rect : Rect) : Rect
      Rect.new(rect.x, rect.y + overview_h(rect), rect.w, STRIP_H)
    end

    def pane_index : Int32
      PANES.index(@pane) || 0
    end

    # --- mouse hit-testing (inverts render's offset math; coords are 0-based) ---

    # The sub-tab chip under (mx,my), or nil when the point isn't on one. Public so the
    # controller can route a chip click to the shell's :subtabs focus BEFORE it is mistaken
    # for a click into the card below (the chip strip is how the mouse reaches a sub-tab the
    # body isn't drawing).
    def strip_chip_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if rect.empty? || active_card(rect).nil?
      strip = strip_rect(rect)
      return nil unless strip.contains?(mx, my)
      seg = Chrome.strip_segments(strip, PANE_LABELS, pane_index, @strip_start).find { |(_, r)| r.contains?(mx, my) }
      seg ? PANES[seg[0]] : nil
    end

    def pane_at(rect : Rect, mx : Int32, my : Int32) : Symbol?
      return nil if rect.empty? || !rect.contains?(mx, my)
      return :overview if my < rect.y + overview_h(rect)
      return nil unless card = active_card(rect)
      return strip_chip_at(rect, mx, my) if strip_rect(rect).contains?(mx, my)
      card.contains?(mx, my) ? @pane : nil
    end

    # Index of the scope-rule row clicked, or nil outside the populated list.
    def scope_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :scope)
      row_at(card.inset(1, 1), mx, my, false, @sel, @scope.rules.size)
    end

    # Index of the host-override row clicked, or nil outside the populated list. Uses the
    # SAME ov_list_inner offset render does, so the example-hint row never drifts the click.
    def ov_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :overrides)
      row_at(ov_list_inner(card.inset(1, 1)), mx, my, @ov_adding, @ov_sel, @host_overrides.entries.size)
    end

    def env_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :env)
      row_at(env_list_inner(card.inset(1, 1)), mx, my, env_row_offset?, @env_sel, @env_items.size)
    end

    # Whether the ENV list starts ONE ROW DOWN. `render_env_list` gives the first interior line
    # to EITHER sub-mode — the add/edit row or the prefix row — so both hit-tests have to ask
    # about both. Passing `@env_adding` alone made every click land on the row after the one
    # under the pointer while the prefix editor was open. One predicate, three callers (the
    # draw, `env_row_at`, `env_gauge_row`), which is the lockstep the geometry section promises.
    private def env_row_offset? : Bool
      @env_adding || @env_prefix_editing
    end

    # Shared row hit-test for the SCOPE/HOST-OVERRIDES list interiors: account for the
    # optional add-row offset and scroll_for's windowing. Mirrors render_*_list.
    # The row a click on a card's scroll gauge asks for. All three lists window from a
    # selection-derived `scroll_for`, so the answer is a selection. Same `y`/`rows` the draw
    # and `row_at` use, which is why it takes `adding` too.
    def scope_gauge_row(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :scope)
      gauge_row(card.inset(1, 1), mx, my, false, @scope.rules.size)
    end

    def ov_gauge_row(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :overrides)
      gauge_row(ov_list_inner(card.inset(1, 1)), mx, my, @ov_adding, @host_overrides.entries.size)
    end

    def env_gauge_row(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :env)
      gauge_row(env_list_inner(card.inset(1, 1)), mx, my, env_row_offset?, @env_items.size)
    end

    private def gauge_row(inner : Rect, mx : Int32, my : Int32, adding : Bool, n : Int32) : Int32?
      return nil if inner.h <= 0
      y = adding ? inner.y + 1 : inner.y
      rows = adding ? inner.h - 1 : inner.h
      return nil if rows <= 0
      Frame.scroll_gauge_row(Rect.new(inner.x, y, inner.w, rows), n, mx, my)
    end

    private def row_at(inner : Rect, mx : Int32, my : Int32, adding : Bool, sel : Int32, n : Int32) : Int32?
      return nil if inner.h <= 0 || !inner.contains?(mx, my)
      y = adding ? inner.y + 1 : inner.y
      rows = adding ? inner.h - 1 : inner.h
      i = my - y
      return nil if i < 0 || i >= rows
      idx = scroll_for(sel, n, rows) + i
      idx < n ? idx : nil
    end

    # Mouse: select a scope rule by row index (clamped to the populated list).
    def select_scope(idx : Int32) : Nil
      n = @scope.rules.size
      return if n == 0
      @sel = idx.clamp(0, n - 1)
    end

    # Mouse: select a host override by row index (clamped to the populated list).
    def select_override(idx : Int32) : Nil
      n = @host_overrides.entries.size
      return if n == 0
      @ov_sel = idx.clamp(0, n - 1)
    end

    # DESCRIPTION card outer rect (for border chrome hit-tests). Nil unless it's showing.
    def desc_card_rect(rect : Rect) : Rect?
      card_rect(rect, :desc)
    end

    # Mouse: place the description-editor cursor at a click INSIDE the card, entering INS
    # like NotesView#click_to_cursor. Selecting the sub-tab (a chip click, ↓ off the strip)
    # deliberately does NOT come through here — that lands in READ mode, so arrows navigate.
    def desc_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless card = card_rect(rect, :desc)
      enter_desc_insert!
      @desc_area.click_to_cursor(card.inset(1, 1), mx, my)
    end

    # --- PROJECT SETTINGS pane (delegated from ProjectController#handle_project_settings_key) ---
    def set_sel : Int32
      @set_sel
    end

    def settings_scope_row? : Bool
      @set_sel == SETTINGS_SCOPE_ROW
    end

    def settings_sandbox_row? : Bool
      @set_sel == SETTINGS_SANDBOX_ROW
    end

    # A toggle row (scope lens or sandbox) — space/↵ flips it; no text capture.
    def settings_toggle_row? : Bool
      @set_sel < SETTINGS_FIELD_BASE
    end

    def settings_text_row? : Bool
      return false if settings_protocol_row?
      return false if settings_auth_row?
      return false if settings_credential_row? && !settings_auth_enabled?
      return false if settings_proxy_field_disabled?
      @set_sel >= SETTINGS_FIELD_BASE
    end

    def settings_protocol_row? : Bool
      @set_sel == SETTINGS_PROTOCOL_ROW
    end

    def settings_auth_row? : Bool
      @set_sel == SETTINGS_AUTH_ROW
    end

    private def settings_credential_row? : Bool
      @set_sel == SETTINGS_USERNAME_ROW || @set_sel == SETTINGS_PASSWORD_ROW
    end

    def settings_auth_enabled? : Bool
      @set_values[SETTINGS_AUTH_INDEX] == "on"
    end

    def toggle_settings_auth : Nil
      @set_values[SETTINGS_AUTH_INDEX] = settings_auth_enabled? ? "off" : "on"
      @set_cursor = 0
      @set_preedit = ""
    end

    def cycle_settings_protocol(delta : Int32 = 1) : Nil
      choices = SETTINGS_PROTOCOL_CHOICES
      previous = @set_values[SETTINGS_PROTOCOL_INDEX]
      index = choices.index(previous) || 0
      current = choices[(index + delta) % choices.size]
      @set_values[SETTINGS_PROTOCOL_INDEX] = current
      port = @set_values[SETTINGS_PROXY_PORT_INDEX].strip
      previous_default = project_proxy_default_port(previous)
      if port.empty? || port == previous_default
        @set_values[SETTINGS_PROXY_PORT_INDEX] = project_proxy_default_port(current)
      end
      @set_cursor = 0
      @set_preedit = ""
    end

    private def project_proxy_default_port(label : String) : String
      case label
      when "HTTP"              then Settings::DEFAULT_HTTP_PROXY_PORT.to_s
      when "SOCKS5", "SOCKS5H" then Settings::DEFAULT_SOCKS_PORT.to_s
      else                          ""
      end
    end

    private def settings_proxy_field_disabled? : Bool
      return false unless @set_sel == SETTINGS_PROXY_HOST_ROW || @set_sel == SETTINGS_PROXY_PORT_ROW
      protocol = @set_values[SETTINGS_PROTOCOL_INDEX]
      protocol == "None" || protocol.starts_with?("Invalid ·")
    end

    # On row 0 → ↑ pops up to the sub-tab strip. There's no matching at_bottom? / at_cursor_start?
    # any more: the card no longer has sideways or downward exits, so both ends just clamp.
    def set_at_top? : Bool
      @set_sel <= 0
    end

    # All persisted network fields, in the same order as the rows after the two toggles.
    # Deliberately excludes the proto schema path, which has its own baseline and commit.
    def settings_values : {String, String, String, String, String, String, String, String, String, String, String, String}
      {@set_values[0].strip, @set_values[1].strip,
       @set_values[2], @set_values[3].strip, @set_values[4].strip,
       @set_values[5].strip, @set_values[6], @set_values[7], @set_values[8],
       @set_values[9].strip, @set_values[10].strip, @set_values[11].strip}
    end

    # Preserve the exact inherited/project scalar while its three-field projection is
    # untouched (including legacy host:port spelling). Once edited, serialize canonically.
    def settings_upstream_proxy : {String, String?}
      unchanged = @set_values[2] == @set_baseline[2] &&
                  @set_values[3] == @set_baseline[3] &&
                  @set_values[4] == @set_baseline[4]
      return {@set_upstream_raw, nil} if unchanged
      Settings.build_upstream_proxy(@set_values[2].downcase, @set_values[3], @set_values[4])
    end

    # The "Proto schema" field, trimmed: a `.desc` file, a directory of them, or blank for
    # the convention directory.
    def protos_value : String
      @set_values[SETTINGS_PROTOS_FIELD]?.try(&.strip) || ""
    end

    # True when the user edited the proto-schema path since it was last loaded. Its OWN
    # baseline, so a network edit does not reload descriptor sets and a path edit does not
    # rebind the proxy.
    def protos_dirty? : Bool
      protos_value != @protos_baseline
    end

    # True when the user edited a network field since it was last loaded. Diffs against the
    # LOAD-TIME baseline, NOT live effective_* — a global settings:network save or a startup
    # port-fallback mutates effective under an untouched pane, and diffing against it would
    # make `commit` (fires on every tab-leave/quit) persist that stale snapshot as a phantom
    # per-project override, silently reverting the global edit. Mirrors @desc_dirty.
    def settings_dirty? : Bool
      settings_values != @set_baseline
    end

    # Move between the pane's rows (keyboard ↑/↓ + wheel); clamps to the row range.
    def set_select(delta : Int32) : Nil
      @set_sel = (@set_sel + delta).clamp(0, SETTINGS_LABELS.size - 1)
      @set_cursor = current_set_value.size
      @set_preedit = ""
    end

    # Mouse: focus a specific settings row (clamped).
    def select_setting(idx : Int32) : Nil
      @set_sel = idx.clamp(0, SETTINGS_LABELS.size - 1)
      @set_cursor = current_set_value.size
      @set_preedit = ""
    end

    def set_input(ch : Char) : Nil
      return unless settings_text_row?
      fi = @set_sel - SETTINGS_FIELD_BASE
      v = @set_values[fi]
      c = @set_cursor.clamp(0, v.size)
      @set_values[fi] = "#{v[0, c]}#{ch}#{v[c..]}"
      @set_cursor = c + 1
      @set_preedit = ""
    end

    # ⌫: delete the char before the caret. Returns false on an at-start caret so the caller can
    # treat ⌫ as a no-op there (the text rows never auto-leave the pane, unlike the add-rows).
    def set_backspace : Bool
      return false unless settings_text_row? && @set_cursor > 0
      fi = @set_sel - SETTINGS_FIELD_BASE
      v = @set_values[fi]
      @set_values[fi] = "#{v[0, @set_cursor - 1]}#{v[@set_cursor..]}"
      @set_cursor -= 1
      true
    end

    def set_move_cursor(delta : Int32) : Nil
      return unless settings_text_row?
      @set_cursor = (@set_cursor + delta).clamp(0, @set_values[@set_sel - SETTINGS_FIELD_BASE].size)
    end

    # Re-read the NETWORK fields after an apply (Settings.project_* / effective values changed).
    #
    # Network only. Both halves of this pane commit from one entry point, network first, and
    # a full reload here silently discarded a proto-schema path the operator had typed in the
    # same visit — it rebuilt slot 6 from the OLD `Schemas.spec` and reset `@protos_baseline`
    # to match, so `protos_dirty?` read false by the time its own commit looked.
    def refresh_settings : Nil
      load_network_values
    end

    # …and the mirror image, after a proto-schema apply. A network field may be holding a
    # half-typed value that `settings_invalid(on_leave: false)` deliberately LEFT on screen for
    # the operator to correct; resetting the six here would erase it mid-correction, under a
    # toast still naming it.
    def refresh_protos : Nil
      load_protos_value
    end

    # Mouse hit-test: the settings row index under (mx,my), or nil outside the pane's rows.
    def set_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :settings)
      inner = card.inset(1, 1)
      return nil if inner.h <= 0 || !inner.contains?(mx, my)
      row = my - inner.y + settings_scroll(inner.h)
      (0 <= row < SETTINGS_LABELS.size) ? row : nil
    end

    # Mouse: place the caret in the focused network field at a click (no-op on the toggle row).
    def setting_click_to_cursor(rect : Rect, mx : Int32, my : Int32) : Nil
      return unless settings_text_row?
      return unless card = card_rect(rect, :settings)
      inner = card.inset(1, 1)
      vx = inner.x + 1 + SETTINGS_LABEL_W + 1
      @set_cursor = (mx - vx).clamp(0, @set_values[@set_sel - SETTINGS_FIELD_BASE].size)
    end

    # --- SCOPE pane (list navigation; add/edit is ScopeRuleOverlay via the controller) ---
    def scope_select(d : Int32) : Nil
      n = @scope.rules.size
      return if n == 0
      @sel = (@sel + d).clamp(0, n - 1)
    end

    # Selection on the first rule (or an empty list) → ↑ pops focus to the sub-tab strip,
    # mirroring the DESCRIPTION editor's `at_top?`.
    def scope_at_top? : Bool
      @sel <= 0
    end

    # The currently selected rule (nil when the list is empty) — seeds the edit popup.
    def selected_rule : Scope::Rule?
      @scope.rules[@sel]?
    end

    # Commit from the SCOPE popup. Returns :ok | :empty | :invalid | :dup | :failed for toasts.
    # :dup and :failed are answered separately because they send the operator to different
    # places — "you already have this rule" vs "the store refused the write, the scope is
    # unchanged". Scope#add/#update collapse both into one false, so the duplicate is settled
    # HERE (against the same rules the popup was seeded from) and whatever false survives that
    # is the store.
    def commit_scope_rule(kind : String, match_type : String, pattern : String, edit_id : Int64? = nil) : Symbol
      pattern = pattern.strip
      return :empty if pattern.empty?
      return :invalid unless Scope.valid?(match_type, pattern)
      if @scope.rules.any? { |r| r.id != edit_id && r.kind == kind && r.match_type == match_type && r.pattern == pattern }
        return :dup
      end
      ok = if id = edit_id
             @scope.update(id, kind, match_type, pattern)
           else
             @scope.add(kind, match_type, pattern)
           end
      return :failed unless ok
      # Land the highlight on the rule that was just written, the way the HOST OVERRIDES and
      # ENV add rows already do (`ov_commit`, `env_commit`). `scope_rules` is ORDER BY id, so
      # an ADD always appends: without this the selection stayed where it was and, on a list
      # taller than the card, the new rule was drawn off-screen — no sign the write landed.
      if edit_id.nil?
        @sel = @scope.rules.index { |r| r.kind == kind && r.match_type == match_type && r.pattern == pattern } || @sel
      end
      clamp_sel
      :ok
    end

    # Removes the selected rule, returning its pattern (for the Runner's toast) or nil.
    def scope_delete : String?
      rule = selected_rule
      return nil unless rule
      # `Scope#remove` now reports whether the DELETE committed. A rolled-back batch must not
      # produce a "removed scope rule: <pattern>" toast over a rule that is still gating
      # traffic; the caller turns this nil into a busy message instead.
      return nil unless @scope.remove(rule.id)
      clamp_sel
      rule.pattern
    end

    # Pull BOTH list selections back inside their (possibly externally shrunk) lists. Called
    # by the controller after Runner#apply_external_change reloaded the live Scope /
    # HostOverrides — this view renders straight out of those objects, so a peer process
    # deleting the last rule would otherwise leave the highlight past the end.
    def clamp_selections : Nil
      clamp_sel
      clamp_ov_sel
      clamp_act_sel
    end

    # Re-seed the ENV list from the process global — THE one place `@env_items` is refilled,
    # called from `reload` (tab entry) and from the external-change path once
    # `Runner#apply_external_change` has refreshed that global.
    #
    # Unlike SCOPE and HOST OVERRIDES — which this view renders straight out of one live
    # object — the ENV pane holds its own `@env_items` copy and `Env.save_project` persists it
    # WHOLESALE. So a stale copy did not merely display wrong: the next commit here wrote the
    # stale set back over the store, deleting every var the other process had added. Refreshing
    # only on tab entry left that window open for as long as the operator stayed on the tab.
    #
    # An open EDIT row names its target by INDEX, and the list that index pointed into is gone,
    # so re-anchor by the KEY the row opened on: the commit still updates that var if it
    # survived, and becomes an ADD if the peer deleted it — which is what the typed text now
    # means. Either way the operator's half-typed line is untouched, no unrelated row is
    # overwritten, and the index can no longer point past the end.
    def reload_env_vars : Nil
      @env_items = Settings.project_env_vars.dup
      clamp_env_sel
      @env_edit_idx = @env_items.index { |(k, _)| k == @env_edit_key } if @env_edit_key
    end

    # --- ACTIVITY pane (#864): a human window over the #124 event feed ------------------
    #
    # The feed records every agent mutation/send plus the failures that never rose to a
    # notification (a binding that missed, a hook that failed and passed bytes through). Until
    # now its only reader was the MCP `list_events` tool, so the audit record the log exists to
    # keep was unreadable by the person whose project it describes.
    #
    # This is a PULL surface (P8): a bounded query over the log with a filter, the way History
    # is a query over flows. It is NOT a second notification channel — the ring
    # (`notifications.cr`, 100 entries, in-memory, per open project) stays the sparse interrupt,
    # and nothing here pushes, promotes, or moves a row out of it.

    # One page. Big enough that the ordinary feed arrives whole, small enough that the first
    # paint of a busy project is not waiting on 50k rows.
    ACT_PAGE = 200
    # Ceiling on the rows this pane KEEPS. The loaded list only ever grew: `prepend_activity`
    # runs on every `data_version` poll for as long as the pane is open — and the capture-lock
    # holder moves `data_version` every 3 s on an idle project — so a session left on this card
    # while an agent worked accumulated every event that agent ever wrote, and paid for it
    # twice, because each prepend reallocates and copies the whole array on the render fiber.
    # (Measured: 2 050 events written under an open pane, 2 050 rows retained.)
    #
    # 25 pages is more scrollback than anyone reads in one sitting, and nothing is LOST by
    # trimming: `@act_next_before` moves up to the last row kept, so the dropped tail pages
    # straight back in on the next `↓`. Rows at or above the cursor are never trimmed — the
    # selected event has to stay selected — so a cursor parked deep still holds its whole list.
    ACT_MAX_ROWS = 5_000
    # Divider + wrapped message rows. The feed's messages are PROSE, not labels — a binding
    # miss explains which descriptor read what and why nothing bound — so a list that only
    # truncates would show the token and drop every word of the reason.
    ACT_DETAIL_H = 4
    # Below this the card gives every row it has to the list instead. A short pane showing two
    # events and two lines of one message is worse at both jobs than a short list.
    ACT_DETAIL_MIN_H = 8

    # Cycle order for the `s` chip, `nil` = no narrowing. These are the sources the feed
    # actually carries (every `insert_event` call site), listed with the two an operator reaches
    # for first — the agent audit trail and the silent binding failures — at the front.
    ACT_SOURCES = [nil, "agent", "config", "bindings", "rewriter", "probe", "discover", "fuzzer", "miner", "sequencer"]

    # Cycle order for the `a` chip: WHICH SURFACE acted. `nil` = every actor, including the
    # events no surface produced (a background engine's own finding).
    #
    # `FlowSource::Surface`'s tokens, in the order an operator asks about them — the human's own
    # surface first, then the AI. Not a second vocabulary: `flows.source_surface` stores the
    # same three words, so "who did this" has one answer shape across the app.
    ACT_ACTORS = [nil] + Gori::FlowSource::Surface.values.map(&.token)

    # What the ACTOR column prints. `mcp` is the protocol; `agent` is the thing that acted, and
    # on a pane whose subject is "what did the AI do to my project" the actor is the useful
    # word. Safe to diverge from the stored token here — unlike History's `src:`, this filter is
    # CYCLED rather than typed, so nobody reads a label off the screen and types it back.
    def self.act_actor_label(actor : String?) : String
      case actor
      when Gori::FlowSource::Surface::Mcp.token then "agent"
      when nil                                  then "—"
      else                                           actor
      end
    end

    # Cycle order for the `l` chip.
    ACT_LEVELS = [nil, "info", "success", "warn", "error"]

    # How many pages `refresh_activity` walks down looking for the row that heads the loaded list
    # before it gives up and reloads. One page is the ordinary tick; five is what keeps a burst
    # from an attached agent (a fuzz run writes hundreds of events between two polls) from
    # discarding a deeply paged list, without letting the render fiber chase an agent forever.
    ACT_CATCHUP_PAGES = 5

    # What a level chip actually matches. The feed carries TWO spellings of one level: every
    # producer writes "warn" except the Sequencer, whose `level.to_s` writes "warning". A chip
    # that matched its own label would hide half the warnings in the feed, and rows already
    # written cannot be respelled.
    def self.act_level_set(level : String?) : Array(String)?
      return nil unless level
      level == "warn" ? ["warn", "warning"] : [level]
    end

    # Where `↵` on an event goes. A PURE function of the row so the routing is decidable
    # without a Runner (and so the shell has exactly one rule to execute).
    #
    # The producer's declared target wins. Rows that set `goto_tab` chose it deliberately —
    # Probe's H3 notice names the Probe tab even though it also carries the flow — and the rows
    # that carry only a `flow_id` are the binding failures, where the captured response IS the
    # answer. `nil` for both, and for a `goto_tab` naming no tab this build has: an unknown
    # string must not become a Symbol that `switch_tab` then fails to find.
    record ActivityTarget, tab : Symbol? = nil, session_id : Int64? = nil, flow_id : Int64? = nil

    def self.activity_target(row : Store::EventRow) : ActivityTarget?
      if (name = row.goto_tab) && !name.empty?
        if entry = Chrome::TABS.find { |(sym, _)| sym.to_s == name }
          return ActivityTarget.new(tab: entry[0], session_id: row.goto_session_id)
        end
      end
      (fid = row.flow_id) ? ActivityTarget.new(flow_id: fid) : nil
    end

    def activity_rows : Array(Store::EventRow)
      @act_rows
    end

    def activity_selected_row : Store::EventRow?
      @act_rows[@act_sel]?
    end

    def activity_source : String?
      @act_source
    end

    def activity_level : String?
      @act_level
    end

    def activity_actor : String?
      @act_actor
    end

    def activity_filtered? : Bool
      !@act_source.nil? || !@act_level.nil? || !@act_actor.nil? || !@act_filter.value.blank?
    end

    def activity_feed_empty? : Bool
      @act_feed_empty
    end

    def activity_more? : Bool
      !@act_next_before.nil?
    end

    # Re-read page one. THE one place `@act_rows` is replaced, called on tab entry
    # (`reload`), after a filter change, and from the external-change path — `insert_event` is
    # an ordinary insert, so a peer's write moves `PRAGMA data_version` and the poll already
    # routes here.
    #
    # `@act_feed_empty` is asked SEPARATELY, and only when a filter is on and the page came back
    # empty. `@act_rows.empty?` stops meaning "nothing has happened" the moment a narrowing is
    # applied, and the two readings send the operator opposite ways: one says the log is quiet,
    # the other says the chip is hiding it. Same shape as History's `@no_flows`.
    def reload_activity(store : Store) : Nil
      page = store.events_recent(ACT_PAGE, source: @act_source,
        levels: ProjectView.act_level_set(@act_level), actor: @act_actor, query: filter_query)
      @act_rows = page.rows
      @act_next_before = page.next_before
      @act_scanned = page.window
      @act_walked = false
      @act_new_above = 0 # page one IS the head again
      @act_feed_empty = if !page.rows.empty?
                          false
                        elsif activity_filtered?
                          store.events_recent(1).rows.empty?
                        else
                          true
                        end
      resolve_activity_anchor
    end

    # Put the cursor back on the event it was on. Re-anchors by event id exactly as
    # `reload_env_vars` re-anchors an open edit row by KEY: the rows this cursor pointed into
    # are gone, and an index that is stale but still IN RANGE is the quiet failure — it selects
    # a different event and `↵` then acts on that one.
    private def resolve_activity_anchor : Nil
      if (id = @act_anchor) && (i = @act_rows.index { |r| r.id == id })
        @act_sel = i
      else
        clamp_act_sel
      end
      @act_anchor = activity_selected_row.try(&.id)
    end

    # Fold in events that arrived ABOVE the loaded set, keeping every page already paged in.
    #
    # `reload_activity` cannot serve the external-change poll: it re-reads page ONE and replaces
    # the list, so an operator who has paged 1 000 rows deep gets snapped back to 200 every time
    # anything commits — and `data_version` moves on our OWN captures too, so during live
    # capture (or with an agent attached, i.e. the exact situation this pane exists for) deep
    # paging becomes impossible and the cursor lands on a row nobody selected. The id anchor
    # protects the PREPEND case; it cannot protect against the list being truncated underneath it.
    #
    # An append-only feed makes the fix exact: the pages above the row that currently heads the
    # list are, by construction, entirely new, so finding that row is all prepending needs. Only
    # when it cannot be found at all — a clear, a retention sweep — is a full reload the honest
    # answer.
    #
    # An EMPTY list gets the same protection, and needs it more. A narrowing that matches nothing
    # in the newest window is walked back one window per `↓` (`activity_load_more`), and a reload
    # here would throw every walked window away — which it did: the capture-lock holder rewrites
    # the intercept bridge heartbeat every 3 s, so `data_version` moves on a project nobody is
    # touching and the walk was rewound to page one before a second `↓` could land. The pane then
    # promised, permanently, that it had looked no further than the newest 50k events, which is
    # the exact lie `activity_no_match_line` exists to prevent. Nothing NEW can appear below the
    # walk either — `id` is AUTOINCREMENT, so every later insert lands above the head — so the
    # walked cursor stays correct and the new matches are all in page one.
    def refresh_activity(store : Store) : Nil
      page = store.events_recent(ACT_PAGE, source: @act_source,
        levels: ProjectView.act_level_set(@act_level), actor: @act_actor, query: filter_query)
      if head = @act_rows.first?
        refresh_activity_head(store, head.id, page)
        return
      end

      # Nothing loaded. `@act_feed_empty` is the one thing that has to be re-asked either way:
      # the onboarding card is drawn off it, and a feed that has just received its first event
      # must stop claiming nothing has ever been recorded.
      @act_feed_empty = if !page.rows.empty?
                          false
                        elsif activity_filtered?
                          store.events_recent(1).rows.empty?
                        else
                          true
                        end
      # The cursor moves only when no walk is in progress. On a fresh empty list page one IS the
      # cursor, and adopting it is required — without it a feed that was empty at open would keep
      # `next_before = nil` and refuse to page past the first 200 events it ever received.
      unless @act_walked
        @act_next_before = page.next_before
        @act_scanned = page.window
      end
      return if page.rows.empty?
      @act_rows = page.rows
      resolve_activity_anchor
    end

    # Fold in everything that arrived above `head_id`, walking DOWN from the newest page until
    # the row that heads the loaded list turns up.
    #
    # One page covers an ordinary tick. The WALK exists because a single agent job writes events
    # faster than the poll runs, and the one-page version read "more than 200 arrived at once" as
    # "the list was truncated": one 500-event burst snapped a list paged 1 250 rows deep back to
    # 200 and dropped the cursor, by `clamp_act_sel`, on a row nobody had selected — during
    # exactly the burst this pane exists to show. Bounded all the same, because keeping a scroll
    # position while an agent is mid-fuzz is not worth an unbounded scan on the render fiber.
    private def refresh_activity_head(store : Store, head_id : Int64,
                                      page : Store::EventPage) : Nil
      fresh = [] of Store::EventRow
      ACT_CATCHUP_PAGES.times do |i|
        if idx = page.rows.index { |r| r.id == head_id }
          fresh.concat(page.rows[0...idx])
          return if fresh.empty? # nothing new above the head
          prepend_activity(fresh)
          return
        end
        fresh.concat(page.rows)
        break if i == ACT_CATCHUP_PAGES - 1
        break unless before = page.next_before
        page = store.events_recent(ACT_PAGE, before, source: @act_source,
          levels: ProjectView.act_level_set(@act_level), actor: @act_actor, query: filter_query)
      end
      # The head is gone (a peer's ⇧C, a retention sweep) or sits further back than the walk
      # goes. Either way page one is the only honest starting point left.
      reload_activity(store)
    end

    # Put `fresh` on top of the loaded set, and decide what the cursor does about it.
    #
    # A cursor parked mid-list keeps its EVENT, which is the whole point of the id anchor. A
    # cursor on row 0 keeps its POSITION instead, and the two are not in tension: "the newest
    # row" is a place the operator chose to sit, so following it is what they asked for, while
    # the neighbour-slide the anchor exists to prevent is what happens to a cursor that chose a
    # particular event further down. Without this the pane silently stopped being a feed — an
    # operator watching the top saw a frozen screen while hundreds of events piled up above it.
    #
    # For that parked cursor the arrivals are still ANNOUNCED. `activity_meta` renders the count
    # on the card border, because a list that is quietly no longer at the top of its own feed is
    # the same failure in a slower form.
    private def prepend_activity(fresh : Array(Store::EventRow)) : Nil
      following = @act_sel == 0
      # Read BEFORE the concat below, which grows `fresh` into the whole list — taking it
      # afterwards credited the border's "↑N new" with every row on screen (`↑8 new` over five
      # arrivals). The count is what ARRIVED, and after the concat `fresh` no longer means that.
      arrived = fresh.size
      # `fresh.concat`, not `fresh + @act_rows`: the sum allocates a THIRD array and copies
      # both halves into it, and this runs on the render fiber on every poll. `fresh` is the
      # walk's own scratch list and is dropped by its caller, so growing it in place is free.
      @act_rows = fresh.concat(@act_rows)
      if following
        @act_sel = 0
        @act_anchor = @act_rows.first.id
        @act_new_above = 0
      else
        @act_new_above += arrived
        resolve_activity_anchor
      end
      trim_activity_tail
    end

    # Drop the oldest loaded rows once the list passes `ACT_MAX_ROWS`, and move the resume
    # point up to match.
    #
    # THE cut is below the cursor, never at it: the selected row must still be selected
    # afterwards, and the rows within a `↓` of it must still be there, or trimming would do to
    # the cursor exactly what a full reload does (`ProjectController#move_subtab`'s post-mortem).
    # So a cursor parked deep in the list keeps everything above it — that growth is the
    # operator's own doing and is bounded by their scrolling; what this bounds is the growth
    # NOTHING asked for, the head-following list that the poll extends by itself.
    #
    # `@act_next_before` becomes the last row KEPT, so the tail is re-read rather than skipped,
    # and `@act_walked` goes with it: the resume point is now a hand-set place further down the
    # feed, which is precisely the state a page-one refresh must not rewind.
    #
    # `@act_scanned` is deliberately left alone. It only reaches the screen through
    # `activity_no_match_line`, which is drawn only for an EMPTY list, and every route from a
    # trimmed list (5 000+ rows) back to an empty one — a chip, the query bar, a clear, a lost
    # head — goes through `reload_activity`, which re-seeds it from a fresh page one.
    private def trim_activity_tail : Nil
      keep = {ACT_MAX_ROWS, @act_sel + 1 + ACT_PAGE}.max
      return if @act_rows.size <= keep
      @act_next_before = @act_rows[keep - 1].id
      @act_rows = @act_rows[0, keep]
      @act_walked = true
    end

    # Append the next page. Called when the cursor reaches the end of what is loaded — the page
    # can be short because the SCAN WINDOW ran out rather than the feed, so "fewer rows than
    # asked for" is not a stopping condition; `next_before` is.
    def activity_load_more(store : Store) : Bool
      return false unless before = @act_next_before
      page = store.events_recent(ACT_PAGE, before, source: @act_source,
        levels: ProjectView.act_level_set(@act_level), actor: @act_actor, query: filter_query)
      @act_rows.concat(page.rows)
      @act_next_before = page.next_before
      # The empty-state sentence promises the pane looked no further than this number, so every
      # window walked has to be counted — reporting only the first one understates the scan in
      # exactly the case the sentence was written for.
      @act_scanned += page.window
      # Past page one now, which is what stops the external-change poll rewinding the walk.
      @act_walked = true
      !page.rows.empty?
    end

    private def filter_query : String?
      @act_filter.value.blank? ? nil : @act_filter.value
    end

    def activity_select(d : Int32) : Nil
      n = @act_rows.size
      return if n == 0
      @act_sel = (@act_sel + d).clamp(0, n - 1)
      @act_anchor = activity_selected_row.try(&.id)
      settle_activity_new_above
    end

    def activity_select_at(idx : Int32) : Nil
      n = @act_rows.size
      return if n == 0
      @act_sel = idx.clamp(0, n - 1)
      @act_anchor = activity_selected_row.try(&.id)
      settle_activity_new_above
    end

    # Arriving back on the head clears the "N new" count and re-arms following. The count is a
    # note about rows the cursor has not seen; being on them again is what makes it seen, and
    # leaving it up would make the border keep reporting an absence the operator just closed.
    private def settle_activity_new_above : Nil
      @act_new_above = 0 if @act_sel == 0
    end

    # On the first row (or an empty list) → ↑ pops focus to the sub-tab strip, like the siblings.
    def activity_at_top? : Bool
      @act_sel <= 0
    end

    # True once the cursor sits on the last LOADED row — the controller's cue to page.
    def activity_at_end? : Bool
      @act_sel >= @act_rows.size - 1
    end

    # `s` / `l` cycle the chips; both reset the cursor, because the rows underneath it are about
    # to be a different set and keeping an anchor into the old one would land arbitrarily.
    def activity_cycle_source(d : Int32 = 1) : Nil
      i = ACT_SOURCES.index(@act_source) || 0
      @act_source = ACT_SOURCES[(i + d) % ACT_SOURCES.size]
      reset_activity_cursor
    end

    def activity_cycle_level(d : Int32 = 1) : Nil
      i = ACT_LEVELS.index(@act_level) || 0
      @act_level = ACT_LEVELS[(i + d) % ACT_LEVELS.size]
      reset_activity_cursor
    end

    def activity_cycle_actor(d : Int32 = 1) : Nil
      i = ACT_ACTORS.index(@act_actor) || 0
      @act_actor = ACT_ACTORS[(i + d) % ACT_ACTORS.size]
      reset_activity_cursor
    end

    def activity_clear_filters : Bool
      return false unless activity_filtered?
      @act_source = nil
      @act_level = nil
      @act_actor = nil
      @act_filter.set("")
      @act_querying = false
      reset_activity_cursor
      true
    end

    private def reset_activity_cursor : Nil
      @act_sel = 0
      @act_anchor = nil
      @act_new_above = 0
    end

    # --- ACTIVITY `/` filter bar (the OAST CALLBACKS grammar) ---
    def activity_querying? : Bool
      @act_querying
    end

    def activity_filter_field : TextField
      @act_filter
    end

    def activity_filter_start : Nil
      @act_querying = true
    end

    # ↵ keeps the query and leaves edit mode; esc clears it outright. Same contract as the
    # OAST callback filter, so `/` means one thing across the app.
    def activity_filter_commit : Nil
      @act_querying = false
      @act_filter.set_preedit("")
      reset_activity_cursor
    end

    def activity_filter_cancel : Bool
      @act_querying = false
      @act_filter.set_preedit("")
      return false if @act_filter.value.empty?
      @act_filter.set("")
      reset_activity_cursor
      true
    end

    private def clamp_act_sel : Nil
      @act_sel = @act_sel.clamp(0, {@act_rows.size - 1, 0}.max)
    end

    # --- ACTIVITY geometry. `act_list_inner` is the ONE offset source: the filter bar and the
    # detail band both eat rows off the card interior, and the draw, the row hit-test and the
    # gauge hit-test all have to agree about how many. The ENV pane's post-mortem
    # (`env_row_offset?`) is exactly this bug: two sub-modes shared a line, only the draw knew,
    # and every click landed one row off. ---

    # Whether the filter bar occupies the first interior row — THE predicate, read by the draw
    # and by both hit-tests, so the three cannot disagree (the `env_row_offset?` discipline).
    #
    # It is hidden only on a pane with nothing to filter, no filter set, AND no bar being typed
    # into. That last clause is not defensive: `/` on an empty feed used to open an edit mode
    # that was never drawn, swallowing every keystroke — including `s`/`l`/`c` — with the typed
    # text visible nowhere on screen.
    private def act_bar_shown? : Bool
      !@act_feed_empty || activity_filtered? || @act_querying
    end

    # Rows the detail band takes, or 0 when the card cannot afford it.
    private def act_detail_h(inner : Rect) : Int32
      return 0 if inner.h < ACT_DETAIL_MIN_H || @act_rows.empty?
      ACT_DETAIL_H
    end

    private def act_list_inner(inner : Rect) : Rect
      top = inner.y + (act_bar_shown? ? 1 : 0)
      h = inner.h - (act_bar_shown? ? 1 : 0) - act_detail_h(inner)
      Rect.new(inner.x, top, inner.w, {h, 0}.max)
    end

    def activity_row_at(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :activity)
      row_at(act_list_inner(card.inset(1, 1)), mx, my, false, @act_sel, @act_rows.size)
    end

    def activity_gauge_row(rect : Rect, mx : Int32, my : Int32) : Int32?
      return nil unless card = card_rect(rect, :activity)
      gauge_row(act_list_inner(card.inset(1, 1)), mx, my, false, @act_rows.size)
    end

    private def clamp_sel : Nil
      @sel = @sel.clamp(0, {@scope.rules.size - 1, 0}.max)
    end

    # --- HOST OVERRIDES pane editing (delegated from the controller) — a DISTINCT pane
    # from SCOPE; the inline row is a single "IP host" line (/etc/hosts order). ---
    def ov_adding? : Bool
      @ov_adding
    end

    def ov_select(d : Int32) : Nil
      n = @host_overrides.entries.size
      return if n == 0
      @ov_sel = (@ov_sel + d).clamp(0, n - 1)
    end

    # On the first override (or an empty list) → ↑ pops focus to the sub-tab strip.
    def ov_at_top? : Bool
      @ov_sel <= 0
    end

    def ov_add_start : Nil
      @ov_adding = true
      @ov_edit_id = nil
      @ov_input = ""
      @ov_icx = 0
      @ov_preedit = ""
    end

    # Open the add-row pre-filled from the selected override (edit-in-place), "IP host".
    def ov_edit_start : Nil
      entry = current_override
      return unless entry
      @ov_adding = true
      @ov_edit_id = entry.id
      @ov_input = "#{entry.ip} #{entry.host}"
      @ov_icx = @ov_input.size
      @ov_preedit = ""
    end

    def cancel_ov_add : Nil
      @ov_adding = false
      @ov_edit_id = nil
      @ov_input = ""
      @ov_icx = 0
      @ov_preedit = ""
    end

    def ov_input(ch : Char) : Nil
      @ov_input = "#{@ov_input[0, @ov_icx]}#{ch}#{@ov_input[@ov_icx..]}"
      @ov_icx += 1
      @ov_preedit = ""
    end

    # Backspace the add-row; false when the ROW is empty (the controller then closes it) —
    # never merely because the caret sits at 0, which discarded a typed line the operator had
    # only moved the caret inside. Same rule as `env_backspace`, which spells it out.
    def ov_backspace : Bool
      return false if @ov_input.empty?
      if @ov_icx > 0
        @ov_input = "#{@ov_input[0, @ov_icx - 1]}#{@ov_input[@ov_icx..]}"
        @ov_icx -= 1
      end
      true
    end

    def ov_move_cursor(d : Int32) : Nil
      @ov_icx = (@ov_icx + d).clamp(0, @ov_input.size)
    end

    # Commit the add/edit row. Parses "IP host" (/etc/hosts order — IP first). Returns
    # :ok | :updated | :empty | :invalid | :dup | :failed so the controller toasts.
    #
    # :ok vs :updated because this row serves BOTH actions and the one toast it had said
    # "added" after an edit. :dup vs :failed for the same reason commit_scope_rule splits
    # them: HostOverrides#add/#update collapse "that host is already mapped" and "the store
    # refused the write" into one false, and on the EDIT path the duplicate reading was
    # simply wrong — it told an operator fixing an address to "edit it (e)", which is what
    # they were already doing.
    def ov_commit : Symbol
      text = @ov_input.strip
      return :empty if text.empty?
      parsed = HostOverrides.parse_line(text)
      return :invalid unless parsed
      host, ip = parsed
      return :dup if @host_overrides.entries.any? { |e| e.id != @ov_edit_id && e.host == host }
      if id = @ov_edit_id
        return :failed unless @host_overrides.update(id, host, ip)
        cancel_ov_add
        clamp_ov_sel
        :updated
      else
        return :failed unless @host_overrides.add(host, ip)
        @ov_sel = @host_overrides.entries.size - 1 # select the new row, like ENV add
        cancel_ov_add
        clamp_ov_sel
        :ok
      end
    end

    # The selected override's host, for the delete CONFIRM to name what it is about to remove.
    # Read-only and separate from `ov_delete` because the confirm has to say the name BEFORE
    # the row is gone, and `ov_delete` can only report it after.
    def selected_override_host : String?
      current_override.try(&.host)
    end

    # Removes the selected override, returning its host (for the toast) — or nil when there
    # was nothing selected OR the delete did not COMMIT. `HostOverrides#remove` answers that
    # (its doc: "false = store busy/locked/closing") and this discarded it, so a dropped
    # write still reported "host override deleted" while the routing pin stayed live. The
    # two writes right above in `ov_commit` already check theirs.
    def ov_delete : String?
      entry = current_override
      return nil unless entry
      return nil unless @host_overrides.remove(entry.id)
      clamp_ov_sel
      entry.host
    end

    private def current_override : HostOverrides::Entry?
      @host_overrides.entries[@ov_sel]?
    end

    private def clamp_ov_sel : Nil
      @ov_sel = @ov_sel.clamp(0, {@host_overrides.entries.size - 1, 0}.max)
    end

    def env_adding? : Bool
      @env_adding
    end

    def env_prefix_editing? : Bool
      @env_prefix_editing
    end

    def env_vars : Array({String, String})
      @env_items
    end

    def env_select(d : Int32) : Nil
      n = @env_items.size
      return if n == 0
      @env_sel = (@env_sel + d).clamp(0, n - 1)
    end

    def select_env(idx : Int32) : Nil
      @env_sel = idx.clamp(0, {@env_items.size - 1, 0}.max)
    end

    def env_at_top? : Bool
      @env_sel <= 0
    end

    def env_add_start : Nil
      cancel_env_prefix_edit
      @env_adding = true
      @env_edit_idx = nil
      @env_edit_key = nil
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""
    end

    def env_edit_start : Nil
      entry = @env_items[@env_sel]?
      return unless entry
      key, val = entry
      cancel_env_prefix_edit
      @env_adding = true
      @env_edit_idx = @env_sel
      @env_edit_key = key
      @env_input = "#{key} #{val}"
      @env_icx = @env_input.size
      @env_preedit = ""
    end

    def cancel_env_add : Nil
      @env_adding = false
      @env_edit_idx = nil
      @env_edit_key = nil
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""
    end

    # --- prefix editor: a one-line field seeded with the current GLOBAL sigil.
    # Reuses the add-row input buffer (mutually exclusive with @env_adding).
    def env_prefix_edit_start : Nil
      cancel_env_add
      @env_prefix_editing = true
      @env_input = Settings.env_prefix
      @env_icx = @env_input.size
      @env_preedit = ""
    end

    def cancel_env_prefix_edit : Nil
      @env_prefix_editing = false
      @env_input = ""
      @env_icx = 0
      @env_preedit = ""
    end

    # Commit the typed prefix: :empty rejects a blank sigil (the substitution engine
    # treats an empty prefix as "disabled"), else :ok with the trimmed sigil. The
    # caller persists it to global Settings.
    def env_prefix_commit : {Symbol, String}
      text = @env_input.strip
      return {:empty, ""} if text.empty?
      cancel_env_prefix_edit
      {:ok, text}
    end

    def env_input(ch : Char) : Nil
      @env_input = "#{@env_input[0, @env_icx]}#{ch}#{@env_input[@env_icx..]}"
      @env_icx += 1
      @env_preedit = ""
    end

    # Whether the row still holds text — the callers read this to tell a ⌫ that edited the
    # line from one on an EMPTY row, which closes the row.
    #
    # The question is whether the ROW is empty, NOT whether the caret is at 0. Answering the
    # caret question threw the line away: ← to the start of a typed "TOKEN abc123" and one ⌫
    # closed the row with the text unsaved, which is the one thing a ⌫ must never do. A caret
    # already at 0 with text behind it is an ordinary no-op, and that is what `TextField`
    # (`EnvOverlay`'s field, the same editor one modal away) has always done.
    def env_backspace : Bool
      return false if @env_input.empty?
      if @env_icx > 0
        @env_input = "#{@env_input[0, @env_icx - 1]}#{@env_input[@env_icx..]}"
        @env_icx -= 1
      end
      true
    end

    def env_move_cursor(d : Int32) : Nil
      @env_icx = (@env_icx + d).clamp(0, @env_input.size)
    end

    def env_commit : Symbol
      text = @env_input.strip
      return :empty if text.empty?
      parsed = Env.parse_line(text)
      return :invalid unless parsed
      key, val = parsed
      idx = @env_edit_idx
      return :dup if @env_items.each_with_index.any? { |(k, _), i| k == key && i != idx }
      # `idx` is re-anchored by `reload_env_vars` whenever a peer shortens the list, so it is
      # in range — the bound is checked anyway rather than trusted, because the failure mode of
      # trusting it is an IndexError raised out of a keystroke.
      if idx && idx < @env_items.size
        @env_items[idx] = {key, val}
        @env_sel = idx
      else
        @env_items << {key, val}
        @env_sel = @env_items.size - 1
      end
      cancel_env_add
      clamp_env_sel
      :ok
    end

    # The selected variable's KEY, for the delete confirm to name it before it is gone. Never
    # the value: a confirm that echoed a secret would print it into a modal the operator may
    # be screen-sharing, and the key alone identifies the row.
    def selected_env_key : String?
      @env_items[@env_sel]?.try { |(key, _)| key }
    end

    def env_delete : String?
      entry = @env_items[@env_sel]?
      return nil unless entry
      key, _ = entry
      @env_items.delete_at(@env_sel)
      clamp_env_sel
      key
    end

    private def clamp_env_sel : Nil
      @env_sel = @env_sel.clamp(0, {@env_items.size - 1, 0}.max)
    end

    # Replace the description (e.g. from the external editor); marks dirty so save
    # persists it on the next tab-exit.
    def replace_desc(text : String) : Nil
      @desc_area.set_text(text)
      @desc_dirty = true
    end

    # Persist description iff edited (called on tab exit paths, like NotesView). Answers
    # whether there was nothing to do or the write COMMITTED — `set_setting` is `exec_task_ok`,
    # so that answer has always been available here and was thrown away. Clearing `@desc_dirty`
    # on a write that rolled back (project busy — another instance's writer holds the lock) is
    # what turned a transient failure into LOSS: `reload` then set the buffer from the stored
    # value on the next tab enter, so prose the operator typed was gone with nothing said. The
    # flag stays up now, so the next exit path retries, and `reload` leaves a dirty buffer
    # alone. Two siblings already read this Bool (`RewriterController#persist_sample`,
    # `DecoderController#restore_sessions`); this was the one that did not.
    def save(store : Store) : Nil
      return unless @desc_dirty
      @desc_dirty = false if store.set_setting(DESC_KEY, @desc_area.text)
    end

    # --- live description editing (delegated when Project tab body is focused) ---
    def insert(ch : Char) : Nil
      @desc_area.insert(ch)
      @desc_dirty = true
    end

    # Characters the last `insert` replaced — see TextArea#last_replaced.
    def last_replaced : Int32
      @desc_area.last_replaced
    end

    def newline : Nil
      @desc_area.insert_newline
      @desc_dirty = true
    end

    def undo : Nil
      @desc_area.undo
      @desc_dirty = true
    end

    def backspace : Nil
      @desc_area.backspace
      @desc_dirty = true
    end

    def move(dr : Int32, dc : Int32) : Nil
      @desc_area.move(dr, dc)
    end

    # Mouse wheel over the DESCRIPTION: scroll the viewport (cursor follows), so a long
    # description scrolls into view instead of staying clipped past the card edge.
    def desc_scroll(step : Int32) : Nil
      @desc_area.scroll_view(step)
    end

    def goto_line(n : Int32) : Nil
      @desc_area.goto_line(n)
    end

    def search_lines(query : String) : Array(Int32)
      @desc_area.search_lines(query)
    end

    def match_count(query : String) : Int32
      @desc_area.match_count(query)
    end

    def replace_matches(query : String, replacement : String) : Int32
      n = @desc_area.replace_matches(query, replacement)
      @desc_dirty = true if n > 0
      n
    end

    def search_hl=(q : String) : Nil
      @desc_area.search_hl = q
    end

    # Cursor on the first description line → ↑ pops focus to the sub-tab strip (after saving).
    def at_top? : Bool
      @desc_area.at_top?
    end

    # Self-framed (like Repeater/Intercept): an OVERVIEW card on top (read-only stats), then
    # the sub-tab chip strip, then the ONE card that strip selects. `focused` = the body holds
    # focus (the card lights gold); `strip_focused` = the strip does (the chips light instead)
    # — the two are mutually exclusive tiers of the shell's focus ring, so a focused strip
    # must leave the card below at rest.
    def render(screen : Screen, rect : Rect, focused : Bool = true, strip_focused : Bool = false,
               capturing : Bool = false) : Nil
      return if rect.empty?
      # Read per frame, never cached in `reload`: capture toggles while this tab sits open, and
      # a stale "capturing" on the address an operator is about to point a client at is a lie.
      @capturing = capturing
      oh = overview_h(rect)
      band = Rect.new(rect.x, rect.y, rect.w, oh)
      vw = viz_width(band.w)
      ov_rect = vw > 0 ? Rect.new(band.x, band.y, band.w - vw - 1, band.h) : band
      # The plan is derived from the BODY rect (the one `overview_h` sized the band from) and
      # handed down, not recomputed from the band: `render_overview` receives the band, whose
      # height is the ANSWER to the plan, so planning again from it decides a second, smaller
      # tier and paints one line into a nine-row box. Same draw/measure divergence `frame.cr`
      # documents for badges — one decision, passed along, is the only safe shape.
      render_overview(screen, ov_rect, overview_plan(rect))
      render_analytics(screen, Rect.new(band.right - vw, band.y, vw, band.h)) if vw > 0
      return unless card = active_card(rect)
      @strip_start = Chrome.render_tab_strip(screen, strip_rect(rect), PANE_LABELS, pane_index, strip_focused, @strip_start)
      case @pane
      when :scope     then render_scope_card(screen, card, focused)
      when :overrides then render_overrides_card(screen, card, focused)
      when :env       then render_env_card(screen, card, focused)
      when :settings  then render_settings_card(screen, card, focused)
      when :activity  then render_activity_card(screen, card, focused)
      else                 render_desc_card(screen, card, focused)
      end
    end

    # One OVERVIEW row: its label, its value, an optional value colour (nil = Theme.text), and
    # whether the value truncates from the LEFT. Paths do: the tail names the project, and
    # `Screen#fit`'s right-side ellipsis is precisely the half that identifies it.
    private record OvRow, label : String, value : String, fg : Color? = nil, elide : Bool = false

    # A semantic group of rows plus the ONE line it folds to when the band cannot afford them
    # individually. Same contract as `render_severity` → `render_severity_tally` right below:
    # a group that does not fit gets SMALLER, it never disappears. That distinction is the
    # whole point — the retired tiling layout dropped a whole pane below a height threshold
    # (see `active_card`), and a fact vanishing with no trace is the defect, not the fix.
    private record OvGroup, rows : Array(OvRow), folded : String

    # How hard the band is folding, and the exact inner row count that costs. `render_overview`
    # paints precisely `rows` rows, so no fact is ever left to a `break` to discard.
    private record OvPlan, level : Symbol, rows : Int32, two_col : Bool, signpost : Bool

    # The band's layout decision, made ONCE and read by both `overview_h` (which sizes the
    # band, and through it everything below) and `render_overview` (which paints it).
    #
    # Four fold levels, largest that fits wins:
    #   :expanded — every group prints its own label:value rows (2 columns when wide enough)
    #   :compact  — every group prints its folded one-liner            (one row per group)
    #   :paired   — the three highest-priority groups, folded (see `ov_paired_lines`)
    #   :single   — identity + the counts, budgeted to the width (see `ov_single_line`)
    #
    # `:expanded` and `:compact` carry every group; the two below them do not, and drop by an
    # explicit priority order rather than by whatever row the band ran out on.
    private def overview_plan(rect : Rect) : OvPlan
      signpost = @flow_count == 0
      avail = overview_budget(rect) - (signpost ? 1 : 0)
      two_col = overview_inner_w(rect) >= OVERVIEW_2COL_MIN_W
      # Both branches go through the SAME height functions the renderers use, so the band can
      # never be sized for one arrangement and painted with another.
      expanded = two_col ? ov_two_col_rows : overview_row_count
      return OvPlan.new(:expanded, expanded, two_col, signpost) if avail >= expanded
      return OvPlan.new(:compact, OV_GROUPS, false, signpost) if avail >= OV_GROUPS
      return OvPlan.new(:paired, 3, false, signpost) if avail >= 3
      OvPlan.new(:single, 1, false, signpost)
    end

    # `overview_groups` count, fixed: identity, proxy, volume, provenance, tech.
    OV_GROUPS = 5

    private def overview_row_count : Int32
      ov_group_sizes.sum + 1 # + the full-width Tech row
    end

    # Row counts of every group but Tech, which always spans.
    #
    # DERIVED from `overview_groups`, deliberately, rather than restated as a literal
    # `[ident, 1, 4, 2]`. That literal was a second definition of the band's shape running
    # beside the real one: they agreed on the day they were written, and the day they stopped
    # agreeing the band would be sized SHORT and `draw_ov_column`'s bounds `break` would resume
    # silently dropping rows — the precise defect this whole arrangement exists to remove,
    # reintroduced through a parallel-definition seam. Same trap as the Scope SQL/in-memory
    # pair. Building the groups costs a handful of small strings and is not on a hot path
    # (the TUI repaints on demand, and hit-tests are mouse-rate).
    private def ov_group_sizes : Array(Int32)
      overview_groups[0..-2].map(&.rows.size)
    end

    # How many LEADING groups go in the left column. Splitting on a group boundary rather than
    # a flat row index is what keeps a group whole: a mid-group cut left "Flows" alone at the
    # foot of one column with Captured/Issues/DB Size in the other, reading as two unrelated
    # lists. Greedy on the running height, which is optimal for this fixed set of sizes.
    private def ov_split_at(sizes : Array(Int32)) : Int32
      half = (sizes.sum + 1) // 2
      run = 0
      sizes.each_with_index do |n, i|
        return i if i > 0 && run + n > half
        run += n
      end
      sizes.size
    end

    # Rows the two-column arrangement occupies: the taller column, plus Tech's own row.
    private def ov_two_col_rows : Int32
      sizes = ov_group_sizes
      at = ov_split_at(sizes)
      {sizes[0, at].sum, sizes[at..].sum}.max + 1
    end

    # The groups, in display order. Ordered so the first row of the band is still the project
    # name, as it has always been.
    private def overview_groups : Array(OvGroup)
      # Deliberately built even with no project yet (the state before the first `reload`). The
      # band's SHAPE has to be constant or `overview_h` shrinks on the first frame and everything
      # below it jumps a row when the values arrive; only the VALUES are allowed to be unknown.
      p = @project
      id = @proj_id
      ws = @workspace
      ident = [OvRow.new("Name", p.try(&.name) || "—"),
               OvRow.new("Path", p.try(&.dir) || "—", elide: true)]
      # Registry sidecar facts. A `--db PATH` project borrows an arbitrary parent directory, so
      # these would describe whatever ELSE lives there — a confidently wrong identifier is worse
      # than none, so `reload` leaves them nil off the registry and the rows aren't offered.
      ident << OvRow.new("ID", id) if id
      ident << OvRow.new("Workspace", ws, elide: true) if ws
      [
        OvGroup.new(ident, fold_identity),
        OvGroup.new([OvRow.new("Proxy", proxy_value, proxy_color)], proxy_value),
        OvGroup.new([
          OvRow.new("Flows", @flow_count.to_s),
          OvRow.new("Captured", human_size(@total_captured)),
          OvRow.new("Issues", issues_value),
          OvRow.new("DB Size", human_size(@db_size)),
        ], fold_volume),
        OvGroup.new([
          OvRow.new("Created", created_value),
          OvRow.new("Activity", activity_value),
        ], fold_provenance),
        OvGroup.new([OvRow.new("Technologies", tech_value)], "tech #{tech_value}"),
      ]
    end

    # A folded line has no label column, so it has to read as a sentence on its own — which is
    # why the unit words are here and not only in the `label:value` rows.
    private def fold_volume : String
      flows = @flow_count == 1 ? "1 flow" : "#{Fmt.count(@flow_count)} flows"
      "#{flows} · #{human_size(@total_captured)} · #{issues_value} issues"
    end

    private def fold_identity : String
      p = @project
      parts = [p.try(&.name) || "—"]
      @proj_id.try { |id| parts << id }
      parts << "ephemeral" if p && p.ephemeral?
      parts.join(" · ")
    end

    private def fold_provenance : String
      c = (t = @created) ? "created #{Fmt.ago(t)} ago" : "created —"
      (a = @last_activity) ? "#{c} · active #{Fmt.ago(a)} ago" : c
    end

    # The address an operator points a client at, plus whether the proxy is actually on it.
    # Mirrors the top bar's listen chip (`Chrome.listen_chip`) so the two never disagree.
    private def proxy_value : String
      addr = BindAddress.display(Settings.effective_bind_host, Settings.effective_bind_port)
      "#{addr} #{@capturing ? "● capturing" : "‖ paused"}"
    end

    private def proxy_color : Color
      @capturing ? Theme.green : Theme.muted
    end

    # Human-confirmed issues, with unreviewed Probe hits alongside. `reload`'s comment keeps
    # Probe OUT of the AT A GLANCE severity chart on purpose, and that still holds — this is a
    # COUNT, not a severity breakdown, and "how much is waiting to be triaged" is a question
    # the project's own home page should answer. The chart beside it is still `issues` only.
    private def issues_value : String
      @probe_count > 0 ? "#{@issues_count} · probe #{@probe_count}" : @issues_count.to_s
    end

    private def activity_value : String
      (t = @last_activity) ? "#{Fmt.ago(t)} ago" : "—"
    end

    private def created_value : String
      c = @created
      return "—" unless c
      "#{format_time(c)} (#{Fmt.ago(c)} ago)"
    end

    private def tech_value : String
      @probe_tech.empty? ? "—" : @probe_tech.join(", ")
    end

    private def render_overview(screen : Screen, rect : Rect, plan : OvPlan) : Nil
      return if rect.h < 2 || rect.w < 2
      Frame.card(screen, rect, nil, bg: Theme.bg, border: Theme.border)
      p = @project
      return unless p
      inner = rect.inset(1, 1)
      return if inner.h <= 0 || inner.w <= 0
      y = inner.y

      # First run (no flows yet): a one-line signpost on how to start, since the empty
      # History/Sitemap tabs don't say. Costs a row, and `overview_plan` already charged it.
      if plan.signpost
        screen.text(inner.x + 1, y,
          Hotkeys.retag("▸ first run — point your client at the proxy · ^P: Open browser · Export CA certificate"),
          Theme.muted, width: {inner.right - inner.x - 1, 0}.max)
        y += 1
      end

      groups = overview_groups
      case plan.level
      when :expanded then plan.two_col ? draw_ov_two_col(screen, inner, y, groups) : draw_ov_rows(screen, inner, y, groups)
      when :compact  then draw_ov_lines(screen, inner, y, groups.map(&.folded))
      when :paired   then draw_ov_lines(screen, inner, y, ov_paired_lines(groups))
      else                draw_ov_lines(screen, inner, y, [ov_single_line(screen, groups, ov_line_w(inner))])
      end
    end

    # `:paired` — three rows. The two tiers below `:compact` are the only ones that do not carry
    # every group, and they drop by an EXPLICIT priority order rather than leaving it to a
    # `break` at whatever row the band happened to end on (which is the defect this whole
    # arrangement replaces). Same discipline as History's column cluster, which sheds
    # TYPE/SIZE/DUR right-to-left once HOST+PATH have their reserved width.
    #
    # Deliberately NOT concatenated: joining two folded lines produced a string longer than a
    # one-column band, so `width:` ellipsized it and the second half vanished anyway — a
    # lossless-looking fold that lost more than an honest drop would.
    private def ov_paired_lines(groups : Array(OvGroup)) : Array(String)
      # identity, volume, proxy — who this is, what it holds, where it listens.
      [groups[0], groups[2], groups[1]].map(&.folded)
    end

    # `:single` — one row, built against the width it has to fit in.
    #
    # The counts are short and bounded; the project NAME is neither. Concatenating them and
    # letting `width:` ellipsize the result means a long name pushes the numbers off the end,
    # leaving a line that looks complete and answers nothing. So the name is what absorbs the
    # squeeze: it is reserved LAST and elided to the room left over, and it is also the one fact
    # still readable from the tab title and the project picker.
    private def ov_single_line(screen : Screen, groups : Array(OvGroup), w : Int32) : String
      vol = groups[2].folded
      name = groups[0].folded
      room = w - Screen.display_width(vol) - 3 # " · "
      return vol if room < 4
      # `screen.fit` rather than a local right-elide: it is the house truncation primitive and
      # already walks graphemes with a bounded scan.
      "#{screen.fit(name, room)} · #{vol}"
    end

    # One label:value column, `x0` for the labels and `label_w` reserving the value column.
    private def draw_ov_column(screen : Screen, inner : Rect, y0 : Int32, rows : Array(OvRow),
                               x0 : Int32, label_w : Int32, right : Int32) : Nil
      vx = x0 + label_w
      vw = {right - vx, 0}.max
      rows.each_with_index do |row, i|
        y = y0 + i
        break if y >= inner.bottom
        screen.text(x0, y, row.label + ":", Theme.text_bright, width: {label_w - 1, 0}.max)
        next unless vw > 0
        value = row.elide ? elide_left(row.value, vw) : row.value
        screen.text(vx, y, value, row.fg || Theme.text, width: vw)
      end
    end

    # Drop leading GRAPHEMES until the value fits, marking the cut with a leading ellipsis —
    # the mirror of `Screen#fit`, which is why it walks graphemes rather than chars: macOS
    # stores filenames NFD, so a directory named `café` is `e` + U+0301 and a cut between them
    # would orphan the combining mark onto the ellipsis. Measured in DISPLAY COLUMNS too, so a
    # path with a CJK component cannot paint through the column it was budgeted for.
    private def elide_left(s : String, w : Int32) : String
      return s if w <= 1 || Screen.display_width(s) <= w
      gs = s.each_grapheme.map(&.to_s).to_a
      width = gs.sum { |g| Screen.grapheme_cols(g) }
      while !gs.empty? && width > w - 1
        width -= Screen.grapheme_cols(gs.shift)
      end
      "…#{gs.join}"
    end

    OV_LABEL_W = 14 # value column starts past the widest label ("Technologies")

    private def draw_ov_rows(screen : Screen, inner : Rect, y0 : Int32, groups : Array(OvGroup)) : Nil
      draw_ov_column(screen, inner, y0, groups.flat_map(&.rows), inner.x + 1, OV_LABEL_W, inner.right)
    end

    # Two columns of label:value, with the last row (Technologies) spanning the full width —
    # it is the longest and most variable value, so a half-width cell truncates it first.
    private def draw_ov_two_col(screen : Screen, inner : Rect, y0 : Int32, groups : Array(OvGroup)) : Nil
      body = groups[0..-2] # every group but Tech, which spans below both columns
      at = ov_split_at(body.map(&.rows.size))
      left = body[0, at].flat_map(&.rows)
      right = body[at..].flat_map(&.rows)
      col_w = {(inner.w - 2) // 2, 1}.max
      draw_ov_column(screen, inner, y0, left, inner.x + 1, OV_LABEL_W, inner.x + 1 + col_w)
      draw_ov_column(screen, inner, y0, right, inner.x + 1 + col_w + 1, OV_LABEL_W, inner.right)
      # Tech sits under the TALLER column — the same height `ov_two_col_rows` charged the band.
      draw_ov_column(screen, inner, y0 + {left.size, right.size}.max, groups.last.rows,
        inner.x + 1, OV_LABEL_W, inner.right)
    end

    # Width one folded line gets. ONE expression, so a line built against a budget (see
    # `ov_single_line`) and the `width:` that finally clips it cannot disagree.
    private def ov_line_w(inner : Rect) : Int32
      {inner.right - inner.x - 1, 0}.max
    end

    # Folded group lines, one per row. Muted like every other collapsed tally in the tree.
    private def draw_ov_lines(screen : Screen, inner : Rect, y0 : Int32, lines : Array(String)) : Nil
      w = ov_line_w(inner)
      lines.each_with_index do |line, i|
        y = y0 + i
        break if y >= inner.bottom
        screen.text(inner.x + 1, y, line, i == 0 ? Theme.text_bright : Theme.text, width: w)
      end
    end

    # AT A GLANCE viz pane riding the right of the OVERVIEW band (read-only, like OVERVIEW
    # — no focus/keys). Two stacked micro-charts an analyst wants without leaving the tab:
    # the captured traffic's HTTP status mix, then the Issues severity breakdown (not Probe).
    # Degrades top-down by height (mirrors the Fuzzer DIST pane).
    private def render_analytics(screen : Screen, rect : Rect) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "AT A GLANCE", bg: Theme.bg, border: Theme.border)
      inner = rect.inset(1, 1)
      return if inner.empty?

      groups = status_class_groups
      sevs = severity_rows
      if groups.empty? && sevs.empty?
        screen.text(inner.x, inner.y, "no data yet", Theme.muted, width: inner.w)
        return
      end

      y = render_bar_section(screen, inner, inner.y, groups)
      return if sevs.empty? || y >= inner.bottom
      y += 1 if !groups.empty? && y < inner.bottom - 1 # spacer between sections when there's room
      render_severity(screen, inner, y, sevs)
    end

    # Collapse @status_counts into ordered {label, count, sample_status} rows: 1xx..5xx
    # classes plus a PEND row for still-pending (nil-status) flows. sample_status feeds
    # Theme.status_color (PEND → nil → muted). Only nonzero classes are kept.
    private def status_class_groups : Array({String, Int64, Int32?})
      cls = StaticArray(Int64, 6).new(0_i64) # 0 = pending, 1..5 = 1xx..5xx
      @status_counts.each do |(st, cnt)|
        if st.nil? || st == 0
          cls[0] += cnt
        else
          k = st // 100
          cls[k] += cnt if 1 <= k < 6
        end
      end
      out = [] of {String, Int64, Int32?}
      (1..5).each do |k|
        out << {"#{k}xx", cls[k], (k * 100).as(Int32?)} if cls[k] > 0
      end
      out << {"PEND", cls[0], nil.as(Int32?)} if cls[0] > 0
      out
    end

    # Severity rows (Critical first) with nonzero counts, from the Issues table only.
    # The Int value feeds Theme.severity_color.
    private def severity_rows : Array({String, Int64, Int32})
      labels = { {4, "CRIT"}, {3, "HIGH"}, {2, "MED"}, {1, "LOW"}, {0, "INFO"} }
      out = [] of {String, Int64, Int32}
      labels.each do |(val, lab)|
        n = @sev_tally[val]
        out << {lab, n, val} if n > 0
      end
      out
    end

    # Draw status-class bars top-down, each colored by its class. Returns the next free y.
    private def render_bar_section(screen : Screen, inner : Rect, y0 : Int32,
                                   groups : Array({String, Int64, Int32?})) : Int32
      return y0 if groups.empty?
      maxc = groups.max_of { |(_, c, _)| c }
      y = y0
      groups.each do |(label, count, code)|
        break if y >= inner.bottom
        render_bar_row(screen, inner, y, label, count, maxc, Theme.status_color(code))
        y += 1
      end
      y
    end

    # Severity section: full colored bars when every row fits, else a compact one-line
    # tally so nothing is silently dropped on a short pane.
    private def render_severity(screen : Screen, inner : Rect, y0 : Int32,
                                rows : Array({String, Int64, Int32})) : Nil
      avail = inner.bottom - y0
      return if avail <= 0
      if avail >= rows.size
        maxc = rows.max_of { |(_, c, _)| c }
        rows.each_with_index do |(label, count, val), i|
          render_bar_row(screen, inner, y0 + i, label, count, maxc, Theme.severity_color(val))
        end
      else
        render_severity_tally(screen, inner, y0, rows)
      end
    end

    # One "LABEL ███░  42" row: label, a Spark.bar scaled to `maxc`, right-aligned count.
    private def render_bar_row(screen : Screen, inner : Rect, y : Int32, label : String,
                               count : Int64, maxc : Int64, color : Color) : Nil
      label_w = 5 # "CRIT " / "PEND " / "2xx  "
      num = Fmt.count(count)
      num_w = num.size
      bar_w = {inner.w - label_w - num_w - 1, 1}.max
      screen.text(inner.x, y, label.ljust(label_w), color, Theme.bg)
      screen.text(inner.x + label_w, y, Spark.bar(count, maxc, bar_w), color, Theme.bg)
      screen.text(inner.x + label_w + bar_w + 1, y, num.rjust(num_w), Theme.muted, Theme.bg, width: num_w)
    end

    # Compact one-line colored severity tally ("C3 H12 M28 L9 I2") for when full bars
    # won't fit — each chip tinted by its severity.
    private def render_severity_tally(screen : Screen, inner : Rect, y : Int32,
                                      rows : Array({String, Int64, Int32})) : Nil
      x = inner.x
      rows.each do |(label, count, val)|
        break if x >= inner.right
        x = screen.text(x, y, "#{label[0]}#{Fmt.count(count)}", Theme.severity_color(val), Theme.bg)
        x = screen.text(x, y, " ", Theme.muted, Theme.bg)
      end
    end

    # SCOPE card: title + the lens state riding the top border (right), then the rule
    # list / inline add-row inside.
    private def render_scope_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "SCOPE", bg: Theme.bg, border: Frame.pane_border(focused))
      n = @scope.rules.size
      # An ACTIVE lens is the one card meta that shouts — it changes what every other tab
      # shows — so this one passes its own fg rather than taking `border_meta`'s muted default.
      Frame.border_meta(screen, rect, "SCOPE", "lens:#{@scope.enabled? ? "on" : "off"} · #{n}",
        fg: @scope.active? ? Theme.text_bright : Theme.muted)
      render_scope_list(screen, rect.inset(1, 1), focused)
    end

    # The rule list (windowed around the selection) inside the SCOPE card interior.
    private def render_scope_list(screen : Screen, inner : Rect, focused : Bool) : Nil
      return if inner.h <= 0 || inner.w <= 0
      rules = @scope.rules
      y = inner.y
      rows = inner.h
      return if rows <= 0

      if rules.empty?
        TrafficEmptyState.render(screen, inner, variant: :project_scope)
        return
      end

      scroll = scroll_for(@sel, rules.size, rows)
      shown = {rows, rules.size - scroll}.min
      shown.times do |i|
        idx = scroll + i
        rule = rules[idx]
        ry = y + i
        # The selection SURVIVES a focus change, dimmed — every other list in gori does this
        # (`Theme.selection_dim`, see RewriterView/ProbeRulesView/DiscoverView…). These three
        # project cards were the only ones that gated the whole marker on `focused`, so moving
        # focus to a sibling card erased any sign of where you were in this one, and coming
        # back meant finding your row again by eye.
        selected = idx == @sel
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        screen.fill(Rect.new(inner.x, ry, inner.w, 1), bg) if selected
        # The marker column is written on EVERY row (a space when unselected), the way every
        # other list writes it — so the column is owned here rather than left to whatever was
        # on the canvas underneath.
        screen.cell(inner.x, ry, selected ? '▎' : ' ', Theme.accent, bg)
        render_rule_row(screen, inner, ry, rule, selected, bg)
      end
      Frame.scroll_gauge(screen, Rect.new(inner.x, y, inner.w, rows), rules.size, scroll, focused)
    end

    private def render_rule_row(screen : Screen, inner : Rect, y : Int32, rule : Scope::Rule, selected : Bool, bg : Color) : Nil
      fg = selected ? Theme.text_bright : Theme.text
      ktag, kcolor = rule.include? ? {"incl", Theme.accent} : {"excl", Theme.yellow}
      x = inner.x + 1
      screen.text(x, y, ktag, kcolor, bg, Attribute::Bold)
      screen.text(x + 5, y, rule.match_type, Theme.muted, bg)
      px = x + 12
      screen.text(px, y, rule.pattern, fg, bg, width: {inner.right - px, 1}.max) if inner.right > px
    end

    # HOST OVERRIDES card: title + count chip riding the top border, then the entry list
    # / inline add-row inside. A DISTINCT pane from SCOPE (own card, focus, action menu).
    private def render_overrides_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "HOST OVERRIDES", bg: Theme.bg, border: Frame.pane_border(focused))
      n = @host_overrides.size
      # `project`, against Settings' near-identically titled HOSTNAME OVERRIDES — these are
      # layered OVER those, and a bare count said nothing about which list you are editing.
      Frame.border_meta(screen, rect, "HOST OVERRIDES", "project · #{n}",
        fg: n > 0 ? Theme.text_bright : Theme.muted)
      render_overrides_list(screen, rect.inset(1, 1), focused)
    end

    # The override list (windowed around the selection) + the inline add/edit row, drawn
    # inside the HOST OVERRIDES card's interior `inner`. Mirrors render_scope_list, but with
    # a persistent format-example header on the first row (parity with the settings editor).
    private def render_overrides_list(screen : Screen, inner : Rect, focused : Bool) : Nil
      return if inner.h <= 0 || inner.w <= 0
      # Nothing mapped yet, and not mid-add: the shared onboarding card owns the whole
      # interior — the format hint below only makes sense once there is a row to read it
      # against, and it reappears the moment `a` opens the add-row.
      if @host_overrides.entries.empty? && !@ov_adding
        TrafficEmptyState.render(screen, inner, variant: :project_overrides)
        return
      end
      # Always-visible format example so the "IP HOSTNAME" entry shape is clear at a glance
      # (IP first so it survives truncation in a narrow pane).
      screen.text(inner.x, inner.y, "IP HOSTNAME · e.g. 10.0.0.1 example.com", Theme.muted, width: inner.w)
      list = ov_list_inner(inner)
      return if list.h <= 0

      entries = @host_overrides.entries
      y = list.y
      rows = list.h
      if @ov_adding
        render_ov_add_row(screen, list, y, focused)
        y += 1
        rows -= 1
      end
      return if rows <= 0

      # Empty here means the add-row is open on a fresh pane (the onboarding card handled the
      # standing-empty case up top): nothing to window, so skip the list and gauge.
      return if entries.empty?

      scroll = scroll_for(@ov_sel, entries.size, rows)
      shown = {rows, entries.size - scroll}.min
      shown.times do |i|
        idx = scroll + i
        entry = entries[idx]
        ry = y + i
        # Dimmed rather than erased when focus leaves — see the SCOPE list above. `@ov_adding`
        # still clears it outright: while the add-row is open there is no selected ENTRY.
        selected = idx == @ov_sel && !@ov_adding
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        screen.fill(Rect.new(list.x, ry, list.w, 1), bg) if selected
        screen.cell(list.x, ry, selected ? '▎' : ' ', Theme.accent, bg)
        render_ov_row(screen, list, ry, entry, selected, bg)
      end
      # `y`/`rows` are already past the add-row when one is open, so the gauge measures the
      # entries actually windowed rather than the card interior.
      Frame.scroll_gauge(screen, Rect.new(list.x, y, list.w, rows), entries.size, scroll, focused)
    end

    # The HOST OVERRIDES list area: the card interior minus the top example-hint row. ONE
    # source of truth so render_overrides_list + ov_row_at share the exact same geometry.
    private def ov_list_inner(inner : Rect) : Rect
      Rect.new(inner.x, inner.y + 1, inner.w, {inner.h - 1, 0}.max)
    end

    private def render_ov_row(screen : Screen, inner : Rect, y : Int32, entry : HostOverrides::Entry, selected : Bool, bg : Color) : Nil
      fg = selected ? Theme.text_bright : Theme.text
      x = inner.x + 1
      # IP column (accent) padded to ~40% of the pane, then "→ host" with the remainder.
      ipw = {inner.w * 2 // 5, 7}.max
      screen.text(x, y, entry.ip, Theme.accent, bg, width: ipw)
      ax = x + ipw
      screen.text(ax, y, "→ ", Theme.muted, bg) if inner.right > ax
      hx = ax + 2
      screen.text(hx, y, entry.host, fg, bg, width: {inner.right - hx, 1}.max) if inner.right > hx
    end

    # The inline "add"/"edit" row: a single "IP host" input (no chips — unlike SCOPE).
    private def render_ov_add_row(screen : Screen, inner : Rect, y : Int32, focused : Bool) : Nil
      x = inner.x + 1
      x = screen.text(x, y, @ov_edit_id ? "edit " : "add ", Theme.accent, Theme.bg)
      w = {inner.right - x, 3}.max
      screen.input_line(x, y, @ov_input, @ov_icx, @ov_preedit, Theme.text_bright, Theme.bg, width: w)
    end

    private def render_env_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "ENVIRONMENT", bg: Theme.bg, border: Frame.pane_border(focused))
      n = @env_items.size
      # `project`, against the identically-titled GLOBAL card in Settings → Env that these
      # vars are layered OVER. See `EnvOverlay#render`.
      Frame.border_meta(screen, rect, "ENVIRONMENT", "project · prefix #{Settings.env_prefix} · #{n}")
      render_env_list(screen, rect.inset(1, 1), focused)
    end

    private def render_env_list(screen : Screen, inner : Rect, focused : Bool) : Nil
      return if inner.h <= 0 || inner.w <= 0
      # Nothing set yet, and not mid add/prefix-edit: the onboarding card owns the interior.
      # The format hint and the input row return together the instant either editor opens.
      if @env_items.empty? && !env_row_offset?
        TrafficEmptyState.render(screen, inner, variant: :project_env)
        return
      end
      screen.text(inner.x, inner.y, "KEY VALUE · e.g. HOST api.example.com", Theme.muted, width: inner.w)
      list = env_list_inner(inner)
      return if list.h <= 0
      y = list.y
      rows = list.h
      if env_row_offset?
        # The two sub-modes are mutually exclusive and share this line; `env_row_offset?` is
        # what both hit-tests ask, so the offset cannot drift from the draw.
        @env_prefix_editing ? render_env_prefix_row(screen, list, y) : render_env_add_row(screen, list, y, focused)
        y += 1
        rows -= 1
      end
      return if rows <= 0
      # Empty here means an add/prefix row is open on a fresh pane (the onboarding card
      # handled the standing-empty case up top): nothing to window.
      return if @env_items.empty?
      scroll = scroll_for(@env_sel, @env_items.size, rows)
      shown = {rows, @env_items.size - scroll}.min
      shown.times do |i|
        idx = scroll + i
        key, val = @env_items[idx]
        ry = y + i
        # Dimmed rather than erased when focus leaves — see the SCOPE list above.
        selected = idx == @env_sel && !@env_adding
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        screen.fill(Rect.new(list.x, ry, list.w, 1), bg) if selected
        screen.cell(list.x, ry, selected ? '▎' : ' ', Theme.accent, bg)
        render_env_row(screen, list, ry, key, val, selected, bg)
      end
      Frame.scroll_gauge(screen, Rect.new(list.x, y, list.w, rows), @env_items.size, scroll, focused)
    end

    private def env_list_inner(inner : Rect) : Rect
      Rect.new(inner.x, inner.y + 1, inner.w, {inner.h - 1, 0}.max)
    end

    private def render_env_row(screen : Screen, inner : Rect, y : Int32, key : String, val : String, selected : Bool, bg : Color) : Nil
      x = inner.x + 1
      kw = {inner.w * 2 // 5, 7}.max
      screen.text(x, y, key, Theme.syn_header, bg, width: kw)
      ax = x + kw
      screen.text(ax, y, "→ ", Theme.muted, bg) if inner.right > ax
      vx = ax + 2
      if inner.right > vx
        line = Highlight.env_line(val, selected ? Theme.text_bright : Theme.text)
        Highlight.draw(screen, vx, y, line, width: {inner.right - vx, 1}.max)
      end
    end

    private def render_env_add_row(screen : Screen, inner : Rect, y : Int32, _focused : Bool) : Nil
      x = inner.x + 1
      x = screen.text(x, y, @env_edit_idx ? "edit " : "add ", Theme.accent, Theme.bg)
      w = {inner.right - x, 3}.max
      screen.input_line(x, y, @env_input, @env_icx, @env_preedit, Theme.text_bright, Theme.bg, width: w)
    end

    private def render_env_prefix_row(screen : Screen, inner : Rect, y : Int32) : Nil
      x = inner.x + 1
      x = screen.text(x, y, "prefix ", Theme.accent, Theme.bg)
      w = {inner.right - x, 3}.max
      screen.input_line(x, y, @env_input, @env_icx, @env_preedit, Theme.text_bright, Theme.bg, width: w)
    end

    private def render_desc_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      ins = focused && desc_insert_mode?
      border = Frame.pane_border(focused)
      Frame.card(screen, rect, "DESCRIPTION", bg: Theme.bg, border: border)
      # The REAL mode, always drawn — `Frame.mode_badge`'s contract. `project_controller`
      # hit-tests the bare `desc_insert_mode?`, so gating the draw on focus left a live
      # target on a border with nothing on it. Focus is carried by the border colour above.
      Frame.mode_badge(screen, rect.right - 1, rect.y, rect.x + 14, desc_insert_mode?)
      inner = rect.inset(1, 1)
      # Nothing written yet: the shared onboarding card instead of the void an empty TextArea
      # paints. Not in INSERT — the operator came here to type, and a "no description yet"
      # sitting under the caret reads as text they just deleted.
      #
      # `paint_desc_read_chrome` is gated on the SAME condition, not merely on focus: on an
      # empty buffer its only ink is one caret cell at the interior top-left, which would sit
      # on the card as a stray inverted block.
      if desc_empty_state?
        TrafficEmptyState.render(screen, inner, variant: :project_desc)
        return
      end
      @desc_area.render(screen, inner, cursor: ins,
        highlight: Settings.editor_markdown ? :markdown : nil, gauge: true, gauge_focused: focused)
      paint_desc_read_chrome(screen, inner, focused && !ins)
    end

    # THE one predicate for "draw the onboarding card, not the editor" — both the card and the
    # suppressed read-chrome read it, so the two cannot disagree about which is showing.
    private def desc_empty_state? : Bool
      @desc_area.text.empty? && !desc_insert_mode?
    end

    # The shared over-paint — see `TextReadState#paint_chrome`, which carries the reasoning
    # (including the `sync_from` that keeps `^E`'s external editor shrinking the description
    # under a stale read cursor from taking the render down).
    private def paint_desc_read_chrome(screen : Screen, rect : Rect, active : Bool) : Nil
      @desc_read.paint_chrome(screen, rect, @desc_area, active)
    end

    # PROJECT SETTINGS card: policy toggles plus project network, proxy-auth, and protobuf
    # fields. It is windowed so keyboard and pointer hit-tests can keep every selected row
    # visible. Network rows show their project/global source; the schema row shows what loaded.
    private def render_settings_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "PROJECT SETTINGS", bg: Theme.bg, border: Frame.pane_border(focused))
      inner = rect.inset(1, 1)
      return if inner.h <= 0 || inner.w <= 0
      # Scrolled, not clipped: every selected row remains visible on a short terminal.
      start = settings_scroll(inner.h)
      inner.h.times do |row|
        i = start + row
        break if i >= SETTINGS_LABELS.size
        render_settings_row(screen, inner, inner.y + row, i, SETTINGS_LABELS[i], focused && @set_sel == i)
      end
      Frame.scroll_gauge(screen, inner, SETTINGS_LABELS.size, start, focused, Theme.bg)
    end

    # Rows scrolled off the TOP of the settings card, so render and hit-test agree.
    private def settings_scroll(h : Int32) : Int32
      scroll_for(@set_sel, SETTINGS_LABELS.size, h)
    end

    private def render_settings_row(screen : Screen, inner : Rect, y : Int32, i : Int32,
                                    label : String, selected : Bool) : Nil
      bg = selected ? Theme.accent_bg : Theme.bg
      if selected
        screen.fill(Rect.new(inner.x, y, inner.w, 1), bg)
        screen.cell(inner.x, y, '▎', Theme.accent, bg)
      end
      lx = inner.x + 1
      screen.text(lx, y, label, selected ? Theme.text_bright : Theme.text, bg, width: SETTINGS_LABEL_W)
      vx = lx + SETTINGS_LABEL_W + 1
      return if vx >= inner.right
      case i
      when SETTINGS_SCOPE_ROW
        # Scope-lens toggle — ON (accent) / OFF (muted), reading the shared session Scope.
        on = @scope.enabled?
        screen.text(vx, y, on ? "ON" : "OFF", on ? Theme.accent : Theme.muted, bg, Attribute::Bold)
      when SETTINGS_SANDBOX_ROW
        render_sandbox_toggle(screen, inner, y, vx, bg)
      when SETTINGS_PROTOCOL_ROW
        render_proxy_protocol(screen, inner, y, vx, selected, bg)
      when SETTINGS_AUTH_ROW
        render_proxy_auth(screen, inner, y, vx, selected, bg)
      else
        render_settings_value(screen, inner, y, vx, i, selected, bg)
      end
    end

    private def render_settings_value(screen : Screen, inner : Rect, y : Int32, vx : Int32,
                                      row : Int32, selected : Bool, bg : Color) : Nil
      proxy_disabled = (row == SETTINGS_PROXY_HOST_ROW || row == SETTINGS_PROXY_PORT_ROW) &&
                       (@set_values[SETTINGS_PROTOCOL_INDEX] == "None" ||
                        @set_values[SETTINGS_PROTOCOL_INDEX].starts_with?("Invalid ·"))
      if proxy_disabled || ((row == SETTINGS_USERNAME_ROW || row == SETTINGS_PASSWORD_ROW) && !settings_auth_enabled?)
        screen.text(vx, y, "—", Theme.muted, bg)
      else
        render_settings_field(screen, inner, y, vx, row - SETTINGS_FIELD_BASE, selected, bg)
      end
    end

    private def render_proxy_protocol(screen : Screen, inner : Rect, y : Int32, vx : Int32,
                                      selected : Bool, bg : Color) : Nil
      value = @set_values[SETTINGS_PROTOCOL_INDEX]
      overridden = @set_overridden[SETTINGS_PROTOCOL_INDEX]
      marker = overridden ? "· project" : "· global"
      mx = inner.right - marker.size
      width = {mx - vx - 1, 3}.max
      shown = SETTINGS_PROTOCOL_CHOICES.includes?(value) && selected ? "‹ #{value} ›" : value
      color = SETTINGS_PROTOCOL_CHOICES.includes?(value) ? (selected ? Theme.text_bright : Theme.text) : Theme.yellow
      screen.text(vx, y, shown, color, bg, width: width)
      screen.text(mx, y, marker, overridden ? Theme.accent : Theme.muted, bg) if mx > vx + 3
    end

    private def render_proxy_auth(screen : Screen, inner : Rect, y : Int32, vx : Int32,
                                  selected : Bool, bg : Color) : Nil
      label = if !settings_auth_enabled?
                "None"
              elsif @set_values[SETTINGS_PROTOCOL_INDEX] == "SOCKS5" ||
                    @set_values[SETTINGS_PROTOCOL_INDEX] == "SOCKS5H"
                "SOCKS5 username/password"
              else
                "Basic"
              end
      label = "‹ #{label} ›" if selected
      screen.text(vx, y, label, settings_auth_enabled? ? Theme.accent : Theme.muted, bg,
        width: {inner.right - vx, 1}.max)
    end

    # The Sandbox toggle value + an ALWAYS-VISIBLE, state-aware guidance note. This is a
    # BLOCKING mode, so the note must make the consequence obvious next to the switch — and
    # SCREAM when the scope has no include rules, the state where ON silently drops ALL
    # traffic. ON draws in red (danger), matching the top-bar sandbox chip + the intercept chip.
    private def render_sandbox_toggle(screen : Screen, inner : Rect, y : Int32, vx : Int32, bg : Color) : Nil
      on = @scope.sandbox?
      x = screen.text(vx, y, on ? "ON" : "OFF", on ? Theme.red : Theme.muted, bg, Attribute::Bold)
      note, nc =
        if !on
          {"· off — all traffic passes", Theme.muted}
        elsif @scope.include_count == 0
          {"⚠ no scope → ALL blocked", Theme.red}
        else
          {"⚠ blocks out-of-scope", Theme.red}
        end
      nx = x + 1
      screen.text(nx, y, note, nc, bg, width: {inner.right - nx, 0}.max) if nx < inner.right
    end

    # One network text field: the value (editable input_line when the row is focused) plus a
    # right-aligned override marker ("· project" versus "· global" / "· default").
    private def render_settings_field(screen : Screen, inner : Rect, y : Int32, vx : Int32,
                                      fi : Int32, selected : Bool, bg : Color) : Nil
      return render_protos_field(screen, inner, y, vx, selected, bg) if fi == SETTINGS_PROTOS_FIELD
      overridden = @set_overridden[fi]
      # "· global" claims settings.json supplied the inherited value. The destination gate and
      # the two credentials have no global counterpart at all — a project-only field that is
      # unset is at its DEFAULT, and naming a source that cannot exist would send an operator
      # looking for the credential in the global editor.
      marker = if SETTINGS_PROJECT_ONLY_INDICES.includes?(fi)
                 overridden ? "· project" : "· default"
               else
                 overridden ? "· project" : "· global"
               end
      mx = inner.right - marker.size
      fw = {mx - vx - 1, 3}.max
      value = @set_values[fi]
      masked = fi == SETTINGS_PASSWORD_INDEX && !selected
      shown = masked ? "•" * value.size : value
      preedit = masked ? "•" * @set_preedit.size : @set_preedit
      if selected
        screen.input_line(vx, y, shown, @set_cursor, preedit, Theme.text_bright, bg, width: fw)
      else
        screen.text(vx, y, shown, Theme.text, bg, width: fw)
      end
      screen.text(mx, y, marker, overridden ? Theme.accent : Theme.muted, bg) if mx > vx + 3
    end

    # The proto-schema row. Its marker is not "project / global" — there is no global to
    # inherit — but WHAT LOADED: "3 files · 41 messages · 12 rpcs", or the reason nothing did.
    # A path that silently resolves to nothing is the whole failure mode of this field, and it
    # is the one thing a "· project" marker would happily lie about.
    private def render_protos_field(screen : Screen, inner : Rect, y : Int32, vx : Int32,
                                    selected : Bool, bg : Color) : Nil
      failed = Protobuf::Schemas.errors?
      marker = "· #{Protobuf::Schemas.status}"
      # Derived, not a constant 38: the status is where a partial load says so ("2 failed",
      # "136 over the 64-file limit"), and a fixed cap put exactly that half off the end on a
      # wide terminal while still crowding a narrow one.
      cap = {inner.w // 2, 24}.max
      marker = "#{marker[0, cap - 1]}…" if marker.size > cap
      mx = inner.right - marker.size
      fw = {mx - vx - 1, 3}.max
      value = @set_values[SETTINGS_PROTOS_FIELD]? || ""
      if selected
        screen.input_line(vx, y, value, @set_cursor, @set_preedit, Theme.text_bright, bg, width: fw)
      else
        # Blank field → say what blank MEANS, rather than leaving an empty cell the operator
        # has to guess at.
        if value.empty?
          screen.text(vx, y, "(#{Paths.protos_dir})", Theme.muted, bg, width: fw)
        else
          screen.text(vx, y, value, Theme.text, bg, width: fw)
        end
      end
      colour = failed ? Theme.yellow : (Protobuf::Schemas.schema ? Theme.accent : Theme.muted)
      screen.text(mx, y, marker, colour, bg) if mx > vx + 3
    end

    # Scroll offset that keeps `sel` visible in a window of `h` rows over `total`.
    # --- ACTIVITY render ---------------------------------------------------------------

    # Widest source the feed carries ("sequencer"). A fixed column so the messages start on one
    # line and the eye can read down them; the source is what the row is ABOUT, and a ragged
    # left edge would make the pane read as prose rather than as a log.
    ACT_SRC_W = 9
    # Below this the source column is dropped rather than squeezed: it costs 10 of the message's
    # cells, and the message is the half only this pane shows.
    ACT_SRC_MIN_W = 40
    # `agent` is the widest label the column prints (`tui`/`cli` are shorter, `—` is one cell).
    ACT_ACTOR_W = 5
    # The actor column costs 6 more cells than the source one, so it needs its own floor.
    ACT_ACTOR_MIN_W = 52

    private def render_activity_card(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.w < 2 || rect.h < 2
      Frame.card(screen, rect, "ACTIVITY", bg: Theme.bg, border: Frame.pane_border(focused))
      Frame.border_meta(screen, rect, "ACTIVITY", activity_meta,
        fg: @act_rows.empty? ? Theme.muted : Theme.text_bright)
      render_activity_body(screen, rect, rect.inset(1, 1), focused)
    end

    # The card's border summary. Names the narrowings that are ON, because a chip filter is the
    # kind of state that turns an empty list into a lie about the project — the operator has to
    # be able to see, without pressing anything, why they are looking at four rows.
    private def activity_meta : String
      parts = [] of String
      n = @act_rows.size
      parts << (activity_more? ? "#{n}+ events" : "#{n} event#{n == 1 ? "" : "s"}")
      # Rows that arrived above a cursor the operator parked further down. Named FIRST after the
      # count, because it is the only part of this line that is about something off-screen.
      #
      # Capped at the rows that ARE above the cursor. The stored counter is what arrived, which
      # stops being what is unseen the moment the operator scrolls up through it — without the
      # cap the border would still promise five new rows overhead to someone standing on the
      # second one. `@act_sel` shrinks as they climb, so the number empties itself out and hits
      # zero exactly at the head, which is also where the counter itself is cleared.
      new_above = {@act_new_above, @act_sel}.min
      parts << "↑#{new_above} new" if new_above > 0
      if src = @act_source
        parts << src
      end
      if lvl = @act_level
        parts << lvl
      end
      if act = @act_actor
        parts << ProjectView.act_actor_label(act)
      end
      parts.join(" · ")
    end

    private def render_activity_body(screen : Screen, card : Rect, inner : Rect, focused : Bool) : Nil
      return if inner.h <= 0 || inner.w <= 0
      # Nothing has EVER been recorded AND nothing is narrowing: the onboarding card owns the
      # whole interior. Gated on the same predicate the geometry uses, so the row the bar would
      # occupy is never reserved by one and skipped by the other.
      unless act_bar_shown?
        TrafficEmptyState.render(screen, inner, variant: :project_activity)
        return
      end
      render_activity_filter_bar(screen, Rect.new(inner.x, inner.y, inner.w, 1))
      list = act_list_inner(inner)
      # A filter is in force (or being typed) over a feed that holds nothing at all. The card
      # still explains the pane, but it draws BELOW the bar — the bar is what says a narrowing
      # is on, and hiding it here is what let a chip stay silently active.
      if @act_feed_empty
        TrafficEmptyState.render(screen, list, variant: :project_activity) if list.h > 0
        return
      end
      render_activity_detail(screen, card, inner, list)
      return if list.h <= 0

      # Rows exist in the feed but not in THIS view. A different sentence from the one above on
      # purpose: "nothing happened" and "your filter hides it" send the operator opposite ways,
      # and only the second is true here.
      if @act_rows.empty?
        render_activity_no_match(screen, list)
        return
      end

      today = Time.local
      scroll = scroll_for(@act_sel, @act_rows.size, list.h)
      shown = {list.h, @act_rows.size - scroll}.min
      shown.times do |i|
        idx = scroll + i
        ry = list.y + i
        selected = idx == @act_sel
        # Dimmed rather than erased when focus leaves, like the SCOPE / HOST OVERRIDES lists:
        # the detail band below is about the selected row, so a card with no visible selection
        # would be showing an explanation of nothing.
        bg = selected ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        screen.fill(Rect.new(list.x, ry, list.w, 1), bg) if selected
        screen.cell(list.x, ry, selected ? '▎' : ' ', Theme.accent, bg)
        render_activity_row(screen, list, ry, @act_rows[idx], selected, bg, today)
      end
      Frame.scroll_gauge(screen, list, @act_rows.size, scroll, focused)
    end

    # "Nothing matched" is only true of what was actually LOOKED at. A page stops either at the
    # end of the feed or at the scan bound, and `next_before` is the difference — so when the
    # scan stopped short, the sentence says how far it got instead of making a claim about
    # events it never read. (Reachable only on a feed grown past its own retention cap, which
    # `trim_events` allows for a process that writes events and captures no flows.)
    private def activity_no_match_line : String
      base = "no events match #{activity_narrowing}"
      activity_more? ? "#{base} in the newest #{Fmt.count(@act_scanned.to_i64)} events" : base
    end

    private def render_activity_no_match(screen : Screen, list : Rect) : Nil
      # Indented to the column the rows' own text starts on, so the sentence sits where the eye
      # is already looking rather than flush against the card's hairline.
      x = list.x + 1
      w = {list.w - 1, 1}.max
      screen.text(x, list.y, activity_no_match_line, Theme.muted, width: w)
      return unless list.h > 1
      # Names the way OUT, and both halves are keys that actually do it. NOT `r`: refresh
      # re-reads from the newest end, which THROWS AWAY every window already walked back — the
      # opposite of what an operator following this line wants. `↓` is what extends the scan
      # (`page_activity` fires on a cursor already at the end, which an empty list always is).
      # `⇧C` is not offered either: that key empties the feed.
      # NOT named `out`: `out` is a Crystal keyword, and `screen.text(…, out, …)` parses as an
      # out-param (the same trap `Store#ids_matching` documents).
      way = activity_more? ? "↓ looks further back · space clears the filters" : "s/l cycle back to all · space clears the filters"
      screen.text(x, list.y + 1, way, Theme.muted, width: w)
    end

    # The narrowing currently in force, as a phrase a sentence can end with.
    private def activity_narrowing : String
      parts = [] of String
      parts << "source #{@act_source}" if @act_source
      parts << "level #{@act_level}" if @act_level
      parts << "actor #{ProjectView.act_actor_label(@act_actor)}" if @act_actor
      parts << "\"#{@act_filter.value}\"" unless @act_filter.value.blank?
      parts.empty? ? "the filter" : parts.join(" + ")
    end

    private def render_activity_row(screen : Screen, list : Rect, ry : Int32,
                                    row : Store::EventRow, selected : Bool, bg : Color,
                                    today : Time) : Nil
      x = list.x + 1
      right = list.right - 1 # the scroll gauge rides the last column
      stamp = ProjectView.act_stamp(row.created_at, today)
      screen.text(x, ry, stamp, Theme.muted, bg)
      x += stamp.size + 1
      glyph, gc = ProjectView.act_glyph(row.level)
      screen.cell(x, ry, glyph, gc, bg)
      x += 2
      if list.w >= ACT_SRC_MIN_W
        screen.text(x, ry, row.source, Theme.muted, bg, width: ACT_SRC_W)
        x += ACT_SRC_W + 1
      end
      # WHO acted, and the AI is the one worth picking out of a scrolling list — the same
      # accent the notification center gives an agent-produced note, so one actor looks like
      # itself on both surfaces. Dropped before the source column is, because "what happened"
      # survives a narrow pane better than "who did it".
      if list.w >= ACT_ACTOR_MIN_W
        label = ProjectView.act_actor_label(row.actor)
        fg = row.actor == Gori::FlowSource::Surface::Mcp.token ? Theme.accent : Theme.muted
        screen.text(x, ry, label, fg, bg, width: ACT_ACTOR_W)
        x += ACT_ACTOR_W + 1
      end
      w = right - x
      return if w <= 0
      fg = selected ? Theme.text_bright : Theme.text
      screen.text(x, ry, ProjectView.act_one_line(row.message), fg, bg, width: w)
    end

    # `HH:MM:SS` for today, `MM-DD` for anything older. A bare clock on a feed that retains
    # 50k rows would read as "just now" for an event from last week; a date that never changes
    # would waste the column on the rows an operator is actually reading.
    #
    # `today` is passed IN rather than read here: this runs once per visible row per frame, and
    # `Time.local` is a timezone resolution. Asking it forty times a frame to answer a question
    # whose answer is the same for every row put two tz lookups per row on the render fiber.
    def self.act_stamp(created_at : Int64, today : Time) : String
      t = Time.unix(created_at // 1_000_000).to_local
      t.date == today.date ? t.to_s("%H:%M:%S") : t.to_s("   %m-%d")
    end

    # Same level vocabulary the notification center draws, so one event looks like itself
    # wherever it surfaces. "warning" is the Sequencer's spelling of "warn" (see act_level_set).
    def self.act_glyph(level : String) : {Char, Color}
      case level
      when "success"         then {'✓', Theme.green}
      when "warn", "warning" then {'⚠', Theme.yellow}
      when "error"           then {'✗', Theme.red}
      else                        {'·', Theme.muted}
      end
    end

    # Feed messages are prose and some are written across several source lines; a newline drawn
    # into a row would leave a hole in the list. The band below shows the whole thing.
    def self.act_one_line(message : String) : String
      message.gsub(/\s+/, " ").strip
    end

    # The three-state filter bar, the grammar the OAST callbacks list already uses: the input
    # while editing, the committed query, and the field names when idle.
    private def render_activity_filter_bar(screen : Screen, rect : Rect) : Nil
      return if rect.empty? || !act_bar_shown?
      screen.fill(rect, Theme.bg)
      if @act_querying
        prefix = "filter › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent, Theme.bg)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @act_filter.value, @act_filter.caret, @act_filter.preedit,
          Theme.text_bright, Theme.bg, width: {rect.w - prefix.size - 2, 0}.max)
      elsif !@act_filter.value.blank?
        screen.text(rect.x + 1, rect.y, ": #{@act_filter.value}", Theme.text, Theme.bg, width: rect.w - 2)
      else
        screen.text(rect.x + 1, rect.y, "/ filter  ·  s source  ·  l level  ·  a actor  ·  ↵ open",
          Theme.muted, Theme.bg, width: rect.w - 2)
      end
    end

    # The selected event's message in full, wrapped, under a tee divider. Drawn only when
    # `act_detail_h` reserved the rows — the geometry decides once and both halves read it.
    private def render_activity_detail(screen : Screen, card : Rect, inner : Rect, list : Rect) : Nil
      return if act_detail_h(inner) == 0
      return unless row = activity_selected_row
      Frame.tee_divider(screen, card, list.bottom, bg: Theme.bg)
      w = inner.w - 1
      return if w <= 0
      text = ProjectView.act_one_line(row.message)
      lay = Wrap.layout(text, w)
      rows = {lay.rows, ACT_DETAIL_H - 1}.min
      rows.times do |i|
        line = text[lay.start_of(i)...lay.end_of(i)]
        # The last drawn row carries an ellipsis when the message runs past the band, so a
        # truncated explanation cannot be read as a complete one.
        line = "#{line[0, {line.size - 1, 0}.max]}…" if i == rows - 1 && lay.rows > rows
        screen.text(inner.x + 1, list.bottom + 1 + i, line, Theme.muted, Theme.bg, width: w)
      end
    end

    private def scroll_for(sel : Int32, total : Int32, h : Int32) : Int32
      return 0 if total <= h || h <= 0
      (sel - h // 2).clamp(0, total - h)
    end

    private def format_time(t : Time?) : String
      return "—" if t.nil?
      # Local wall-clock time for creation date (no tz noise in TUI).
      t.to_local.to_s("%Y-%m-%d %H:%M")
    end

    # Prose sizes for the Project pane — a space before the unit and a TB step, which is why
    # this is not `Fmt.size` (that one is a fixed ≤6-column table cell, no space, capped at
    # GB). What it MUST share is `Fmt`'s rounding convention, stated in that module's
    # docstring: pick the unit from the ROUNDED magnitude, so a value just under a boundary
    # rolls up instead of printing the misleading form. This loop compared the UNROUNDED
    # value, so 1_048_575 bytes rendered as "1024.0 KB" — verbatim the string `Fmt` names as
    # the thing it exists to prevent — where `Fmt.size` gives "1.0MB".
    private def human_size(bytes : Int64) : String
      return "0 B" if bytes <= 0
      units = ["B", "KB", "MB", "GB", "TB"]
      i = 0
      b = bytes.to_f64
      while b.round(1) >= 1024.0 && i < units.size - 1
        b /= 1024.0
        i += 1
      end
      if i == 0
        "#{b.to_i64} #{units[i]}"
      else
        "%.1f #{units[i]}" % b
      end
    end
  end
end
