require "./config"
require "./project"
require "./capture_lock"
require "./store"
require "./rules"
require "./scope"
require "./interceptor"
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
    getter flow_events : Channel(Store::FlowEvent)
    getter rules : Rules
    getter scope : Scope
    getter interceptor : Interceptor
    # Why the live proxy isn't listening (e.g. "port in use"), or nil when capture
    # is up. The project still opens for History/Replay/Sitemap/etc. — only live
    # capture needs the bind — so a bind failure is non-fatal.
    getter bind_error : String?

    def self.open(config : Config, ca : Proxy::Tls::CertAuthority,
                  registry : Verb::Registry, project : Project,
                  bind_fallback : Bool = false) : Session
      events = Channel(Store::FlowEvent).new(1024)
      store = Store.open(project.db_path, events)
      begin
        lock = nil.as(CaptureLock?)
        sink = Proxy::StoreSink.new(store)
        rules = Rules.load(store)            # shared: proxy reads, TUI edits (Mutex-guarded)
        scope = Scope.load(store)            # shared by the TUI lens AND intercept gating
        interceptor = Interceptor.new(scope) # shared: proxy fibers hold, TUI decides
        tunnel = Proxy::Tls::Tunnel.new(ca, verify_upstream: !config.insecure_upstream?,
          rewriter: rules, interceptor: interceptor)
        proxy = Proxy::Server.new(config.listen, config.port, sink, tls: tunnel,
          rewriter: rules, interceptor: interceptor)
        # Per-PROJECT capture lock decides whether THIS instance captures. A 2nd
        # instance of the SAME project can't acquire it → VIEW-ONLY (no 2nd port; it
        # live-refreshes off the shared DB). A DIFFERENT project has its own lock, so
        # it captures on its own port (the bind falls back when the configured port
        # is taken). The bind itself stays NON-FATAL: History/Replay/Sitemap/Findings
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
              "another gori instance is already capturing this project"
            end
          rescue ex
            # CaptureLock.try itself failed (can't create/open the lock file) — not a
            # bind issue; release anything we opened and report it.
            lock.try(&.close) rescue nil
            lock = nil
            ex.message || "could not open the project capture lock"
          end
        new(config, ca, registry, project, store, proxy, events, rules, scope, interceptor, bind_error, lock)
      rescue ex
        # A store/rules/scope failure (NOT the bind, which is handled above) would
        # otherwise leak the store's writer fiber + db fd, the events channel, and the
        # lock fd. Tear them down, then re-raise for the caller.
        lock.try(&.close) rescue nil
        store.close rescue nil
        events.close rescue nil
        raise ex
      end
    end

    def initialize(@config, @ca, @registry, @project, @store, @proxy, @flow_events,
                   @rules, @scope, @interceptor, @bind_error : String? = nil,
                   @capture_lock : CaptureLock? = nil)
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
      if @proxy.listening?
        @proxy.stop
        false
      else
        @capture_lock ||= CaptureLock.try(@project.dir) # reuse if held, else try to take over
        return false unless @capture_lock               # still held by another instance
        @proxy.start(fallback: true)                    # cover a DIFFERENT project's port on resume
        true
      end
    end

    def close : Nil
      @interceptor.release_all # unblock held fibers FIRST so they can write final rows
      @proxy.stop
      @capture_lock.try(&.close) # release the flock so a later open of this project can capture
      # Drain + stop the store BEFORE closing the events channel: the writer
      # publishes post-commit events while draining, and a closed channel would
      # otherwise make it raise mid-drain. (publish() also tolerates a closed
      # channel as defense-in-depth.)
      @store.close
      @flow_events.close
      @project.cleanup
    end
  end
end
