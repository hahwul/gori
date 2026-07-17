require "../tab_controller"
require "../screen"
require "../theme"
require "../frame"
require "../highlight"
require "../clipboard"
require "../text_field"
require "../../store"
require "../../oast"

module Gori::Tui
  # The OAST tab: register out-of-band payload URLs and watch the DNS/HTTP/SMTP callbacks
  # they draw. ONE controller owns the shared state (providers, live listeners, callback
  # history) behind two fixed sub-tabs — Callbacks (default) and Providers — since both
  # sub-tabs are views of the SAME data (unlike Target, which composes two independent
  # child controllers). Listening is a background job: a poll fiber per session feeds the
  # `@oast_events` channel drained each tick; callbacks persist so history survives restart.
  # No auto-resume — sessions load on enter but polling only restarts on an explicit action.
  class OastController < TabController
    SUBS          = ["Callbacks", "Providers"]
    DRAIN_CAP     = 512
    POLL_INTERVAL = 5.seconds

    # A live listening session: the engine Session + its provider + poll fiber.
    class Listener
      getter session : Oast::Session
      getter provider : Oast::Provider
      getter provider_id : Int64?
      getter provider_label : String
      property poller : Oast::Poller?
      property job_id : Int32 = 0

      def initialize(@session, @provider, @provider_id, @provider_label)
      end

      def active? : Bool
        (p = @poller) ? p.running? : false
      end
    end

    # A displayed callback row (decoupled from the DB id; dedup is by (session, uid)).
    record CbRow, session_id : Int64, uid : String, protocol : String, method : String?,
      source : String?, destination : String, provider : String, at : Time,
      raw_request : String, raw_response : String?

    # register() outcomes carried back to the main fiber (register is a network call run off
    # the main fiber; persistence + poller start happen here on drain).
    record RegOk, session : Oast::Session, provider : Oast::Provider, provider_id : Int64?,
      provider_label : String, want_payload : Bool
    record RegErr, message : String, provider_label : String, provider_id : Int64?
    alias RegResult = RegOk | RegErr

    def initialize(host : Host)
      super(host)
      @providers = [] of Store::OastProviderRecord
      @listeners = [] of Listener
      @callbacks = [] of CbRow
      @seen = Hash(Int64, Set(String)).new       # session_id → seen provider_uids (dedup)
      @session_label = Hash(Int64, String).new    # session_id → provider label for the table
      @active_sub = 0
      @cb_sel = 0
      @cb_scroll = 0
      @cb_detail = false
      @cb_detail_scroll = 0
      @filter = TextField.new       # Callbacks free-text filter (`/`)
      @filter_editing = false
      @prov_sel = 0
      @prov_scroll = 0
      @payload_pick = 0
      @last_payload = nil.as(String?)
      @oast_events = Channel(Oast::Event).new(256)
      @reg_events = Channel(RegResult).new(16)
      @registering = Set(Int64).new # provider ids with a register round-trip in flight (dedup g/^R)
      reload
    end

    # --- identity ---
    def tab : Symbol
      :oast
    end

    def command_scope : Verb::Scope
      callbacks_sub? ? Verb::Scope::OastCallbacks : Verb::Scope::OastProviders
    end

    def callbacks_sub? : Bool
      @active_sub == 0
    end

    # --- sub-tab strip (fixed 2: no create/close) ---
    def subtab_labels : Array(String)?
      SUBS
    end

    def subtab_index : Int32
      @active_sub
    end

    def subtab_strip_shown? : Bool
      true
    end

    def subtabs_fixed? : Bool
      true
    end

    def move_subtab(dir : Int32) : Nil
      set_sub(@active_sub + dir)
    end

    def jump_subtab(idx : Int32) : Nil
      set_sub(idx)
    end

    private def set_sub(idx : Int32) : Nil
      idx = idx.clamp(0, SUBS.size - 1)
      return if idx == @active_sub
      @cb_detail = false
      @active_sub = idx
    end

    def body_badge : Symbol
      @filter_editing ? :editor : :body # :editor while the filter bar captures keystrokes
    end

    # Live IME composition flows to the filter bar while it is being edited.
    def set_preedit(text : String) : Bool
      return false unless @filter_editing
      @filter.set_preedit(text)
      true
    end

    def body_hint(focus : Symbol) : String
      if callbacks_sub?
        return "↑/↓ scroll · esc back" if @cb_detail
        return "type to filter · ↵ keep · esc clear" if @filter_editing
        "↑/↓ select · ‹/› provider · g payload · y copy · / filter · ^R listen · ^X stop · ↵ detail · space cmds"
      else
        "↑/↓ select · a add · e edit · t toggle · d delete · space cmds · esc tabs"
      end
    end

    # --- data ---
    def reload : Nil
      store = @host.session.store
      @providers = store.oast_providers
      @callbacks.clear
      @seen.clear
      @session_label.clear
      store.oast_sessions.each do |s|
        label = provider_label_for(s)
        @session_label[s.id] = label
        seen = (@seen[s.id] ||= Set(String).new)
        store.oast_callbacks(s.id).each do |cb|
          next if seen.includes?(cb.provider_uid)
          seen << cb.provider_uid
          @callbacks << cb_row(cb, label)
        end
      end
      @callbacks.sort_by!(&.at)
      clamp_selection
    end

    # Soft-sync on an external DB change: reload config + history, keep live pollers.
    def reconcile : Nil
      reload
    end

    def on_enter : Nil
      reload
    end

    private def provider_label_for(s : Store::OastSessionRecord) : String
      if (pid = s.provider_id) && (p = @providers.find { |pr| pr.id == pid })
        p.name
      else
        Oast::ProviderKind.parse?(s.kind).try(&.label) || s.kind
      end
    end

    private def cb_row(cb : Store::OastCallbackRecord, label : String) : CbRow
      CbRow.new(cb.session_id, cb.provider_uid, cb.protocol, cb.method, cb.source_ip,
        cb.full_id, label, Time.unix((cb.created_at // 1_000_000)),
        String.new(cb.raw_request), cb.raw_response.try { |b| String.new(b) })
    end

    # --- enabled providers (payload bar picks among these) ---
    private def enabled_providers : Array(Store::OastProviderRecord)
      @providers.select(&.enabled?)
    end

    private def picked_provider : Store::OastProviderRecord?
      ep = enabled_providers
      return nil if ep.empty?
      ep[@payload_pick.clamp(0, ep.size - 1)]?
    end

    # =========================================================================
    # Actions (also reachable as verbs / space menu)
    # =========================================================================

    # Get an OAST payload for the picked provider: generate locally if a listener already
    # exists, else start listening (register off-fiber) and deliver the payload when ready.
    def generate_payload : Nil
      prov = picked_provider
      return @host.status("no enabled provider — add one in the Providers tab") unless prov
      if listener = listener_for(prov.id)
        url = listener.provider.generate_payload(listener.session)
        deliver_payload(url)
      else
        start_listening(prov, want_payload: true)
      end
    end

    def copy_payload : Nil
      if url = @last_payload
        Clipboard.copy(url)
        @host.status("copied OAST payload")
      else
        @host.status("no payload yet — press g to generate")
      end
    end

    def start_listening_action : Nil
      prov = picked_provider
      return @host.status("no enabled provider to listen with") unless prov
      if listener_for(prov.id)
        @host.status("already listening with #{prov.name}")
      else
        start_listening(prov, want_payload: false)
      end
    end

    def stop_listening : Nil
      prov = picked_provider
      return @host.status("no provider selected") unless prov
      listener = listener_for(prov.id)
      return @host.status("not listening with #{prov.name}") unless listener
      stop_listener(listener)
      @host.status("stopped listening with #{prov.name}")
    end

    private def start_listening(prov : Store::OastProviderRecord, want_payload : Bool) : Nil
      # A register round-trip takes a few seconds and only appends the Listener on the
      # drain tick AFTER it returns, so listener_for is nil the whole time. Without an
      # in-flight guard a second g/^R spawns a duplicate register → two sessions, two
      # Listeners and two poller fibers for one provider. Dedup on the provider id.
      pid = prov.id
      return @host.status("already registering with #{prov.name}…") if pid && @registering.includes?(pid)
      kind = Oast::ProviderKind.parse?(prov.kind)
      return @host.status("unknown provider type #{prov.kind}") unless kind
      provider = Oast::Provider.build(kind, prov.host, prov.token)
      http = Oast::HttpClient.new(verify_tls: !@host.session.config.insecure_upstream?)
      reg = @reg_events
      label = prov.name
      @registering << pid if pid
      spawn(name: "gori-oast-register") do
        begin
          session = provider.register(http)
          reg.send(RegOk.new(session, provider, pid, label, want_payload))
        rescue ex
          reg.send(RegErr.new(ex.message || "register failed", label, pid))
        end
      end
      @host.status("registering with #{label}…")
    end

    private def listener_for(provider_id : Int64?) : Listener?
      return nil unless provider_id
      @listeners.find { |l| l.provider_id == provider_id && l.active? }
    end

    private def stop_listener(listener : Listener) : Nil
      listener.poller.try(&.stop)
      @host.jobs.finish(listener.job_id, :stopped, "stopped") if listener.job_id != 0
      http = Oast::HttpClient.new(verify_tls: !@host.session.config.insecure_upstream?)
      provider = listener.provider
      session = listener.session
      spawn(name: "gori-oast-deregister") { provider.deregister(http, session) rescue nil }
      @listeners.delete(listener)
    end

    private def deliver_payload(url : String) : Nil
      @last_payload = url
      Clipboard.copy(url)
      @host.status("OAST payload ready + copied: #{url}")
    end

    # Cross-tab: a listener exists → a payload can be generated locally (no network).
    def has_active_listener? : Bool
      @listeners.any?(&.active?)
    end

    # Cross-tab: generate a fresh payload from the first active listener (LOCAL). nil when
    # there is no listener (the caller toasts a hint).
    def generate_for_insert : String?
      listener = @listeners.find(&.active?)
      return nil unless listener
      url = listener.provider.generate_payload(listener.session)
      @last_payload = url
      url
    end

    # =========================================================================
    # Providers management
    # =========================================================================

    def open_add_provider : Nil
      @host.open_oast_provider_editor(nil, "", "interactsh", "", "")
    end

    def open_edit_provider : Nil
      return @host.status("no provider selected") unless p = selected_provider
      @host.open_oast_provider_editor(p.id, p.name, p.kind, p.host, p.token || "")
    end

    def toggle_provider : Nil
      return unless p = selected_provider
      @host.session.store.set_oast_provider_enabled(p.id, !p.enabled?)
      reload
    end

    def delete_provider : Nil
      return unless p = selected_provider
      @host.confirm("DELETE PROVIDER", "Delete OAST provider \"#{p.name}\"?\nIts callback history is kept.",
        confirm_label: "delete", danger: true) do
        if l = @listeners.find { |ls| ls.provider_id == p.id }
          stop_listener(l)
        end
        @host.session.store.delete_oast_provider(p.id)
        reload
      end
    end

    # Called back by the runner when the provider overlay commits.
    def save_provider(edit_id : Int64?, name : String, kind : Oast::ProviderKind, host : String, token : String?) : Nil
      store = @host.session.store
      if id = edit_id
        store.update_oast_provider(id, name, kind.label, host, token, true)
      else
        store.insert_oast_provider(name, kind.label, host, token, true, @providers.size)
      end
      reload
      @host.status("saved provider #{name}")
    end

    private def selected_provider : Store::OastProviderRecord?
      @providers[@prov_sel]?
    end

    # =========================================================================
    # Rendering
    # =========================================================================

    def render_body(screen : Screen, rect : Rect, focus : Symbol) : Nil
      shell = BodyChrome.shell_focused(focus, multi_pane: true)
      subtabs_focused = focus == :subtabs
      body_focused = focus == :body
      @subtab_start = BodyChrome.framed_body(screen, rect, shell, subtabs_focused,
        subtab_labels, @active_sub, @subtab_start) do |content|
        if callbacks_sub?
          render_callbacks(screen, content, body_focused)
        else
          render_providers(screen, content, body_focused)
        end
      end
    end

    private def render_callbacks(screen : Screen, rect : Rect, focused : Bool) : Nil
      return if rect.h < 2
      # payload bar (2 rows)
      bar = Rect.new(rect.x, rect.y, rect.w, 2)
      render_payload_bar(screen, bar)
      body = Rect.new(rect.x, rect.y + 2, rect.w, rect.h - 2)
      if @cb_detail && (row = selected_callback)
        render_callback_detail(screen, body, row, focused)
      elsif body.h >= 2
        # filter bar row above the table
        render_filter_bar(screen, Rect.new(body.x, body.y, body.w, 1))
        render_callback_table(screen, Rect.new(body.x, body.y + 1, body.w, body.h - 1), focused)
      else
        render_callback_table(screen, body, focused)
      end
    end

    # Three-state filter bar (mirrors the History/Intercept bar): editing → `filter › <input>`;
    # committed non-blank → `: <query>`; idle → the field hint.
    private def render_filter_bar(screen : Screen, rect : Rect) : Nil
      return if rect.empty?
      screen.fill(Rect.new(rect.x, rect.y, rect.w, 1), Theme.bg)
      if @filter_editing
        prefix = "filter › "
        screen.text(rect.x + 1, rect.y, prefix, Theme.accent, Theme.bg)
        base = rect.x + 1 + prefix.size
        screen.input_line(base, rect.y, @filter.value, @filter.caret, @filter.preedit,
          Theme.text_bright, Theme.bg, width: {rect.w - prefix.size - 2, 0}.max)
      elsif !@filter.value.blank?
        screen.text(rect.x + 1, rect.y, ": #{@filter.value}", Theme.text, Theme.bg, width: rect.w - 2)
      else
        screen.text(rect.x + 1, rect.y, "/ filter  ·  proto  method  source  dest  provider",
          Theme.muted, Theme.bg, width: rect.w - 2)
      end
    end

    private def render_payload_bar(screen : Screen, rect : Rect) : Nil
      screen.fill(Rect.new(rect.x, rect.y, rect.w, 1), Theme.panel)
      prov = picked_provider
      x = rect.x + 1
      x = screen.text(x, rect.y, "provider ", Theme.muted, Theme.panel)
      name = prov ? "‹ #{prov.name} ›" : "‹ none — add one › "
      listening = prov && listener_for(prov.id) ? "  ●listening" : ""
      x = screen.text(x, rect.y, name, Theme.accent, Theme.panel)
      screen.text(x, rect.y, listening, Theme.green, Theme.panel) unless listening.empty?
      # payload row
      if url = @last_payload
        screen.text(rect.x + 1, rect.y + 1, url, Theme.text_bright, Theme.bg, width: rect.w - 2)
      else
        screen.text(rect.x + 1, rect.y + 1, "press g to get an OAST payload URL (copies to clipboard)", Theme.muted, Theme.bg, width: rect.w - 2)
      end
    end

    private def render_callback_table(screen : Screen, rect : Rect, focused : Bool) : Nil
      ordered = ordered_callbacks
      filtering = !@filter.value.strip.empty?
      title = filtering ? "CALLBACKS (#{ordered.size}/#{@callbacks.size})" : "CALLBACKS (#{@callbacks.size})"
      Frame.card(screen, rect, title, border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      if ordered.empty?
        msg = filtering ? "no callbacks match “#{@filter.value.strip}” — esc to clear" : "no callbacks yet — get a payload (g), use it in a target, watch here"
        screen.text(inner.x + 1, inner.y, msg, Theme.muted, Theme.bg, width: inner.w - 2)
        return
      end
      header_y = inner.y
      screen.text(inner.x + 2, header_y, "PROTO", Theme.muted, Theme.bg)
      screen.text(inner.x + 9, header_y, "METHOD", Theme.muted, Theme.bg)
      screen.text(inner.x + 18, header_y, "SOURCE", Theme.muted, Theme.bg)
      screen.text(inner.x + 36, header_y, "DESTINATION", Theme.muted, Theme.bg)
      screen.text(inner.right - 18, header_y, "PROVIDER", Theme.muted, Theme.bg)
      rows_rect = Rect.new(inner.x, inner.y + 1, inner.w, inner.h - 1)
      visible = rows_rect.h
      return if visible <= 0 # a collapsed pane (tiny terminal) has no rows to draw; a negative slice count would raise
      # Keep the selection in view in BOTH directions (@cb_sel may have moved via keys or
      # the wheel, neither of which advances the viewport downward on its own).
      @cb_scroll = @cb_sel if @cb_sel < @cb_scroll
      @cb_scroll = @cb_sel - visible + 1 if @cb_sel >= @cb_scroll + visible
      @cb_scroll = @cb_scroll.clamp(0, {ordered.size - visible, 0}.max)
      ordered[@cb_scroll, visible]?.try &.each_with_index do |row, i|
        py = rows_rect.y + i
        abs = @cb_scroll + i
        draw_callback_row(screen, rows_rect, py, row, abs == @cb_sel, focused)
      end
    end

    private def draw_callback_row(screen : Screen, rect : Rect, py : Int32, row : CbRow, sel : Bool, focused : Bool) : Nil
      bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
      screen.fill(Rect.new(rect.x, py, rect.w, 1), bg)
      screen.cell(rect.x, py, sel ? '▎' : ' ', Theme.accent, bg)
      screen.text(rect.x + 2, py, row.protocol, protocol_hue(row.protocol), bg, width: 6)
      screen.text(rect.x + 9, py, row.method || "—", Theme.text, bg, width: 8)
      screen.text(rect.x + 18, py, row.source || "—", Theme.accent, bg, width: 17)
      dw = {rect.right - 18 - (rect.x + 36), 6}.max
      screen.text(rect.x + 36, py, row.destination, sel ? Theme.text_bright : Theme.text, bg, width: dw)
      screen.text(rect.right - 18, py, row.provider, Theme.muted, bg, width: 17)
    end

    private def protocol_hue(proto : String) : Color
      case proto.downcase
      when "http", "https" then Theme.accent
      when "dns"           then Theme.green
      when "smtp", "smb"   then Theme.yellow
      else                      Theme.text
      end
    end

    private def render_callback_detail(screen : Screen, rect : Rect, row : CbRow, focused : Bool) : Nil
      Frame.card(screen, rect, "#{row.protocol.upcase} · #{row.destination}", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      meta = "from #{row.source || "?"} · provider #{row.provider} · #{row.at.to_rfc3339}"
      screen.text(inner.x + 1, inner.y, meta, Theme.muted, Theme.bg, width: inner.w - 2)
      body = Rect.new(inner.x, inner.y + 2, inner.w, inner.h - 2)
      return if body.h <= 0 # collapsed pane (tiny terminal): a negative slice count would raise
      text = row.raw_response ? "#{row.raw_request}\n\n--- response ---\n#{row.raw_response}" : row.raw_request
      lines = text.split('\n')
      @cb_detail_scroll = @cb_detail_scroll.clamp(0, {lines.size - body.h, 0}.max)
      lines[@cb_detail_scroll, body.h]?.try &.each_with_index do |line, i|
        screen.text(body.x + 1, body.y + i, line, Theme.text, Theme.bg, width: body.w - 2)
      end
    end

    private def render_providers(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "PROVIDERS (#{@providers.size})", border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      if @providers.empty?
        screen.text(inner.x + 1, inner.y, "no providers — press a to add one (interactsh is prefilled)", Theme.muted, Theme.bg, width: inner.w - 2)
        return
      end
      screen.text(inner.x + 2, inner.y, "NAME", Theme.muted, Theme.bg)
      screen.text(inner.x + 24, inner.y, "TYPE", Theme.muted, Theme.bg)
      screen.text(inner.x + 38, inner.y, "HOST", Theme.muted, Theme.bg)
      screen.text(inner.right - 8, inner.y, "ENABLED", Theme.muted, Theme.bg)
      rows = Rect.new(inner.x, inner.y + 1, inner.w, inner.h - 1)
      return if rows.h <= 0 # collapsed pane (tiny terminal): a negative slice count would raise
      sync_prov_scroll(rows.h)
      @providers[@prov_scroll, rows.h]?.try &.each_with_index do |p, i|
        py = rows.y + i
        abs = @prov_scroll + i
        sel = abs == @prov_sel
        bg = sel ? (focused ? Theme.accent_bg : Theme.selection_dim) : Theme.bg
        screen.fill(Rect.new(rows.x, py, rows.w, 1), bg)
        screen.cell(rows.x, py, sel ? '▎' : ' ', Theme.accent, bg)
        screen.text(rows.x + 2, py, p.name, sel ? Theme.text_bright : Theme.text, bg, width: 21)
        kind_label = Oast::ProviderKind.parse?(p.kind).try(&.label) || p.kind
        screen.text(rows.x + 24, py, kind_label, Theme.accent, bg, width: 13)
        hw = {rows.right - 10 - (rows.x + 38), 6}.max
        screen.text(rows.x + 38, py, p.host, Theme.text, bg, width: hw)
        listening = @listeners.any? { |l| l.provider_id == p.id && l.active? }
        badge = p.enabled? ? (listening ? "● live" : "on") : "off"
        screen.text(rows.right - 8, py, badge, p.enabled? ? Theme.green : Theme.muted, bg)
      end
    end

    # Keep @prov_sel within the visible provider window (both directions), then clamp — so a
    # selection taller than the pane scrolls into view instead of vanishing off the bottom.
    private def sync_prov_scroll(visible : Int32) : Nil
      if visible > 0
        @prov_scroll = @prov_sel if @prov_sel < @prov_scroll
        @prov_scroll = @prov_sel - visible + 1 if @prov_sel >= @prov_scroll + visible
      end
      @prov_scroll = @prov_scroll.clamp(0, {@providers.size - visible, 0}.max)
    end

    private def selected_callback : CbRow?
      ordered_callbacks[@cb_sel]?
    end

    # The callbacks in display order (newest first), narrowed by the filter. `@callbacks`
    # stays the master store so live inserts still land and simply re-filter next render.
    private def ordered_callbacks : Array(CbRow)
      filtered_callbacks.reverse
    end

    private def filtered_callbacks : Array(CbRow)
      q = @filter.value.strip.downcase
      return @callbacks if q.empty?
      @callbacks.select { |r| callback_matches?(r, q) }
    end

    private def callback_matches?(r : CbRow, q : String) : Bool
      r.protocol.downcase.includes?(q) ||
        (r.method.try(&.downcase.includes?(q)) || false) ||
        (r.source.try(&.downcase.includes?(q)) || false) ||
        r.destination.downcase.includes?(q) ||
        r.provider.downcase.includes?(q)
    end

    # --- filter bar (a text sub-mode; the shell claims it before the focus ring, exactly
    # like the History/Intercept filter). ---
    def start_cb_filter : Nil
      @filter_editing = true
      @filter.end_of_line
    end

    def cb_filter_editing? : Bool
      @filter_editing
    end

    def handle_cb_filter_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.enter?
        @filter_editing = false # keep the query, leave edit mode
      elsif key.escape?
        clear_cb_filter
      else
        @filter.handle_edit_key(ev)
      end
      @cb_sel = @cb_sel.clamp(0, {filtered_callbacks.size - 1, 0}.max)
      @cb_scroll = 0
      true
    end

    private def clear_cb_filter : Nil
      @filter.set("")
      @filter_editing = false
      @cb_sel = 0
      @cb_scroll = 0
    end

    # =========================================================================
    # Input
    # =========================================================================

    def handle_body_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      if key.space? && !ev.ctrl? && !ev.alt?
        @host.open_space_menu
        return true
      end
      return false if ev.ctrl? || ev.alt? # ^R/^X etc. → keymap verbs
      callbacks_sub? ? handle_callbacks_key(ev) : handle_providers_key(ev)
    end

    private def handle_callbacks_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      if @cb_detail
        case
        when key.escape?             then @cb_detail = false
        when key.up?, key.lower_k?   then @cb_detail_scroll -= 1
        when key.down?, key.lower_j? then @cb_detail_scroll += 1
        else                              return true
        end
        return true
      end
      case
      when key.escape?             then @host.request_focus(:subtabs)
      when key.up?, key.lower_k?   then cb_row_up
      when key.down?, key.lower_j? then @cb_sel = {@cb_sel + 1, {filtered_callbacks.size - 1, 0}.max}.min
      when key.left?               then cycle_provider(-1)
      when key.right?              then cycle_provider(1)
      when key.enter?              then @cb_detail = true if selected_callback
      when c == 'g'                then generate_payload
      when c == 'y'                then copy_payload
      else                              return false
      end
      sync_scroll
      true
    end

    # ↑/k at the top row pops focus up to the sub-tab strip (like Miner/History); otherwise
    # move the selection up.
    private def cb_row_up : Nil
      if @cb_sel <= 0
        @host.request_focus(:subtabs)
      else
        @cb_sel -= 1
      end
    end

    private def prov_row_up : Nil
      if @prov_sel <= 0
        @host.request_focus(:subtabs)
      else
        @prov_sel -= 1
      end
    end

    private def handle_providers_key(ev : Termisu::Event::Key) : Bool
      key = ev.key
      c = ev.char || key.to_char
      case
      when key.escape?             then @host.request_focus(:subtabs)
      when key.up?, key.lower_k?   then prov_row_up
      when key.down?, key.lower_j? then @prov_sel = {@prov_sel + 1, {@providers.size - 1, 0}.max}.min
      when key.enter?, c == 'e'    then open_edit_provider
      when c == 'a'                then open_add_provider
      when c == 't'                then toggle_provider
      when c == 'd'                then delete_provider
      else                              return false
      end
      true
    end

    private def cycle_provider(dir : Int32) : Nil
      ep = enabled_providers
      return if ep.empty?
      @payload_pick = (@payload_pick + dir) % ep.size
    end

    private def sync_scroll : Nil
      # keep selection visible in the table (approximate; render clamps precisely)
      @cb_sel = @cb_sel.clamp(0, {filtered_callbacks.size - 1, 0}.max)
      if @cb_sel < @cb_scroll
        @cb_scroll = @cb_sel
      end
    end

    private def clamp_selection : Nil
      @cb_sel = @cb_sel.clamp(0, {filtered_callbacks.size - 1, 0}.max)
      @prov_sel = @prov_sel.clamp(0, {@providers.size - 1, 0}.max)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      true
    end

    def handle_wheel(step : Int32) : Bool
      if callbacks_sub?
        if @cb_detail
          @cb_detail_scroll += step
        else
          @cb_sel = (@cb_sel + step).clamp(0, {filtered_callbacks.size - 1, 0}.max)
          sync_scroll
        end
      else
        @prov_sel = (@prov_sel + step).clamp(0, {@providers.size - 1, 0}.max)
      end
      true
    end

    # =========================================================================
    # Background drain (called each run-loop tick by the Runner)
    # =========================================================================

    def drain_events : Bool
      applied = false
      applied = true if drain_registrations
      n = 0
      while n < DRAIN_CAP && (ev = nonblocking_callback)
        n += 1
        apply_callback(ev)
        applied = true
      end
      applied
    end

    private def drain_registrations : Bool
      applied = false
      while reg = nonblocking_reg
        apply_registration(reg)
        applied = true
      end
      applied
    end

    private def nonblocking_reg : RegResult?
      select
      when r = @reg_events.receive
        r
      else
        nil
      end
    end

    private def nonblocking_callback : Oast::Event?
      select
      when e = @oast_events.receive
        e
      else
        nil
      end
    end

    private def apply_registration(reg : RegResult) : Nil
      if pid = reg.provider_id
        @registering.delete(pid) # registration resolved (ok or err) — clear the in-flight guard
      end
      case reg
      when RegErr
        @host.status("OAST register failed (#{reg.provider_label}): #{reg.message}")
      when RegOk
        store = @host.session.store
        id = store.insert_oast_session(reg.provider_id, reg.session.kind.label, reg.session.server_url,
          reg.session.correlation_id, reg.session.secret, reg.session.private_key_pem, reg.session.token)
        reg.session.id = id
        listener = Listener.new(reg.session, reg.provider, reg.provider_id, reg.provider_label)
        listener.job_id = @host.jobs.start(:oast, "OAST #{reg.provider_label}", goto: Jobs::Goto.new(:oast))
        poller = Oast::Poller.new(reg.provider, reg.session, poll_http, POLL_INTERVAL, @oast_events)
        listener.poller = poller
        poller.start
        @listeners << listener
        @seen[id] ||= Set(String).new
        @session_label[id] = reg.provider_label
        if reg.want_payload
          deliver_payload(reg.provider.generate_payload(reg.session))
        else
          @host.status("listening with #{reg.provider_label}")
        end
      end
    end

    private def apply_callback(ev : Oast::Event) : Nil
      case ev
      when Oast::OastErrorEvent
        @host.status("OAST poll error: #{ev.message}")
      when Oast::CallbackEvent
        sid = ev.session_id
        seen = (@seen[sid] ||= Set(String).new)
        i = ev.interaction
        return if seen.includes?(i.unique_id)
        seen << i.unique_id
        label = @session_label[sid]? || "oast"
        store = @host.session.store
        store.insert_oast_callback(sid, i.unique_id, i.protocol, i.method, i.source_ip,
          i.full_id, i.raw_request.to_slice, i.raw_response.try(&.to_slice), now_us)
        @callbacks << CbRow.new(sid, i.unique_id, i.protocol, i.method, i.source_ip, i.full_id,
          label, i.at, i.raw_request, i.raw_response)
        n = @listeners.find { |l| l.session.id == sid }
        @host.jobs.progress(n.job_id, nil, nil, "#{callbacks_for(sid)} hits") if n
        @host.notifications.push(:success, "OAST #{i.protocol.upcase} hit on #{label} (#{i.source_ip || "?"})",
          Jobs::Goto.new(:oast), source: "oast")
      end
    end

    private def callbacks_for(sid : Int64) : Int32
      @callbacks.count { |c| c.session_id == sid }
    end

    private def poll_http : Oast::Http
      Oast::HttpClient.new(verify_tls: !@host.session.config.insecure_upstream?)
    end

    private def now_us : Int64
      Time.utc.to_unix_ms * 1000
    end

    # Notification "jump to result" lands on this tab (no per-row reveal needed).
    def reveal_session(id : Int64) : Nil
      @active_sub = 0
      @host.focus_body
    end
  end
end
