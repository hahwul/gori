require "./config"
require "./project"
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
        sink = Proxy::StoreSink.new(store)
        rules = Rules.load(store)            # shared: proxy reads, TUI edits (Mutex-guarded)
        scope = Scope.load(store)            # shared by the TUI lens AND intercept gating
        interceptor = Interceptor.new(scope) # shared: proxy fibers hold, TUI decides
        tunnel = Proxy::Tls::Tunnel.new(ca, verify_upstream: !config.insecure_upstream?,
          rewriter: rules, interceptor: interceptor)
        proxy = Proxy::Server.new(config.listen, config.port, sink, tls: tunnel,
          rewriter: rules, interceptor: interceptor)
        # The bind is NON-FATAL: if the port is taken (e.g. another gori instance),
        # open in capture-off mode rather than failing the whole project — History/
        # Replay/Sitemap/Findings all read the store / dial upstream directly and
        # don't need the listener. The user can change the port (settings) + toggle
        # capture to start it later.
        bind_error =
          begin
            proxy.start(fallback: bind_fallback)
            nil
          rescue ex
            ex.message || "could not bind #{config.listen}:#{config.port}"
          end
        new(config, ca, registry, project, store, proxy, events, rules, scope, interceptor, bind_error)
      rescue ex
        # A store/rules/scope failure (NOT the bind, which is handled above) would
        # otherwise leak the store's writer fiber + db fd and the events channel.
        # Tear them down, then re-raise for the caller.
        store.close rescue nil
        events.close rescue nil
        raise ex
      end
    end

    def initialize(@config, @ca, @registry, @project, @store, @proxy, @flow_events,
                   @rules, @scope, @interceptor, @bind_error : String? = nil)
    end

    def capturing? : Bool
      @proxy.listening?
    end

    def toggle_capture : Nil
      @proxy.listening? ? @proxy.stop : @proxy.start
    end

    def close : Nil
      @interceptor.release_all # unblock held fibers FIRST so they can write final rows
      @proxy.stop
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
