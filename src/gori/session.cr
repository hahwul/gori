require "./config"
require "./bind_address"
require "./project"
require "./capture_lock"
require "./capture_status"
require "./store"
require "./rules"
require "./colormarker"
require "./scope"
require "./host_overrides"
require "./env"
require "./interceptor"
require "./probe"
require "./proxy/server"
require "./proxy/tls/cert_authority"
require "./proxy/tls/tunnel"
require "./verb"

module Gori
  # An open project: its SQLite store, the proxy capturing into it, and the
  # flow-notification channel. The CA and verb registry are shared across
  # sessions (passed in). Opening starts the proxy; closing stops it, drains the
  # store, and removes the workspace if the project is ephemeral.
  class Session
    getter config : Config
    getter ca : Proxy::Tls::CertAuthority
    getter registry : Verb::Registry
    getter project : Project
    getter store : Store
    getter proxy : Proxy::Server
    getter tunnel : Proxy::Tls::Tunnel
    getter flow_events : Channel(Store::FlowEvent)
    # The Authorize tab's live feed. A third channel because a Crystal Channel is
    # single-consumer; nothing drains it until passive replay is switched on, and the store's
    # publish drops on a full channel, so an idle feed costs nothing.
    getter authorize_events : Channel(Store::FlowEvent)
    # The passive/active scanner. Subscribes to the store's parallel probe_events feed and
    # writes grouped issues; runs for both the TUI and headless capture.
    getter probe : Probe::Analyzer
    getter rules : Rules
    # Session bindings (#501): the persisted extract rules plus the IN-MEMORY name→value
    # table they write. Same "shared: proxy reads, TUI edits (Mutex-guarded)" contract as
    # `rules`, and the same lifetime — the values are gone when the project closes, which
    # is the point (a restored token is stale by construction).
    getter bindings : Bindings
    # The project's session slots plus the active one. Shared exactly as `rules` and
    # `bindings` are — one live object, Mutex-guarded — because "which identity am I sending
    # as" has to be one answer across the Authorize tab, a Repeater send and the proxy's
    # intercept forward, not one per surface.
    getter slots : SessionSlots
    getter scope : Scope
    getter host_overrides : HostOverrides
    getter interceptor : Interceptor
    # Which History rows get painted, and how (display only). Shared the way `scope` and
    # `host_overrides` are — one live object every reader holds, Mutex-guarded — so an external
    # edit lands in one place and History repaints from it.
    #
    # Built here from `@store` alone rather than threaded through `open`, because that is its
    # only dependency, and deliberately NOT passed to `Proxy::Server` / `Tls::Tunnel` /
    # `build_listener`: a colour rule never touches a byte on the wire, so a listener has no
    # business naming it.
    getter colormarker : Colormarker
    # Why the live proxy isn't listening (e.g. "port in use"), or nil when capture
    # is up. The project still opens for History/Repeater/Sitemap/etc. — only live
    # capture needs the bind — so a bind failure is non-fatal.
    getter bind_error : String?

    def self.open(config : Config, ca : Proxy::Tls::CertAuthority,
                  registry : Verb::Registry, project : Project,
                  bind_fallback : Bool = false) : Session
      events = Channel(Store::FlowEvent).new(1024)
      probe_events = Channel(Store::FlowEvent).new(256)
      authorize_events = Channel(Store::FlowEvent).new(256)
      store = Store.open(project.db_path, events, probe_events, Settings.retention_flows,
        authorize_events: authorize_events)
      probe = nil.as(Probe::Analyzer?)
      begin
        # Per-project network overrides: pull this project's pinned bind/upstream (if any) into
        # the Settings runtime layer BEFORE binding, so the proxy listens on the project's address
        # and Upstream.dial (reads Settings.effective_upstream_proxy) tunnels through its upstream.
        # `bind: true` — a Session is the one surface that LISTENS (the TUI and `gori run capture`
        # both open the project this way), so all six keys apply here; the headless callers of
        # `CLI::Run.open_store` and the MCP bind path pass `bind: false`. Mutating `config` is
        # safe — App re-seeds it from the global Settings on every project open. Inside the begin
        # so a failing settings read is torn down below rather than leaking store+channels.
        Settings.load_project_network(store, bind: true)
        Env.load_project(store)
        config.listen = Settings.effective_bind_host
        config.port = Settings.effective_bind_port
        lock = nil.as(CaptureLock?)
        sink = Proxy::StoreSink.new(store)
        rules = Rules.load(store) # shared: proxy reads, TUI edits (Mutex-guarded)
        # Session slots: the project's named identities (header overlay + which extract rules
        # belong to them) and WHICH ONE is the active send context. Loaded before `bindings`
        # because the binding table is namespaced by it — see `Bindings#candidates`. The LIST
        # is the same persisted row the Authorize tab has always written; the ACTIVE pointer
        # starts nil (as-captured) on every open, because a slot's values are memory-only and
        # restoring a pointer into an empty table resolves nothing.
        slots = SessionSlots.load(store)
        bindings = Bindings.load(store, slots) # #501: extract rules persist, values stay in memory
        # Publish this project's binding table as `Env`'s send-time layer. A per-project
        # global, exactly like `Settings.project_env_vars` two lines up and for exactly the
        # same reason: `$SESSION` has to mean one thing in the Rewriter, in a Repeater tab,
        # in a Fuzzer template and in `--target` alike. Assigning here (rather than passing
        # the table to each sender) is what makes that true for a surface nobody remembered.
        Env.layer = bindings
        scope = Scope.load(store)                  # shared by the TUI lens AND intercept gating
        host_overrides = HostOverrides.load(store) # per-project /etc/hosts; proxy reads, TUI edits (Mutex-guarded)
        interceptor = Interceptor.new(scope)       # shared: proxy fibers hold, TUI decides
        # Passive/active scanner: reads the parallel probe_events feed, gates active probes on
        # the shared Scope. Runs headless too — but ONLY on the capture-lock holder (started
        # below), never on a view-only 2nd instance (which would send duplicate active probes to
        # targets and race issue-writes on the shared DB against the real capturer).
        probe = Probe::Analyzer.new(store, scope, probe_events, store.probe_mode, !config.insecure_upstream?)
        # `extractor: bindings` is the SECOND wiring of the same object and the one slice 2 is
        # about: `Env.layer` above makes `$SESSION` resolvable at send time, this makes proxy
        # traffic able to BIND it. Threaded explicitly rather than read off the `Env` global,
        # matching how `rewriter` and `interceptor` reach the same sockets — a listener built
        # anywhere else then has to name it, instead of inheriting it invisibly.
        tunnel = Proxy::Tls::Tunnel.new(ca, verify_upstream: !config.insecure_upstream?,
          rewriter: rules, interceptor: interceptor, host_overrides: host_overrides,
          serve_landing: Settings.serve_landing?, extractor: bindings)
        proxy = Proxy::Server.new(config.listen, config.port, sink, tls: tunnel,
          rewriter: rules, interceptor: interceptor, host_overrides: host_overrides,
          extractor: bindings)
        # ADDITIONAL listeners (settings.json "listeners"), sharing this project's sink, rules,
        # interceptor and host overrides — so a transparent listener captures into the same
        # project and obeys the same scope/sandbox as the primary. `proxy` above stays THE proxy
        # address for every surface that reports one; these are auxiliary sockets.
        #
        # Seeded with the entries `valid_listeners` DROPPED as unusable, so a misconfigured
        # listener reads the same as one that failed to bind rather than vanishing (the
        # operator's only other signal is traffic that never arrives).
        listener_errs = Settings.listener_config_errors
        extra = Settings.valid_listeners.map do |l|
          build_listener(l, sink, tunnel, rules, interceptor, host_overrides, bindings)
        end
        # Per-PROJECT capture lock decides whether THIS instance captures. A 2nd
        # instance of the SAME project can't acquire it → VIEW-ONLY (no 2nd port; it
        # live-refreshes off the shared DB). A DIFFERENT project has its own lock, so
        # it captures on its own port (the bind falls back when the configured port
        # is taken). The bind itself stays NON-FATAL: History/Repeater/Sitemap/Issues
        # all read the store / dial upstream directly and don't need the listener.
        bind_error =
          begin
            lock = CaptureLock.try_at(project.capture_lock_path)
            if lock
              begin
                proxy.start(fallback: bind_fallback)
                # Each extra listener binds independently: a transparent listener on a
                # privileged port failing must not stop capture on the primary, but the failure
                # is COLLECTED rather than swallowed — a redirect rule pointing at a socket that
                # never bound is invisible from the client's side.
                extra.each do |e|
                  e.server.start
                rescue ex
                  # BindAddress.authority, not bare interpolation: `listener_rows` matches a
                  # failure back to its server by this prefix, and a raw `::1` bind renders as
                  # the unparseable "::1:8070" (the same bug BindAddress exists to kill).
                  listener_errs << bind_failure(e.server, ex)
                end
                nil
              rescue ex
                # We own this project (hold the lock) but couldn't bind the listener
                # (port taken, fallback off/exhausted). Stay capture-off and KEEP the
                # lock — the user can free the port (settings) + press c to start
                # (toggle_capture reuses the held lock).
                ex.message || "could not bind #{config.listen}:#{config.port}"
              end
            else
              "another gori instance already holds this database's capture lock"
            end
          rescue ex
            # CaptureLock.try itself failed (can't create/open the lock file) — not a
            # bind issue; release anything we opened and report it.
            lock.try(&.close) rescue nil
            lock = nil
            ex.message || "could not open the project capture lock"
          end
        if lock
          # Sole capturer for this project: clear any Pending rows orphaned by a previous
          # session's crash/kill (nothing else will ever resolve them) before we capture, then
          # run the scanner. Both are gated on the lock so a view-only 2nd instance touches
          # neither the shared Pending rows nor the shared issue set.
          store.abandon_pending!("orphaned by a previous session")
          # #123: wipe any live-intercept snapshot / command rows a dead session left behind
          # (their per-session item ids no longer mean anything) before we start publishing.
          store.clear_intercept_state!
          probe.start
        end
        session = new(config, ca, registry, project, store, proxy, tunnel, events, probe, rules, bindings, slots, scope, host_overrides, interceptor, sink, authorize_events, bind_error, lock, extra, listener_errs)
        session.sync_capture_status!
        session
      rescue ex
        # A store/rules/scope failure (NOT the bind, which is handled above) would
        # otherwise leak the store's writer fiber + db fd, the events channels, the Probe
        # fibers, and the lock fd. Tear them down, then re-raise for the caller.
        # The binding layer is cleared with them: a half-opened project must not leave a
        # dangling table whose `$KEY`s the next surface would happily resolve.
        Env.layer = nil
        lock.try(&.close) rescue nil
        probe.try(&.stop) rescue nil
        store.close rescue nil
        events.close rescue nil
        probe_events.close rescue nil
        authorize_events.close rescue nil
        raise ex
      end
    end

    # One additional listener: the settings record it was built from, paired with the socket
    # serving it. Paired rather than kept in two index-aligned arrays because `reconcile_listeners!`
    # diffs the RECORDS to decide which sockets to touch, and a pairing that could slip would mean
    # restarting the wrong one — the exact failure the diff exists to avoid.
    record ExtraListener, spec : Settings::Listener, server : Proxy::Server

    # Build (but do not start) the socket for one listener entry. Shared by `open` and the live
    # reconcile so a listener added at runtime is wired to the same sink, TLS tunnel, rewriter,
    # interceptor, host overrides and binding table as one that was there at startup — a second
    # construction site is how a reconciled listener would quietly stop obeying the project's
    # scope (or, since #501 slice 2, quietly stop binding `$SESSION`).
    def self.build_listener(l : Settings::Listener, sink : Proxy::FlowSink,
                            tunnel : Proxy::Tls::Tunnel, rules : Rules,
                            interceptor : Interceptor,
                            host_overrides : HostOverrides,
                            bindings : Bindings) : ExtraListener
      ExtraListener.new(l, Proxy::Server.new(l.host, l.port, sink, tls: tunnel,
        rewriter: rules, interceptor: interceptor, host_overrides: host_overrides,
        transparent: l.transparent?, target_port: l.target_port,
        origin: l.origin_target, rewrite_host: l.rewrite_host, extractor: bindings))
    end

    # The one spelling of a bind failure. `listener_rows` matches a failure back to its server by
    # the address prefix, so open, capture-toggle and reconcile must all format it identically.
    def self.bind_failure(server : Proxy::Server, ex : Exception) : String
      "#{Gori::BindAddress.authority(server.host, server.port)} — #{ex.message || "could not bind"}"
    end

    # A random per-session token stamped on every #123 intercept snapshot/command row, so a
    # stale command from a prior session (whose interceptor item ids reset to 0) can never be
    # applied against a different new held item — the drain acks a token mismatch as stale.
    getter intercept_token : String

    def initialize(@config, @ca, @registry, @project, @store, @proxy, @tunnel, @flow_events, @probe,
                   @rules, @bindings, @slots, @scope, @host_overrides, @interceptor, @sink : Proxy::FlowSink,
                   @authorize_events : Channel(Store::FlowEvent),
                   @bind_error : String? = nil,
                   @capture_lock : CaptureLock? = nil,
                   @extra_listeners : Array(ExtraListener) = [] of ExtraListener,
                   @listener_errors : Array(String) = [] of String)
      @intercept_token = Random::Secure.hex(8)
      @listeners_applied = Settings.listeners.dup
      @colormarker = Colormarker.load(@store)
    end

    # True when the `listeners` section on disk no longer matches the one these sockets were
    # built from (#508) — i.e. there is an edit `reconcile_listeners!` has not applied yet.
    #
    # Compared against what this session last APPLIED, not against `Settings.listeners`: the
    # class property is the copy read at startup and is deliberately never refreshed (see
    # `Settings.listener_error`'s `among` for why writing it back would clobber hand edits), so
    # only the session knows which section its sockets currently answer to.
    def listeners_changed_on_disk? : Bool
      Settings.disk_listeners != @listeners_applied
    end

    # What one reconcile did. `added`/`removed` count entries the section GAINED and LOST;
    # `retargeted` counts the ones that kept their address and changed everything else (a
    # reverse listener pointed at a new origin — the case #499 made interactive and therefore
    # the case this whole issue is about), which would otherwise read as one of each.
    #
    # `dropped` is the wording the issue asked for: an address that WAS serving, is still
    # wanted, and did not come back. It is the only outcome the operator must act on, and it is
    # deliberately separate from `failed` (which also covers a listener that never bound).
    record ListenerReconcile,
      added : Int32,
      removed : Int32,
      retargeted : Int32,
      serving : Int32,
      failed : Array(String),
      dropped : Array(String),
      capturing : Bool do
      def changed? : Bool
        added > 0 || removed > 0 || retargeted > 0
      end

      # What the reconcile did, in one line. Lives on the record rather than in the TUI shell
      # for the same reason `ListenerRow` does: it is a pure function of the outcome, and the
      # branch that matters most (`dropped`) is the one a shell method would be hardest to
      # exercise. The counts come first because they answer "did my edit land"; a bind failure
      # comes last and NAMES the address, because that is the part the operator has to go fix.
      def summary : String
        parts = [] of String
        parts << "#{added} added" if added > 0
        parts << "#{removed} removed" if removed > 0
        parts << "#{retargeted} retargeted" if retargeted > 0
        head = parts.empty? ? "listeners: settings.json already matches the running sockets" : "listeners: #{parts.join(", ")}"
        # Capture off means nothing was bound and nothing could be — "0 serving" would read as a
        # failure of the reconcile rather than as the state the operator put gori in.
        return "#{head} — capture is off, press c to start" unless capturing
        "#{head}#{tail}"
      end

      private def tail : String
        # The wording #508 asked for: it WAS serving, it is STILL wanted, and it did not come
        # back. Distinct from `failed`, which also covers a listener that never bound at all.
        return " — #{dropped.join(", ")} was serving and could not rebind" if dropped.present?
        return " — #{failed.size} could not bind (see the listeners chip)" unless failed.empty?
        changed? ? " · #{serving} serving" : ""
      end
    end

    # Re-read the `listeners` section from settings.json and make this session's additional
    # sockets match it, without a restart (#508). Returns what moved, or nil when the file could
    # not be read — a reconcile driven by a fallback would tear sockets down over a typo in an
    # unrelated section, so it refuses instead.
    #
    # The shape is the primary bind's live rebind (`runner.cr` `apply_settings`), one level up:
    # that one early-returns when the address has not moved, this one leaves alone every listener
    # whose record has not moved. **A listener that is unchanged AND already serving is never
    # touched** — which is what makes an edit to one row incapable of dropping a working socket
    # somewhere else in the array. Stop-all/start-all would have done exactly that.
    #
    # Fates, all of them defined by `Proxy::Server#stop` closing only the ACCEPT socket:
    #
    #   - removed from the section → stops accepting; connections already established finish on
    #     their own fibers. Same fate as capture-off and as a primary rebind.
    #   - same address, changed config → stopped then rebuilt, in that order, because the new
    #     socket wants the address the old one holds. In-flight connections keep running against
    #     the configuration they were accepted under, which is the only answer that does not
    #     retarget a request mid-flight.
    #   - unchanged but NOT serving (its bind failed earlier, or capture was off) → retried. A
    #     reconcile is also how an operator recovers a listener after freeing its port.
    #
    # Nothing is started while capture is off: the sockets are rebuilt so the next `c` opens the
    # right set, which is `Server#rebind`'s "not listening → just record the new bind" rule.
    def reconcile_listeners! : ListenerReconcile?
      desired_raw = Settings.disk_listeners?
      return nil unless desired_raw
      desired = Settings.valid_listeners(desired_raw)
      before = @extra_listeners.map(&.spec)
      up_before = @extra_listeners.select(&.server.listening?).map { |e| authority_of(e.server) }

      # Phase 1 — every stop, BEFORE any start, so a listener that kept its address can rebind.
      pending = desired.dup
      keep = [] of ExtraListener
      @extra_listeners.each do |e|
        idx = pending.index(e.spec)
        if idx && e.server.listening?
          pending.delete_at(idx)
          keep << e
        else
          e.server.stop rescue nil
        end
      end

      # Phase 2 — build and start whatever has no surviving socket.
      failed = [] of String
      @extra_listeners = keep
      pending.each do |l|
        e = Session.build_listener(l, @sink, @tunnel, @rules, @interceptor, @host_overrides, @bindings)
        @extra_listeners << e
        next unless capturing?
        begin
          e.server.start
        rescue ex
          failed << Session.bind_failure(e.server, ex)
          ::Log.warn { "listener #{e.server.host}:#{e.server.port} failed to bind: #{ex.message}" }
        end
      end

      # Config-time rejections first, then this reconcile's bind failures — the same two-part
      # list `start_extra_listeners` maintains, so the readout cannot tell a reconciled session
      # from a freshly opened one.
      @listener_errors.clear
      @listener_errors.concat(Settings.listener_config_errors(desired_raw))
      @listener_errors.concat(failed)
      @listeners_applied = desired_raw

      gone = before.reject { |s| desired.includes?(s) }
      fresh = desired.reject { |s| before.includes?(s) }
      # Matched by CONSUMING an address, not by `count`: two entries can name the same address
      # (only one of them ever binds), and an `any?` test would match both against one survivor
      # and drive `added` negative.
      unclaimed = fresh.map { |f| {f.host, f.port} }
      moved = gone.count do |s|
        (i = unclaimed.index({s.host, s.port})) ? (unclaimed.delete_at(i); true) : false
      end
      up_after = @extra_listeners.select(&.server.listening?).map { |e| authority_of(e.server) }
      ListenerReconcile.new(
        added: fresh.size - moved, removed: gone.size - moved, retargeted: moved,
        serving: up_after.size, failed: failed,
        dropped: up_before.reject { |a| up_after.includes?(a) }
          .select { |a| desired.any? { |l| Gori::BindAddress.authority(l.host, l.port) == a } },
        capturing: capturing?)
    end

    private def authority_of(server : Proxy::Server) : String
      Gori::BindAddress.authority(server.host, server.port)
    end

    # Additional listeners started and stopped alongside the primary. Each failure is
    # non-fatal and recorded: a transparent listener that cannot bind (privileged port, address
    # in use) must not stop capture on the primary, but it must not fail silently either — a
    # redirect rule pointing at a dead socket is invisible from the client's side.
    getter listener_errors : Array(String)

    # One row per ADDITIONAL listener for the readout (the `listeners:N` chip and its overlay).
    # `error` is the bind failure for this specific socket, matched by address — `listener_errors`
    # is a flat list because it also carries config-time rejections, which have no live server.
    #
    # Deliberately a snapshot of plain values, not the `Proxy::Server` objects: the TUI must not
    # be able to reach a live listener's socket through a readout.
    record ListenerRow, host : String, port : Int32, mode : String,
      origin : String, listening : Bool, error : String?

    def listener_rows : Array(ListenerRow)
      rows = @extra_listeners.map do |e|
        s = e.server
        addr = authority_of(s)
        org = s.origin
        ListenerRow.new(s.host, s.port,
          s.origin ? "reverse" : (s.transparent? ? "transparent" : "proxy"),
          org ? "#{org[0]}://#{Gori::BindAddress.authority(org[1], org[2])}" : "",
          s.listening?,
          @listener_errors.find(&.starts_with?("#{addr} —")))
      end
      # Config-time rejections have no server object, so they would otherwise be counted by the
      # chip and then missing from the list it opens.
      @listener_errors.each do |err|
        next if rows.any? { |r| r.error == err }
        rows << ListenerRow.new(err.split(" —").first, 0, "invalid", "", false, err)
      end
      rows
    end

    private def start_extra_listeners : Nil
      # Reset to the CONFIG-time rejections rather than to empty: those are still true after a
      # capture toggle, and clearing them would make an unusable listener disappear from the
      # readout on the first `c` press.
      @listener_errors.clear
      # The config errors of the section these sockets were built from — `@listeners_applied`,
      # not `Settings.listeners`, so a capture toggle after a reconcile does not resurrect the
      # rejections of the startup section.
      @listener_errors.concat(Settings.listener_config_errors(@listeners_applied))
      @extra_listeners.each do |e|
        e.server.start
      rescue ex
        @listener_errors << Session.bind_failure(e.server, ex)
        ::Log.warn { "listener #{e.server.host}:#{e.server.port} failed to bind: #{ex.message}" }
      end
    end

    private def stop_extra_listeners : Nil
      @extra_listeners.each { |e| e.server.stop rescue nil }
    end

    # Flip upstream TLS verification live (settings:network toggle). Updates the runtime
    # config (repeater/fuzzer/miner read config.insecure_upstream? per send), the capture
    # proxy's TLS tunnel (next CONNECT), and the active-probe sender (next probe). Global —
    # the persisted Settings.verify_upstream is the source of truth across restarts.
    def set_verify_upstream(verify : Bool) : Nil
      @config.insecure_upstream = !verify
      @tunnel.verify_upstream = verify
      @probe.verify_upstream = verify
    end

    # Flip the direct-access info page live (settings:network toggle). Pushed to the
    # capture proxy's TLS tunnel, which ClientConn reads per request via the TlsMitm
    # seam — so the next direct hit picks it up with no restart. Global; the persisted
    # Settings.serve_landing is the source of truth across restarts.
    def set_serve_landing(enabled : Bool) : Nil
      @tunnel.serve_landing = enabled
    end

    def capturing? : Bool
      @proxy.listening?
    end

    # True when THIS session owns the project's capture lock (vs view-only, where
    # another instance holds it). Lets the TUI tell "port taken, but we own capture"
    # (advise: free the port) from "another instance owns this project" (advise:
    # press c to take over once it closes).
    def capturing_lock_held? : Bool
      !@capture_lock.nil?
    end

    # Toggle live capture. Returns true if capture is now ON, false if now OFF or
    # REFUSED (another instance holds this project's lock). Stopping KEEPS the lock
    # (we still own this project, just paused, so a quick resume can't race another
    # instance). Starting reuses the held lock, or re-acquires it if we were
    # view-only and the other instance has since released it.
    def toggle_capture : Bool
      result =
        if @proxy.listening?
          @proxy.stop
          stop_extra_listeners
          false
        else
          @capture_lock ||= CaptureLock.try_at(@project.capture_lock_path) # reuse if held, else try to take over
          return false unless @capture_lock                                # still held by another instance
          @probe.start                                                     # we now hold the lock → run the scanner (idempotent if already running)
          @proxy.start(fallback: true)                                     # cover a DIFFERENT project's port on resume
          start_extra_listeners                                            # non-fatal; see #listener_errors
          true
        end
      sync_capture_status!
      result
    end

    # Refresh the per-project capture sidecar so the project picker can show the
    # live bind address. No-op when this session doesn't hold the capture lock.
    def sync_capture_status! : Nil
      return unless capturing_lock_held?
      CaptureStatus.write_at(@project.capture_status_path, @proxy.host, @proxy.port, capturing?)
    rescue
      # The capture-status file is a purely informational sidecar; a write failure
      # (disk full, dir vanished) must not abort session open / capture toggle / settings.
    end

    def close : Nil
      # Drop the binding layer FIRST, before any fiber can send again: the values are
      # per-project and must not survive into the next project, and a `$SESSION` resolved
      # against a closed project's table would be the worst kind of cross-project leak.
      # The values themselves die with the object — nothing wrote them anywhere.
      Env.layer = nil if Env.layer.same?(@bindings)
      @interceptor.release_all # unblock held fibers FIRST so they can write final rows
      @proxy.stop
      stop_extra_listeners
      @store.abandon_pending!("proxy stopped before response")
      # Best-effort: a delete failure here must not skip the lock/probe/store teardown below
      # (which would leak the flock + writer fiber + fibers) or, via a caller's `ensure`,
      # replace the real exception being unwound.
      (CaptureStatus.clear_at(@project.capture_status_path) if capturing_lock_held?) rescue nil
      # Stop Probe FIRST so its active workers wind down and its passive fiber stops issuing
      # get_flow against a live DB; this also closes the probe_events channel it consumes.
      @probe.stop
      # Second sweep: proxy/intercept fibers released above may still enqueue
      # InsertFlow after the first abandon (right after proxy.stop).
      @store.abandon_pending!("proxy stopped before response")
      # Drain + stop the store BEFORE closing the events channel: the writer
      # publishes post-commit events while draining, and a closed channel would
      # otherwise make it raise mid-drain. (publish() also tolerates a closed
      # channel as defense-in-depth — incl. the now-closed probe_events.)
      @store.close
      @flow_events.close
      # The third feed closes with them, or the Authorize passive watcher parks in `receive?`
      # forever — one leaked fiber per project switch, each holding a closed store and a dead
      # controller (a fresh Runner is built per project).
      @authorize_events.close
      # Release the capture flock LAST — only after this session's store + probe have torn
      # down — so a second instance racing to reopen the same project can't become
      # concurrently live (its own analyzer/store touching shared state) while ours winds down.
      @capture_lock.try(&.close)
      @project.cleanup
    end
  end
end
