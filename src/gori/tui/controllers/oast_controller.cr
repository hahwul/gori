require "../tab_controller"
require "../screen"
require "../theme"
require "../frame"
require "../traffic_empty_state"
require "../highlight"
require "../clipboard"
require "../read_pane"
require "../text_field"
require "../../store"
require "../../settings"
require "../../oast"
require "../../oast/provider_config"
require "../../oast/sessions"
require "../oast_provider_overlay"
require "../oast_provider_picker"
require "../oast_session_picker"
require "../viewport"

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

    # How often a live listener re-stamps its session's `last_poll_at` — the cross-process liveness
    # signal the probe OOB minter reads (Oast::StoreMinter). Coarser than POLL_INTERVAL on purpose:
    # it only needs to keep a live session ranked above a stopped one, not to be precise, and a
    # live-but-idle listener draws no callbacks, so this heartbeat is the ONLY thing keeping its row
    # ahead of a newer, stopped session.
    SESSION_HEARTBEAT = 30.seconds

    # Ring cap on the in-memory callback window. A per-project result buffer fed by a NETWORK
    # PEER must have a cap or an eviction policy: unlike every other result list in this layer,
    # growth here is paced by the PROVIDER, not the operator. An interact.sh-class domain
    # attracts unsolicited third-party scanner traffic, the poller ingests it every
    # POLL_INTERVAL for as long as the listener lives, and each interaction costs one CbRow
    # holding the FULL raw_request and raw_response. Unbounded, that is the only buffer in the
    # TUI a third party can grow (Notifications::CAP 100, Jobs::CAP 50, FuzzerView::RESULT_CAP
    # 5000 are all bounded).
    #
    # This is a VIEW WINDOW, not a destructive trim: every evicted row is still in the
    # `oast_callbacks` table, and `reload` re-forms the window over the newest CALLBACK_CAP of
    # them. Lower than FuzzerView's 5000 because a fuzz row keeps bodies only for matches while
    # every OAST row carries both raw sides in full — 2000 is ~2-4 MiB of live interactions and
    # is two orders of magnitude past the few dozen callbacks a real assessment produces, so
    # the operator's own evidence never reaches it; only a flood does.
    CALLBACK_CAP = 2000

    # A live listening session: the engine Session + its provider + poll fiber.
    # `provider_key` is the scope-qualified Oast::ProviderConfig#key (stable across both
    # scopes; a global provider has no project-DB row id to key off).
    class Listener
      getter session : Oast::Session
      getter provider : Oast::Provider
      getter provider_key : String
      getter provider_label : String
      property poller : Oast::Poller?
      property job_id : Int32 = 0

      def initialize(@session, @provider, @provider_key, @provider_label)
      end

      def active? : Bool
        (p = @poller) ? p.running? : false
      end
    end

    # A displayed callback row (decoupled from the DB id; dedup is by (session, uid)).
    record CbRow, session_id : Int64, uid : String, protocol : String, method : String?,
      source : String?, destination : String, provider : String, at : Time,
      raw_request : String, raw_response : String?

    # The "Add issue" prefill for one callback (see callback_issue_draft). A record rather
    # than three loose returns because the Runner opens the form with it verbatim, and
    # because `host` being NIL is a decision worth naming: an OAST interaction has a source
    # (whoever called back) and a destination (our own listener), and NEITHER is the target
    # host every other issue's `host` column means. Filing the source IP there would poison
    # the Issues tab's `host:` filter with a second meaning; it goes in the title and the
    # evidence instead, where it cannot be mistaken for one.
    record IssueDraft, title : String, host : String?, notes : String

    # How much of each raw side rides into the issue notes. A callback is evidence and the
    # notes column is where it belongs, but `raw_request` is attacker-shaped input from a
    # third-party server — an interactsh domain collects unsolicited scanner traffic — and an
    # issue is exported to Markdown/JSON and read in editors. 8 KiB is far past a DNS query or
    # a blind-SSRF GET, and the untruncated bytes are still in `oast_callbacks`.
    EVIDENCE_CAP = 8192

    # register() outcomes carried back to the main fiber (register is a network call run off
    # the main fiber; persistence + poller start happen here on drain). `db_provider_id` is
    # the project-DB row id to persist on the session (nil for a global-scope provider — it
    # has no row in this project's DB; `provider_config_for` re-resolves those by kind +
    # endpoint instead, so a global provider's sessions still come back named and resumable).
    # `resumed` distinguishes the two round trips this record carries back. A fresh register
    # mints server state and needs an `oast_sessions` row; a RESUME re-arms a session that
    # already has one (`session.id` is its row id, set before the spawn). Inserting again there
    # would fork the callback history: the poller would file the same interactions under a
    # second session id, and the first row — the one holding the payloads the operator planted
    # — would sit at its old hit count forever.
    record RegOk, session : Oast::Session, provider : Oast::Provider, provider_key : String,
      db_provider_id : Int64?, provider_label : String, want_payload : Bool, resumed : Bool = false
    record RegErr, message : String, provider_label : String, provider_key : String
    alias RegResult = RegOk | RegErr

    def initialize(host : Host)
      super(host)
      @providers = [] of Oast::ProviderConfig
      @listeners = [] of Listener
      @callbacks = [] of CbRow
      @seen = Hash(Int64, Set(String)).new     # session_id → seen provider_uids, WINDOWED (dedup)
      @hits = Hash(Int64, Int32).new           # session_id → TOTAL callbacks folded (survives eviction)
      @evicted = 0                             # rows dropped off the old end of the window (still in the DB)
      @evict_announced = false                 # the one-time "the pane is a window now" note has fired
      @session_label = Hash(Int64, String).new # session_id → provider label for the table
      @active_sub = 0
      @cb_sel = 0
      @cb_scroll = 0
      @cb_detail = false
      # The callback detail's caret, selection, scroll and draw. This pane holds the raw callback
      # — the evidence an OAST finding rests on — and had no caret and no copy of its own: the
      # tab's `y` copies the PAYLOAD, not what came back.
      # Soft wrap: a callback's body / headers are the payload under inspection, and an
      # interaction record is mostly long single lines.
      @cb_pane = ReadPane.new(wrap: true)
      @filter = TextField.new # Callbacks free-text filter (`/`)
      @filter_editing = false
      @prov_sel = 0
      @prov_scroll = 0
      @payload_pick = 0
      @last_payload = nil.as(String?)
      @oast_events = Channel(Oast::Event).new(256)
      @reg_events = Channel(RegResult).new(16)
      @registering = Set(String).new # provider keys with a register round-trip in flight (dedup g/^R)
      @max_cb_id = 0_i64             # highest callback row id folded in (watermark for reconcile)
      @cb_version = 0                # bumped on any @callbacks mutation → invalidates the view caches
      @ordered_cache = nil.as(Array(CbRow)?)
      @ordered_cache_key = nil.as({Int32, String, Int32}?)
      @filtered_cache = nil.as(Array(CbRow)?)
      @filtered_cache_key = nil.as({Int32, String, Int32}?)
      @last_session_heartbeat = Time.instant # gate for the last_poll_at heartbeat (see SESSION_HEARTBEAT)
      reload
    end

    # --- identity ---
    def tab : Symbol
      :oast
    end

    # The focus area the space menu shows alongside COMMON: `:detail` with a callback open,
    # `:list` on the callbacks list, `:common` on Providers. The split exists because the two
    # views spend `y` differently — the list copies the payload gori generated, the detail copies
    # what came back — and two sections never render together.
    def command_section : Symbol
      return :common unless callbacks_sub?
      @cb_detail ? :detail : :list
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
        return "↑/↓ move · ⇧arrows select · y copy · x line · space cmds · ←/esc back" if @cb_detail
        return "type to filter · ↵ keep · esc clear" if @filter_editing
        "↑/↓ select · ‹/› provider · g payload · y copy · / filter · ^R listen · ^X stop · ↵ detail · space cmds"
      else
        # `x on/off` and `↵/e edit` — the vocabulary the three sibling rule lists use. Toggle was
        # `t` here alone, and ↵ has always opened the editor without the hint saying so.
        "↑/↓ select · a add · ↵/e edit · x on/off · d delete · space cmds · esc sub-tabs"
      end
    end

    # --- data ---
    # Authoritative full rebuild (init + on_enter): re-read providers/sessions, then fold the
    # whole callback table in one rowid-ordered query (id order == chronological, so no sort).
    # Also reflects any peer-process deletions. Live/soft-sync updates go through reconcile.
    # The fold is windowed by trim_callbacks, so the REBUILT state is the newest CALLBACK_CAP
    # rows and the eviction counter is recomputed from scratch rather than carried across —
    # the window is a function of the table, so a revisit must not inflate it.
    def reload : Nil
      store = @host.session.store
      @providers = Oast.provider_configs(store)
      @callbacks.clear
      @seen.clear
      @hits.clear
      @evicted = 0
      @session_label.clear
      @max_cb_id = 0_i64
      store.oast_sessions.each do |s|
        @session_label[s.id] = provider_label_for(s)
        @seen[s.id] ||= Set(String).new
      end
      store.oast_callbacks_since(0_i64).each { |cb| fold_callback(cb) }
      @cb_version += 1
      clamp_selection
    end

    # Soft-sync on an external DB change (own commits OR a peer process): refresh the cheap
    # config (providers/sessions/labels), then fold in ONLY callbacks past the watermark. This
    # runs on every data_version bump — up to ~1.3×/sec during capture, even off-tab — so it
    # must stay incremental; the full-table reload lives in reload (init + on_enter).
    def reconcile : Nil
      store = @host.session.store
      @providers = Oast.provider_configs(store)
      store.oast_sessions.each do |s|
        @session_label[s.id] = provider_label_for(s)
        @seen[s.id] ||= Set(String).new
      end
      inserted = false
      store.oast_callbacks_since(@max_cb_id).each { |cb| inserted = true if fold_callback(cb) }
      @cb_version += 1 if inserted
      clamp_selection
    end

    # Add one persisted callback to the in-memory view, advancing the watermark. Returns true
    # if it was new (not a dedup hit). Rows arrive id-ascending, so the watermark only grows;
    # a callback the live drain already appended is read once here, skipped, and its id clears
    # the watermark so it is never re-read again (bounds reconcile to new-since-last rows).
    # That same id-ascending order is what makes the windowing below keep the NEWEST rows.
    private def fold_callback(cb : Store::OastCallbackRecord) : Bool
      @max_cb_id = cb.id if cb.id > @max_cb_id
      seen = (@seen[cb.session_id] ||= Set(String).new)
      return false if seen.includes?(cb.provider_uid)
      seen << cb.provider_uid
      @hits[cb.session_id] = (@hits[cb.session_id]? || 0) + 1
      @callbacks << cb_row(cb, @session_label[cb.session_id]? || "oast")
      trim_callbacks
      true
    end

    # Hold @callbacks to CALLBACK_CAP by dropping its OLDEST rows, and drop their uids from
    # @seen with them — @seen grew one interned uid per row in lockstep, so capping the rows
    # alone would only slow the same unbounded growth down.
    #
    # Evicting the OLD end is what keeps dedup sound. The one re-announcement that must never
    # double-append is `reconcile` re-reading a row the live drain already appended, and those
    # rows are always NEWER than @max_cb_id — never the ones dropped here. Both callers fold
    # id-ascending (`oast_callbacks_since` is ORDER BY id; the live drain is chronological), so
    # the surviving window is the newest CALLBACK_CAP rows, not an arbitrary slice. The residual
    # trade is a provider re-announcing an interaction OLDER than the window: the table stays
    # single-copy (UNIQUE(session_id, provider_uid) + INSERT OR IGNORE) but the pane would show
    # that row a second time, and @hits would over-count it until the next reload.
    #
    # @cb_sel indexes the REVERSED (newest-first) display, so dropping the old end leaves every
    # newer row's index untouched — the least disruptive end to evict. The one case it moves
    # under is a selection parked at the very bottom of a FULL window during a flood:
    # reanchor_callback_selection cannot find the evicted row and the render clamp lands @cb_sel
    # on its neighbour. Accepted rather than given machinery — that row is leaving either way.
    private def trim_callbacks : Nil
      return if @callbacks.size <= CALLBACK_CAP
      while @callbacks.size > CALLBACK_CAP
        old = @callbacks.shift
        @seen[old.session_id]?.try(&.delete(old.uid))
        @evicted += 1
      end
    end

    def on_enter : Nil
      reload
    end

    # The name a session's rows are labelled with. Routes through `provider_config_for`, so a
    # session registered against a GLOBAL provider — which has no project-DB row id to key off,
    # and so used to fall back to the bare kind label after every restart — comes back named.
    # Only a provider that is genuinely gone reaches the fallback now.
    private def provider_label_for(s : Store::OastSessionRecord) : String
      if p = provider_config_for(s)
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
    private def enabled_providers : Array(Oast::ProviderConfig)
      @providers.select(&.enabled)
    end

    private def picked_provider : Oast::ProviderConfig?
      ep = enabled_providers
      return nil if ep.empty? || @payload_pick == 0
      ep[(@payload_pick - 1).clamp(0, ep.size - 1)]?
    end

    # =========================================================================
    # The "All" position → one provider
    # =========================================================================
    #
    # The payload bar has an All position, which is legible for the CALLBACKS table (show every
    # provider's hits) and meaningless for `g` / `^R` / `^X`, each of which acts on exactly one
    # provider. All three used to answer that with a status line — "select a specific provider
    # (use ‹/› to cycle)" — which is a refusal that names a second, invisible step: the operator
    # pressed a key, was told no, and had to go find a bar they were not looking at.
    #
    # Two thirds of that is answerable without asking. With NO enabled provider the answer is
    # "add one", not "pick one". With exactly ONE, All *is* that provider, so the pick is
    # busywork — resolve it in place and let the bar show what happened. Only a genuine
    # ambiguity (two or more enabled, bar on All) is a question, and `g`/`^R` ask it as a card
    # at their open-site (see Runner#oast_generate) rather than as a refusal.

    # An action needing one provider has more than one candidate — the open-site's cue to open
    # OastProviderPicker instead of calling the action straight through.
    def provider_pick_needed? : Bool
      @payload_pick == 0 && enabled_providers.size > 1
    end

    # The enabled providers as picker rows, in the Providers sub-tab's order.
    def provider_pick_rows : Array(OastProviderPicker::Row)
      enabled_providers.map do |p|
        OastProviderPicker::Row.new(
          key: p.key,
          name: p.name,
          kind: Oast::ProviderKind.parse?(p.kind).try(&.label) || p.kind,
          host: p.host,
          scope: p.global? ? "global" : "project",
          live: !listener_for(p.key).nil?)
      end
    end

    # Point the payload bar at the provider the card committed. Addressed BY KEY, never by the
    # card's row index: the enabled list is re-formed on every reload/soft-sync — a peer process
    # toggling a provider is enough — so an index captured when the card opened can name a
    # different provider by the time ↵ lands. false when it is gone (the caller must not act).
    def select_provider(key : String) : Bool
      idx = enabled_providers.index { |p| p.key == key }
      unless idx
        @host.status("that provider is gone or was disabled — pick another")
        return false
      end
      @payload_pick = idx + 1
      # The pick also NARROWS the callbacks table (filtered_callbacks keys off @payload_pick),
      # so the row cursor can now sit past the end of a shorter list — the same reason
      # cycle_provider clamps. Unclamped, the table draws no highlighted row and ↵ / ⇧F go inert
      # until the operator happens to press an arrow key.
      clamp_selection
      true
    end

    # Both answer whether the pick RESOLVED, which is what the picker card's on_commit returns:
    # a key that no longer names an enabled provider must leave the card up, with something left
    # to pick, rather than close it onto a status line the operator can no longer act on.
    def generate_payload_with(key : String) : Bool
      return false unless select_provider(key)
      generate_payload
      true
    end

    def start_listening_with(key : String) : Bool
      return false unless select_provider(key)
      start_listening_action
      true
    end

    # Collapse the All position onto the only enabled provider there is. A no-op when there are
    # none (nothing to resolve) or several (an operator question — see provider_pick_needed?).
    private def resolve_single_provider : Nil
      return unless @payload_pick == 0 && enabled_providers.size == 1
      @payload_pick = 1
      clamp_selection # narrows the table, exactly as select_provider does
    end

    # Why an action found no provider to run against. Nothing enabled is a different problem
    # from an unresolved All, and telling an operator with no providers to "pick one" sends
    # them to a bar that has nothing on it.
    private def no_provider_status(action : String) : String
      return "no enabled provider — add one in the Providers tab" if enabled_providers.empty?
      "pick a provider to #{action} — ‹/› on the bar"
    end

    # =========================================================================
    # Actions (also reachable as verbs / space menu)
    # =========================================================================

    # Get an OAST payload for the picked provider: generate locally if a listener already
    # exists, else start listening (register off-fiber) and deliver the payload when ready.
    def generate_payload : Nil
      resolve_single_provider
      prov = picked_provider
      return @host.status(no_provider_status("generate a payload")) unless prov
      if listener = listener_for(prov.key)
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
      resolve_single_provider
      prov = picked_provider
      return @host.status(no_provider_status("listen")) unless prov
      if listener_for(prov.key)
        @host.status("already listening with #{prov.name}")
      else
        start_listening(prov, want_payload: false)
      end
    end

    # `^X` keeps the bar as its selector — its rows would be the LIVE listeners, not the enabled
    # providers, and an All that meant "stop everything" is a behaviour change, not a prompt.
    # It still gets the single-provider collapse, so the one-provider project never sees a
    # "select a provider" that has only one answer.
    def stop_listening : Nil
      resolve_single_provider
      prov = picked_provider
      return @host.status(no_provider_status("stop listening")) unless prov
      listener = listener_for(prov.key)
      return @host.status("not listening with #{prov.name}") unless listener
      stop_listener(listener)
      @host.status("stopped listening with #{prov.name} — session kept, resume it with `r`")
    end

    # Stop every live listener on a project-level exit (leave project / quit). A listener
    # is an `:oast` job like any other, so it answers `Jobs#any_active?` and is named in the
    # leave confirm — leaving it polling a third-party provider from a project the operator
    # believes they closed is the same defect as a crawl that keeps sending. Reuses
    # stop_listener, so quitting keeps the sessions resumable exactly as an explicit stop does.
    # Iterates a COPY: stop_listener deletes from @listeners.
    def stop_all : Nil
      @listeners.dup.each { |l| stop_listener(l) }
    end

    private def start_listening(prov : Oast::ProviderConfig, want_payload : Bool) : Nil
      # A register round-trip takes a few seconds and only appends the Listener on the
      # drain tick AFTER it returns, so listener_for is nil the whole time. Without an
      # in-flight guard a second g/^R spawns a duplicate register → two sessions, two
      # Listeners and two poller fibers for one provider. Dedup on the provider key.
      key = prov.key
      return @host.status("already registering with #{prov.name}…") if @registering.includes?(key)
      kind = Oast::ProviderKind.parse?(prov.kind)
      return @host.status("unknown provider type #{prov.kind}") unless kind
      provider = Oast::Provider.build(kind, prov.host, prov.token)
      http = Oast::HttpClient.new(verify_tls: !@host.session.config.insecure_upstream?)
      reg = @reg_events
      label = prov.name
      db_id = prov.project_id
      @registering << key
      spawn(name: "gori-oast-register") do
        session = provider.register(http)
        reg.send(RegOk.new(session, provider, key, db_id, label, want_payload))
      rescue ex
        reg.send(RegErr.new(ex.message || "register failed", label, key))
      end
      @host.status("registering with #{label}…")
    end

    # =========================================================================
    # Persisted sessions (resume / release)
    # =========================================================================

    # Every persisted session of this project, newest first, as the resume picker's rows.
    # Newest first because a session list is read as a stack: the one you were just using is
    # the one you want back.
    def session_rows : Array(OastSessionPicker::Row)
      live = @listeners.select(&.active?).map(&.session.id).to_set
      @host.session.store.oast_sessions.reverse.map do |s|
        OastSessionPicker::Row.new(
          session_id: s.id,
          provider: @session_label[s.id]? || provider_label_for(s),
          payload_host: payload_host_for(s),
          started_at: Time.unix(s.created_at // 1_000_000),
          hits: callbacks_for(s.id),
          live: live.includes?(s.id))
      end
    end

    # Re-arm a persisted session and start polling it again. The network half (`resume`) runs
    # off the main fiber and lands back through the SAME @reg_events channel a fresh register
    # uses, so a resume and a register can never race into two listeners for one provider.
    def resume_session(session_id : Int64) : Nil
      rec = @host.session.store.get_oast_session(session_id)
      return @host.status("session ##{session_id} is gone") unless rec
      return @host.status("already listening on session ##{session_id}") if @listeners.any? { |l| l.active? && l.session.id == session_id }
      kind = Oast::ProviderKind.parse?(rec.kind)
      return @host.status("session ##{session_id} names an unknown provider type #{rec.kind}") unless kind

      # A listener is addressed BY ITS PROVIDER everywhere else in this tab — ^X, `g` and the
      # payload picker all resolve through `listener_for(picked_provider.key)` — so a resumed
      # session must land under a provider key or it would be a poller the operator could see
      # and never stop.
      config = provider_config_for(rec)
      unless config
        return @host.status("session ##{session_id}'s provider is gone — re-add #{rec.kind} #{rec.server_url} in Providers to resume it")
      end
      key = config.key
      return @host.status("already registering with #{config.name}…") if @registering.includes?(key)
      # ONE listener per provider key, the invariant `listener_for` rests on. Resuming a second
      # session of a provider that is already listening would put two Listeners under one key,
      # and every lookup after that — stop, generate, the job note — would silently pick one.
      if listener_for(key)
        return @host.status("already listening with #{config.name} — stop it first (^X)")
      end

      session = session_from_record(rec)
      # The HOST comes from the session, never from the provider config: the session's secrets
      # only mean anything to the server that minted them, and a provider whose host was edited
      # since would send this correlation id somewhere that has never heard of it. The TOKEN
      # does prefer the config — it is a credential, and a rotated one is the live one.
      provider = Oast::Provider.build(kind, rec.server_url, config.token || rec.token)
      label = config.name
      http = poll_http
      reg = @reg_events
      db_id = config.project_id
      @registering << key
      spawn(name: "gori-oast-resume") do
        provider.resume(http, session)
        reg.send(RegOk.new(session, provider, key, db_id, label, false, resumed: true))
      rescue ex
        reg.send(RegErr.new(ex.message || "resume failed", label, key))
      end
      @host.status("resuming #{label} session ##{session_id}…")
    end

    # Deregister a session's server-side state, stopping its poller first if it is live. The
    # local row and every callback it collected stay — this releases the LISTENER, not the
    # evidence, and an operator who wanted the findings gone would say so on the Issues tab.
    def release_session(session_id : Int64) : Nil
      rec = @host.session.store.get_oast_session(session_id)
      return @host.status("session ##{session_id} is gone") unless rec
      if listener = @listeners.find { |l| l.session.id == session_id }
        stop_listener(listener, release: true)
      else
        kind = Oast::ProviderKind.parse?(rec.kind)
        return @host.status("session ##{session_id} names an unknown provider type #{rec.kind}") unless kind
        config = provider_config_for(rec)
        deregister(Oast::Provider.build(kind, rec.server_url, config.try(&.token) || rec.token),
          session_from_record(rec))
      end
      @host.status("released session ##{session_id} — its callbacks stay")
    end

    # Rebuild the engine Session from its row, and re-resolve the provider it belongs to.
    # Both live in `Oast::Sessions` — the surface-free half of this controller — because
    # `gori run oast` and the MCP oast_* tools resume the same rows and must rebuild them
    # identically (a session whose secrets or endpoint were reconstructed differently on one
    # surface would poll a correlation id the server has never heard of).
    private def session_from_record(rec : Store::OastSessionRecord) : Oast::Session
      Oast::Sessions.session_from_record(rec)
    end

    private def provider_config_for(rec : Store::OastSessionRecord) : Oast::ProviderConfig?
      Oast::Sessions.config_for(rec, @providers)
    end

    # What the operator recognises a session BY: the host its payloads point at. That is the
    # session's own server_url host for every provider whose payload is a URL, and the
    # interactsh server host for the one whose payload is a bare DNS name — which is what
    # `Session#host` already computes, so build one and ask it.
    private def payload_host_for(rec : Store::OastSessionRecord) : String
      session_from_record(rec).host
    end

    private def listener_for(provider_key : String?) : Listener?
      return nil unless provider_key
      @listeners.find { |l| l.provider_key == provider_key && l.active? }
    end

    # Stop polling. `release` is what separates "I'm done watching for now" from "I'm done
    # with this engagement".
    #
    # It defaults to FALSE, and that default is the whole resume feature. Stopping used to
    # deregister unconditionally, which for interactsh tells the server to forget the
    # correlation id — so every payload already planted stopped resolving the moment the
    # operator pressed ^X, and quitting gori (stop_all) did the same to every session at once.
    # For the one workbench whose findings arrive HOURS after the request that caused them,
    # that turned a normal exit into evidence destruction. Now the server state outlives the
    # poll fiber, and `resume_session` picks it back up.
    #
    # Release stays reachable — it is the honest counterpart, and leaving state on a public
    # third-party interaction server after an engagement is its own hygiene problem — but it
    # is now something the operator ASKS for, from the resume picker's `x`.
    private def stop_listener(listener : Listener, release : Bool = false) : Nil
      listener.poller.try(&.stop)
      @host.jobs.finish(listener.job_id, :stopped, "stopped") if listener.job_id != 0
      deregister(listener.provider, listener.session) if release
      @listeners.delete(listener)
    end

    # Best-effort release of server-side state, off the main fiber. `Provider#deregister` is
    # documented never to raise, and the `rescue nil` is the belt to that braces: this runs
    # detached, where an exception would take out the fiber with no one to report to.
    private def deregister(provider : Oast::Provider, session : Oast::Session) : Nil
      http = poll_http
      spawn(name: "gori-oast-deregister") { provider.deregister(http, session) rescue nil }
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
      @host.open_oast_provider_editor(nil)
    end

    def open_edit_provider : Nil
      return @host.status("no provider selected") unless p = selected_provider
      @host.open_oast_provider_editor(p)
    end

    def toggle_provider : Nil
      return unless p = selected_provider
      on = !p.enabled
      p.global? ? Settings.set_oast_provider_enabled(p.id, on) : @host.session.store.set_oast_provider_enabled(p.project_id.not_nil!, on)
      reload
    end

    def delete_provider : Nil
      return unless p = selected_provider
      @host.confirm("DELETE PROVIDER", "Delete OAST provider “#{p.name}”?\nIts callback history is kept.",
        confirm_label: "delete", danger: true) do
        if l = @listeners.find { |ls| ls.provider_key == p.key }
          stop_listener(l)
        end
        p.global? ? Settings.delete_oast_provider(p.id) : @host.session.store.delete_oast_provider(p.project_id.not_nil!)
        reload
      end
    end

    # Called back by the runner when the provider overlay commits. Returns false (keep the
    # form open) when invalid. A scope change on edit moves the provider between the global
    # library and the project DB (mirrors ProbeController#apply_custom_rule) — its prior
    # enabled state is carried over (not reset to on), and any listener still keyed to the
    # OLD scope/id is stopped first (mirrors delete_provider), since the move mints a fresh
    # key that nothing could ever reach it under again otherwise.
    def save_provider(ov : OastProviderOverlay) : Bool
      return false unless ov.valid?
      store = @host.session.store
      if id = ov.edit_id
        old = @providers.find { |p| p.scope == ov.edit_scope && p.id == id }
        prev_enabled = old.try(&.enabled)
        prev_enabled = true if prev_enabled.nil?
        if ov.scope == ov.edit_scope
          if ov.scope == "global"
            Settings.update_oast_provider(id, ov.provider_name, ov.kind.label, ov.host, ov.token)
          else
            store.update_oast_provider(id.to_i64, ov.provider_name, ov.kind.label, ov.host, ov.token, prev_enabled)
          end
        else
          if old && (l = @listeners.find { |ls| ls.provider_key == old.key })
            stop_listener(l)
          end
          ov.edit_scope == "global" ? Settings.delete_oast_provider(id) : store.delete_oast_provider(id.to_i64)
          insert_provider(store, ov, prev_enabled)
        end
        @host.status("updated provider #{ov.provider_name}")
      else
        insert_provider(store, ov, true)
        @host.status("added provider #{ov.provider_name}")
      end
      reload
      true
    end

    private def insert_provider(store : Store, ov : OastProviderOverlay, enabled : Bool) : Nil
      if ov.scope == "global"
        Settings.add_oast_provider(ov.provider_name, ov.kind.label, ov.host, ov.token, enabled)
      else
        project_count = @providers.count { |p| !p.global? }
        store.insert_oast_provider(ov.provider_name, ov.kind.label, ov.host, ov.token, enabled, project_count)
      end
    end

    private def selected_provider : Oast::ProviderConfig?
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
        subtab_labels, @active_sub, @subtab_start,
        find: subtab_find_shown?, find_lit: @host.subtab_find_focused?) do |content|
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
      ep = enabled_providers
      x = rect.x + 1
      x = screen.text(x, rect.y, "provider ", Theme.muted, Theme.panel)
      name = if ep.empty?
               "‹ none — add one › "
             elsif @payload_pick == 0
               "‹ All ›"
             else
               prov = ep[@payload_pick - 1]?
               prov ? "‹ #{prov.name} ›" : "‹ unknown ›"
             end
      listening = if @payload_pick == 0
                    @listeners.any?(&.active?) ? "  ●listening" : ""
                  else
                    prov = ep[@payload_pick - 1]?
                    prov && listener_for(prov.key) ? "  ●listening" : ""
                  end
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
      # A capped pane must SAY it is capped. Once the window has evicted, a bare count is the
      # worst of both: `2000` stands still while callbacks keep arriving, reading as "nothing
      # new" in the one tab whose whole job is evidence. Name the window, the total behind it,
      # and where the rest went.
      held = @evicted > 0 ? "#{@callbacks.size} of #{@callbacks.size + @evicted}" : @callbacks.size.to_s
      title = filtering ? "CALLBACKS (#{ordered.size}/#{held})" : "CALLBACKS (#{held})"
      title += " · #{@evicted} older kept in the project DB" if @evicted > 0
      Frame.card(screen, rect, title, border: focused ? Theme.focus_gold : Theme.border, bg: Theme.bg)
      inner = rect.inset(1, 1)
      if ordered.empty?
        # A FILTERED miss keeps its line. The card explains how the tab works, and an operator
        # who has typed a query already knows — what they need is the query back and the
        # eviction caveat below it, neither of which a card would say.
        unless filtering
          TrafficEmptyState.render(screen, inner, variant: :oast,
            has_provider: !enabled_providers.empty?)
          return
        end
        screen.text(inner.x + 1, inner.y, "no callbacks match “#{@filter.value.strip}” — esc to clear",
          Theme.muted, Theme.bg, width: inner.w - 2)
        # A no-match over a WINDOW is not a no-match over the evidence. Unqualified, the
        # operator filters for the source IP they care about, reads "no match", and concludes
        # it never hit — when the row is sitting in the table the filter never saw. Its OWN row
        # (not appended to the message) so it survives the width clamp on an 80-column terminal,
        # where a tacked-on clause is exactly the part that gets cut.
        if @evicted > 0 && inner.h > 1
          screen.text(inner.x + 1, inner.y + 1,
            "filter covers the newest #{@callbacks.size} only — #{@evicted} older are in the project DB",
            Theme.yellow, Theme.bg, width: inner.w - 2)
        end
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
      # the wheel, neither of which advances the viewport downward on its own). `ordered` is
      # the filtered, newest-first projection this loop slices — `callback_row_at` runs the
      # SAME call against the same list so the hit-test inverts this window exactly.
      @cb_scroll = Viewport.scroll_to_show(@cb_sel, @cb_scroll, visible, ordered.size)
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
      sync_cb_pane(row)
      @cb_pane.render(screen, Rect.new(body.x + 1, body.y, {body.w - 2, 0}.max, body.h), focused)
    end

    # The raw callback as text: request, then the response when the provider captured one. The
    # copy payload and the caret's coordinate system, in one place so the draw and a `y` cannot
    # disagree about what "this callback" is.
    private def cb_detail_text(row : CbRow) : String
      row.raw_response ? "#{row.raw_request}\n\n--- response ---\n#{row.raw_response}" : row.raw_request
    end

    private def sync_cb_pane(row : CbRow) : Nil
      @cb_pane.source(cb_detail_text(row).split('\n'))
    end

    # Run `blk` with the detail pane pointed at the open callback. Every gesture and every verb
    # goes through it, so none can act on a pane sourced from a different row.
    private def with_cb_pane(&) : Nil
      return unless @cb_detail
      row = selected_callback || return
      sync_cb_pane(row)
      yield
    end

    private def render_providers(screen : Screen, rect : Rect, focused : Bool) : Nil
      Frame.card(screen, rect, "PROVIDERS", border: Frame.pane_border(focused), bg: Theme.bg)
      Frame.border_meta(screen, rect, "PROVIDERS", @providers.size.to_s)
      inner = rect.inset(1, 1)
      if @providers.empty?
        screen.text(inner.x + 1, inner.y, "no providers — press a to add one (interactsh is prefilled)", Theme.muted, Theme.bg, width: inner.w - 2)
        return
      end
      screen.text(inner.x + 2, inner.y, "NAME", Theme.muted, Theme.bg)
      screen.text(inner.x + 19, inner.y, "SCOPE", Theme.muted, Theme.bg)
      screen.text(inner.x + 27, inner.y, "TYPE", Theme.muted, Theme.bg)
      screen.text(inner.x + 41, inner.y, "HOST", Theme.muted, Theme.bg)
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
        screen.text(rows.x + 2, py, p.name, sel ? Theme.text_bright : Theme.text, bg, width: 16)
        screen.text(rows.x + 19, py, p.global? ? "GLOBAL" : "PROJECT", p.global? ? Theme.yellow : Theme.muted, bg, width: 7)
        kind_label = Oast::ProviderKind.parse?(p.kind).try(&.label) || p.kind
        screen.text(rows.x + 27, py, kind_label, Theme.accent, bg, width: 13)
        hw = {rows.right - 10 - (rows.x + 41), 6}.max
        screen.text(rows.x + 41, py, p.host, Theme.text, bg, width: hw)
        listening = @listeners.any? { |l| l.provider_key == p.key && l.active? }
        badge = p.enabled ? (listening ? "● live" : "on") : "off"
        screen.text(rows.right - 8, py, badge, p.enabled ? Theme.green : Theme.muted, bg)
      end
    end

    # Keep @prov_sel within the visible provider window (both directions), then clamp — so a
    # selection taller than the pane scrolls into view instead of vanishing off the bottom.
    private def sync_prov_scroll(visible : Int32) : Nil
      @prov_scroll = Viewport.scroll_to_show(@prov_sel, @prov_scroll, visible, @providers.size)
    end

    private def selected_callback : CbRow?
      ordered_callbacks[@cb_sel]?
    end

    # The callbacks in display order (newest first), narrowed by the filter. Memoized on
    # (callbacks version, filter) so the per-render reverse — and the filter scan below — run
    # once per change instead of several times each render frame + drain tick. `@callbacks`
    # stays the master store so live inserts still land and simply re-filter next version.
    private def ordered_callbacks : Array(CbRow)
      key = {@cb_version, @filter.value, @payload_pick}
      if (cached = @ordered_cache) && @ordered_cache_key == key
        return cached
      end
      result = filtered_callbacks.reverse
      @ordered_cache = result
      @ordered_cache_key = key
      result
    end

    private def filtered_callbacks : Array(CbRow)
      key = {@cb_version, @filter.value, @payload_pick}
      if (cached = @filtered_cache) && @filtered_cache_key == key
        return cached
      end
      ep = enabled_providers
      selected_prov = (@payload_pick > 0 && @payload_pick <= ep.size) ? ep[@payload_pick - 1] : nil
      base_list = if prov = selected_prov
                    @callbacks.select { |r| r.provider == prov.name }
                  else
                    @callbacks
                  end
      q = @filter.value.strip.downcase
      result = q.empty? ? base_list : base_list.select { |r| callback_matches?(r, q) }
      @filtered_cache = result
      @filtered_cache_key = key
      result
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
        when key.escape?, key.left?, key.lower_h?
          @cb_detail = false
        when key.up?, key.lower_k?
          # At the top the ↑ still closes the detail and leaves; below it the caret steps, so
          # ⇧↑ can grow a selection the way it does in every other read pane.
          if @cb_pane.at_top?
            @cb_detail = false
            @host.request_focus(:subtabs)
          else
            with_cb_pane { @cb_pane.move(-1, 0, selecting: ev.shift?) }
          end
        when key.down?, key.lower_j? then with_cb_pane { @cb_pane.move(1, 0, selecting: ev.shift?) }
        else
          with_cb_pane { @cb_pane.motion_key(ev) } # Home / End / PgUp / PgDn, ⇧ extending
          return true
        end
        return true
      end
      case
      when key.escape?             then @host.request_focus(:subtabs)
      when key.up?, key.lower_k?   then cb_row_up
      when key.down?, key.lower_j? then @cb_sel = {@cb_sel + 1, {filtered_callbacks.size - 1, 0}.max}.min
      when key.left?               then cycle_provider(-1)
      when key.right?              then cycle_provider(1)
      when key.enter?
        if selected_callback
          @cb_detail = true
          @cb_pane.reset # a different callback renumbers every line
        end
      when c == 'y' then copy_payload
        # `g` (get payload), `r` (resume) and `a` (add issue) are NOT claimed here: each can open
        # an overlay, which a controller cannot do, so they stay verbs with plain chords and reach
        # the keymap through the `return false` below — the same fall-through every unhandled key
        # takes. `g` used to be claimed here, back when its only "All" answer was a status line.
      else return false
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
      when c == 'x'                then toggle_provider
      when c == 'd'                then delete_provider
      else                              return false
      end
      true
    end

    private def cycle_provider(dir : Int32) : Nil
      ep = enabled_providers
      return if ep.empty?
      total_choices = ep.size + 1
      @payload_pick = (@payload_pick + dir) % total_choices
      clamp_selection
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
      ep = enabled_providers
      @payload_pick = @payload_pick.clamp(0, ep.empty? ? 0 : ep.size)
    end

    def handle_click(rect : Rect, mx : Int32, my : Int32) : Bool
      @host.focus_body
      content = BodyChrome.content_rect(rect, strip: true)
      if callbacks_sub?
        click_callbacks(content, mx, my)
      else
        click_providers(content, mx, my)
      end
      true
    end

    # Callbacks list: filter bar starts `/` edit; rows use History/Probe select-first
    # (first click selects, second click on the selected row opens detail — same as ↵).
    # Detail view itself is key-driven (like Probe).
    private def click_callbacks(content : Rect, mx : Int32, my : Int32) : Nil
      return if @cb_detail
      return if content.h < 2
      # payload bar (2 rows) — no row action; body is the filter + table card below
      body = Rect.new(content.x, content.y + 2, content.w, content.h - 2)
      return if body.h < 1
      table = if body.h >= 2
                if my == body.y
                  start_cb_filter unless @filter_editing
                  return
                end
                Rect.new(body.x, body.y + 1, body.w, body.h - 1)
              else
                body
              end
      return unless idx = callback_row_at(table, mx, my)
      @filter_editing = false # a row click commits the filter, like History's list click
      if idx == @cb_sel
        @cb_detail = true
        @cb_pane.reset
      else
        @cb_sel = idx
        sync_scroll
      end
    end

    # Hit-test a click against the CALLBACKS table card (mirrors render_callback_table).
    private def callback_row_at(table : Rect, mx : Int32, my : Int32) : Int32?
      return nil if table.empty? || !table.contains?(mx, my)
      inner = table.inset(1, 1)
      rows = Rect.new(inner.x, inner.y + 1, inner.w, {inner.h - 1, 0}.max)
      return nil if rows.empty? || my < rows.y || my >= rows.bottom
      return nil if mx < rows.x || mx >= rows.right
      visible = rows.h
      return nil if visible <= 0
      ordered = ordered_callbacks
      # The SAME derivation render_callback_table runs, into a LOCAL — a hit-test must invert
      # the window, never move it (a click that scrolled the pane it is measuring would pick
      # the row that slid under the cursor).
      scroll = Viewport.scroll_to_show(@cb_sel, @cb_scroll, visible, ordered.size)
      abs = scroll + (my - rows.y)
      abs >= 0 && abs < ordered.size ? abs : nil
    end

    # Providers list: select-first; a second click on the selected row opens the editor (↵/e).
    private def click_providers(content : Rect, mx : Int32, my : Int32) : Nil
      return unless idx = provider_row_at(content, mx, my)
      if idx == @prov_sel
        open_edit_provider
      else
        @prov_sel = idx
      end
    end

    # Hit-test a click against the PROVIDERS table card (mirrors render_providers).
    private def provider_row_at(content : Rect, mx : Int32, my : Int32) : Int32?
      return nil if content.empty? || !content.contains?(mx, my)
      inner = content.inset(1, 1)
      rows = Rect.new(inner.x, inner.y + 1, inner.w, {inner.h - 1, 0}.max)
      return nil if rows.empty? || my < rows.y || my >= rows.bottom
      return nil if mx < rows.x || mx >= rows.right
      visible = rows.h
      return nil if visible <= 0
      # The SAME derivation `sync_prov_scroll` runs, into a LOCAL — see callback_row_at.
      scroll = Viewport.scroll_to_show(@prov_sel, @prov_scroll, visible, @providers.size)
      abs = scroll + (my - rows.y)
      abs >= 0 && abs < @providers.size ? abs : nil
    end

    def handle_wheel(step : Int32) : Bool
      if callbacks_sub?
        if @cb_detail
          with_cb_pane { @cb_pane.scroll_view(step) }
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
      # Pin the callback selection to the SAME callback across live inserts: each new callback
      # prepends to the newest-first display and shifts every index down, so a bare @cb_sel would
      # silently slide onto a neighbor (and flip an open detail). Capture its stable key, re-resolve.
      sel_key = selected_callback.try { |c| {c.session_id, c.uid} }
      n = 0
      inserted = false
      while n < DRAIN_CAP && (ev = nonblocking_callback)
        n += 1
        apply_callback(ev)
        applied = true
        inserted = true
      end
      reanchor_callback_selection(sel_key) if inserted && sel_key
      heartbeat_active_sessions
      applied
    end

    # Keep each live session's `last_poll_at` fresh so the probe OOB minter (Oast::StoreMinter)
    # can tell a session that is being polled from one that was started and stopped. Runs off-tab
    # too — drain_events is called every tick regardless of focus — which is the point: you start
    # a listener here, switch tabs, and a probe scan still mints against it. Throttled to
    # SESSION_HEARTBEAT and skipped entirely when nothing is listening, so an idle project writes
    # nothing. Does not mark the tick `applied`: it changes no on-screen state.
    private def heartbeat_active_sessions : Nil
      return if @listeners.empty?
      now = Time.instant
      return if now - @last_session_heartbeat < SESSION_HEARTBEAT
      @last_session_heartbeat = now
      store = @host.session.store
      @listeners.each { |l| store.touch_oast_session(l.session.id) if l.active? }
    end

    # Move @cb_sel back onto the callback identified by `key` after live inserts shifted the
    # display indices. No-op if it was filtered out (the clamp in render keeps @cb_sel in range).
    private def reanchor_callback_selection(key : {Int64, String}) : Nil
      if idx = ordered_callbacks.index { |c| {c.session_id, c.uid} == key }
        @cb_sel = idx
      end
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
      @registering.delete(reg.provider_key) # registration resolved (ok or err) — clear the in-flight guard
      case reg
      when RegErr
        @host.status("OAST register failed (#{reg.provider_label}): #{reg.message}")
      when RegOk
        unless @providers.any? { |p| p.key == reg.provider_key }
          # The provider was deleted or scope-migrated while the round trip was in flight — its
          # key no longer resolves to anything in @providers, so a Listener built from it
          # could never be found/stopped again. Drop the result rather than leak an
          # unreachable poller.
          #
          # A FRESH registration is also deregistered here, and only a fresh one: nothing about
          # it is worth keeping — it has no row, so the resume picker could never offer it, and
          # no payload was handed out. A RESUMED session is the opposite on every count. It has
          # a row, it has callbacks, and its payloads are planted out in the world right now;
          # releasing that server state because a provider row vanished mid-flight would throw
          # away exactly what the operator asked to get back. Re-add the provider and resume.
          deregister(reg.provider, reg.session) unless reg.resumed
          return @host.status("OAST #{reg.resumed ? "resume" : "register"} for #{reg.provider_label} finished after its provider was removed — discarded")
        end
        # A resume already HAS its row (see RegOk#resumed); only a fresh registration inserts.
        unless reg.resumed
          reg.session.id = @host.session.store.insert_oast_session(reg.db_provider_id,
            reg.session.kind.label, reg.session.server_url, reg.session.correlation_id,
            reg.session.secret, reg.session.private_key_pem, reg.session.token)
        end
        id = reg.session.id
        listener = Listener.new(reg.session, reg.provider, reg.provider_key, reg.provider_label)
        listener.job_id = @host.jobs.start(:oast, "OAST #{reg.provider_label}", goto: Jobs::Goto.new(:oast))
        poller = Oast::Poller.new(reg.provider, reg.session, poll_http, POLL_INTERVAL, @oast_events)
        listener.poller = poller
        poller.start
        @listeners << listener
        @seen[id] ||= Set(String).new
        @session_label[id] = reg.provider_label
        # Mark the session live NOW so a probe scan in the ≤SESSION_HEARTBEAT window before the
        # first heartbeat still mints against it rather than an older polled session.
        @host.session.store.touch_oast_session(id)
        if reg.want_payload
          deliver_payload(reg.provider.generate_payload(reg.session))
        elsif reg.resumed
          # Name the hits already on file. A resume that only said "listening" would look
          # identical to a fresh register, and the whole point of the action is that this
          # session has a history — and payloads still out there — that a new one does not.
          @host.status("resumed #{reg.provider_label} session ##{id} (#{callbacks_for(id)} callbacks so far)")
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
        @hits[sid] = (@hits[sid]? || 0) + 1
        label = @session_label[sid]? || "oast"
        store = @host.session.store
        # Persist the interaction's OWN time (not now) so a callback shows the same timestamp
        # live and after a reload (created_at is microseconds; cb_row divides back to seconds).
        store.insert_oast_callback(sid, i.unique_id, i.protocol, i.method, i.source_ip,
          i.full_id, i.raw_request.to_slice, i.raw_response.try(&.to_slice), i.at.to_unix_ms * 1000)
        @callbacks << CbRow.new(sid, i.unique_id, i.protocol, i.method, i.source_ip, i.full_id,
          label, i.at, i.raw_request, i.raw_response)
        trim_callbacks
        announce_window_cap
        @cb_version += 1
        n = @listeners.find { |l| l.session.id == sid }
        @host.jobs.progress(n.job_id, nil, nil, "#{callbacks_for(sid)} hits") if n
        @host.notifications.push(:success, "OAST #{i.protocol.upcase} hit on #{label} (#{i.source_ip || "?"})",
          Jobs::Goto.new(:oast), source: "oast")
      end
    end

    # Say it ONCE, the first time a LIVE callback pushes a row off the window. The standing
    # marker in the CALLBACKS title only reaches an operator who is looking at the tab, and
    # the callbacks that get evicted are precisely the ones that arrived while they were
    # somewhere else — a cap the operator can only discover by noticing an absence is a silent
    # cap. Live path only, and not because reload's trim is less real — a cold open of a
    # project whose table already holds more than CALLBACK_CAP evicts too — but because that
    # operator is LOOKING at the pane and its title already carries the marker, while pushing a
    # note from `reload` would mean touching @host.notifications during construction. The flag
    # is sticky across reloads so a tab revisit cannot re-fire it.
    private def announce_window_cap : Nil
      return if @evict_announced || @evicted == 0
      @evict_announced = true
      @host.notifications.push(:warn,
        "OAST callbacks pane now shows the newest #{CALLBACK_CAP} — older ones stay in the project DB",
        Jobs::Goto.new(:oast), source: "oast")
    end

    # The hit count in the job note is the session's TOTAL, so it is counted separately rather
    # than read off @seen#size: @seen is now windowed (trim_callbacks drops evicted uids), and
    # a listener whose counter walked BACKWARDS as it kept receiving would be worse than no
    # counter. One Int32 per session, so it costs nothing the labels don't already cost.
    private def callbacks_for(sid : Int64) : Int32
      @hits[sid]? || 0
    end

    private def poll_http : Oast::Http
      Oast::HttpClient.new(verify_tls: !@host.session.config.insecure_upstream?)
    end

    # Notification "jump to result" lands on this tab (no per-row reveal needed).
    def reveal_session(id : Int64) : Nil
      @active_sub = 0
      @host.focus_body
    end

    # =========================================================================
    # Promote a callback to an Issue
    # =========================================================================

    # True when there is a callback to file an issue from — the verb's gate. Deliberately NOT
    # gated on the detail being open: the list row is the natural place to decide a callback
    # is real, and the drill-in is one ↵ further in.
    def callback_selected? : Bool
      callbacks_sub? && !selected_callback.nil?
    end

    # Prefill the NEW ISSUE form from the selected callback. A callback is the strongest
    # evidence this tool produces — the target's own infrastructure reached a server it had no
    # business reaching — and until now the only way to record one was to retype it: the tab
    # could copy the payload out and the raw interaction out, but not turn either into a
    # finding. The guide has linked "promote a confirmed callback into an Issue" the whole
    # time; this is that link.
    def callback_issue_draft : IssueDraft?
      row = selected_callback
      return nil unless row
      IssueDraft.new(issue_title_for(row), nil, issue_notes_for(row))
    end

    # "OAST DNS callback from 203.0.113.5" — protocol and source, the two facts that make the
    # finding legible in a list. Falls back to the destination when the provider reports no
    # source IP (webhook.site and postbin both can), so the title never trails off into "from".
    private def issue_title_for(row : CbRow) : String
      what = "OAST #{row.protocol.upcase} callback"
      if src = row.source.presence
        "#{what} from #{src}"
      else
        "#{what} on #{row.destination}"
      end
    end

    private def issue_notes_for(row : CbRow) : String
      String.build do |io|
        io << "Out-of-band callback received by gori's OAST listener.\n\n"
        io << "protocol:    " << row.protocol
        row.method.try { |m| io << " (" << m << ")" }
        io << '\n'
        io << "source:      " << (row.source.presence || "unknown") << '\n'
        io << "destination: " << row.destination << '\n'
        io << "provider:    " << row.provider << '\n'
        io << "received:    " << row.at.to_rfc3339 << '\n'
        evidence_section(io, "raw request", row.raw_request)
        row.raw_response.try { |r| evidence_section(io, "raw response", r) }
      end
    end

    # One fenced evidence block, truncated at EVIDENCE_CAP and SAYING so when it truncates —
    # evidence that was silently cut is evidence you can draw the wrong conclusion from.
    private def evidence_section(io : IO, label : String, body : String) : Nil
      return if body.empty?
      io << "\n--- " << label << " ---\n"
      if body.bytesize > EVIDENCE_CAP
        # byte_slice, not `body[0, n]`: a raw interaction is bytes off the wire that were
        # never promised to be UTF-8, and `scrub` puts it back in a shape the notes column
        # and the Markdown export can both hold.
        io << body.byte_slice(0, EVIDENCE_CAP).scrub
        io << "\n… truncated at " << EVIDENCE_CAP << " bytes (full callback kept in the OAST tab)\n"
      else
        io << body.scrub
        io << '\n' unless body.ends_with?('\n')
      end
    end

    # --- READ-pane delegators (the callback detail's read verbs + the Runner's read_* ladders) ---
    def oast_detail_readable? : Bool
      callbacks_sub? && @cb_detail && !selected_callback.nil?
    end

    def oast_detail_selection_active? : Bool
      @cb_detail && @cb_pane.selection?
    end

    def oast_detail_selection_text : String
      row = selected_callback
      return "" unless row && callbacks_sub? && @cb_detail
      sync_cb_pane(row)
      @cb_pane.copy_text
    end

    def oast_detail_select_line : Nil
      with_cb_pane { @cb_pane.select_line }
    end

    def oast_detail_clear_selection : Nil
      @cb_pane.clear_selection
    end

    # `y` inside the detail: the selection, or the whole callback. Distinct from the list's `y`,
    # which copies the PAYLOAD gori generated — the two are the opposite directions of the same
    # interaction, and an evidence tool must let you take what came BACK.
    def oast_detail_copy : Nil
      row = selected_callback
      return unless row && callbacks_sub? && @cb_detail
      sync_cb_pane(row)
      sel = @cb_pane.selection?
      text = sel ? @cb_pane.copy_text : @cb_pane.copy_all
      return if text.empty?
      written = Clipboard.copy(text)
      note = Clipboard.note(written, text)
      @host.status(sel ? "copied #{written}b to clipboard#{note}" : "copied all (#{written}b)#{note}")
    end
  end
end
