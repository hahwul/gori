require "./config"
require "./project"
require "./capture_lock"
require "./capture_status"
require "./store"
require "./rules"
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
    # The passive/active scanner. Subscribes to the store's parallel probe_events feed and
    # writes grouped issues; runs for both the TUI and headless capture.
    getter probe : Probe::Analyzer
    getter rules : Rules
    getter scope : Scope
    getter host_overrides : HostOverrides
    getter interceptor : Interceptor
    # Why the live proxy isn't listening (e.g. "port in use"), or nil when capture
    # is up. The project still opens for History/Repeater/Sitemap/etc. — only live
    # capture needs the bind — so a bind failure is non-fatal.
    getter bind_error : String?

    def self.open(config : Config, ca : Proxy::Tls::CertAuthority,
                  registry : Verb::Registry, project : Project,
                  bind_fallback : Bool = false) : Session
      events = Channel(Store::FlowEvent).new(1024)
      probe_events = Channel(Store::FlowEvent).new(256)
      store = Store.open(project.db_path, events, probe_events)
      probe = nil.as(Probe::Analyzer?)
      begin
        # Per-project network overrides: pull this project's pinned bind/upstream (if any) into
        # the Settings runtime layer BEFORE binding, so the proxy listens on the project's address
        # and Upstream.dial (reads Settings.effective_upstream_proxy) tunnels through its upstream.
        # Always assign all three (nil when unset) so switching projects resets cleanly. Mutating
        # `config` is safe — App re-seeds it from the global Settings on every project open. Inside
        # the begin so a failing settings read is torn down below rather than leaking store+channels.
        Settings.project_bind_host = store.setting(Settings::PROJECT_BIND_HOST_KEY)
        Settings.project_bind_port = store.setting(Settings::PROJECT_BIND_PORT_KEY).try(&.to_i?)
        Settings.project_upstream_proxy = store.setting(Settings::PROJECT_UPSTREAM_KEY)
        Env.load_project(store)
        config.listen = Settings.effective_bind_host
        config.port = Settings.effective_bind_port
        lock = nil.as(CaptureLock?)
        sink = Proxy::StoreSink.new(store)
        rules = Rules.load(store)                  # shared: proxy reads, TUI edits (Mutex-guarded)
        scope = Scope.load(store)                  # shared by the TUI lens AND intercept gating
        host_overrides = HostOverrides.load(store) # per-project /etc/hosts; proxy reads, TUI edits (Mutex-guarded)
        interceptor = Interceptor.new(scope)       # shared: proxy fibers hold, TUI decides
        # Passive/active scanner: reads the parallel probe_events feed, gates active probes on
        # the shared Scope. Runs headless too — but ONLY on the capture-lock holder (started
        # below), never on a view-only 2nd instance (which would send duplicate active probes to
        # targets and race issue-writes on the shared DB against the real capturer).
        probe = Probe::Analyzer.new(store, scope, probe_events, store.probe_mode, !config.insecure_upstream?)
        tunnel = Proxy::Tls::Tunnel.new(ca, verify_upstream: !config.insecure_upstream?,
          rewriter: rules, interceptor: interceptor, host_overrides: host_overrides,
          serve_landing: Settings.serve_landing?)
        proxy = Proxy::Server.new(config.listen, config.port, sink, tls: tunnel,
          rewriter: rules, interceptor: interceptor, host_overrides: host_overrides)
        # Per-PROJECT capture lock decides whether THIS instance captures. A 2nd
        # instance of the SAME project can't acquire it → VIEW-ONLY (no 2nd port; it
        # live-refreshes off the shared DB). A DIFFERENT project has its own lock, so
        # it captures on its own port (the bind falls back when the configured port
        # is taken). The bind itself stays NON-FATAL: History/Repeater/Sitemap/Issues
        # all read the store / dial upstream directly and don't need the listener.
        bind_error =
          begin
            lock = CaptureLock.try(project.dir)
            if lock
              begin
                proxy.start(fallback: bind_fallback)
                nil
              rescue ex
                # We own this project (hold the lock) but couldn't bind the listener
                # (port taken, fallback off/exhausted). Stay capture-off and KEEP the
                # lock — the user can free the port (settings) + press c to start
                # (toggle_capture reuses the held lock).
                ex.message || "could not bind #{config.listen}:#{config.port}"
              end
            else
              "another gori instance already holds this directory's capture lock"
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
        session = new(config, ca, registry, project, store, proxy, tunnel, events, probe, rules, scope, host_overrides, interceptor, bind_error, lock)
        session.sync_capture_status!
        session
      rescue ex
        # A store/rules/scope failure (NOT the bind, which is handled above) would
        # otherwise leak the store's writer fiber + db fd, the events channels, the Probe
        # fibers, and the lock fd. Tear them down, then re-raise for the caller.
        lock.try(&.close) rescue nil
        probe.try(&.stop) rescue nil
        store.close rescue nil
        events.close rescue nil
        probe_events.close rescue nil
        raise ex
      end
    end

    # A random per-session token stamped on every #123 intercept snapshot/command row, so a
    # stale command from a prior session (whose interceptor item ids reset to 0) can never be
    # applied against a different new held item — the drain acks a token mismatch as stale.
    getter intercept_token : String

    def initialize(@config, @ca, @registry, @project, @store, @proxy, @tunnel, @flow_events, @probe,
                   @rules, @scope, @host_overrides, @interceptor, @bind_error : String? = nil,
                   @capture_lock : CaptureLock? = nil)
      @intercept_token = Random::Secure.hex(8)
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
          false
        else
          @capture_lock ||= CaptureLock.try(@project.dir) # reuse if held, else try to take over
          return false unless @capture_lock               # still held by another instance
          @probe.start                                    # we now hold the lock → run the scanner (idempotent if already running)
          @proxy.start(fallback: true)                    # cover a DIFFERENT project's port on resume
          true
        end
      sync_capture_status!
      result
    end

    # Refresh the per-project capture sidecar so the project picker can show the
    # live bind address. No-op when this session doesn't hold the capture lock.
    def sync_capture_status! : Nil
      return unless capturing_lock_held?
      CaptureStatus.write(@project.dir, @proxy.host, @proxy.port, capturing?)
    rescue
      # The capture-status file is a purely informational sidecar; a write failure
      # (disk full, dir vanished) must not abort session open / capture toggle / settings.
    end

    def close : Nil
      @interceptor.release_all # unblock held fibers FIRST so they can write final rows
      @proxy.stop
      @store.abandon_pending!("proxy stopped before response")
      # Best-effort: a delete failure here must not skip the lock/probe/store teardown below
      # (which would leak the flock + writer fiber + fibers) or, via a caller's `ensure`,
      # replace the real exception being unwound.
      (CaptureStatus.clear(@project.dir) if capturing_lock_held?) rescue nil
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
      # Release the capture flock LAST — only after this session's store + probe have torn
      # down — so a second instance racing to reopen the same project can't become
      # concurrently live (its own analyzer/store touching shared state) while ours winds down.
      @capture_lock.try(&.close)
      @project.cleanup
    end
  end
end
