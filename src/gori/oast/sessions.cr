require "../store"
require "./provider_config"
require "./provider"
require "./session"

module Gori::Oast
  # PERSISTED listening sessions: list them, re-arm one, release one.
  #
  # A registration outlives the process that minted it — that is the whole point of the
  # `oast_sessions` table (the stored payload that only fires on a nightly job, the
  # back-office browser that opens the mail tomorrow). The TUI had the only implementation
  # of "get that session back", inside `Tui::OastController`, so `gori run oast` and the MCP
  # `oast_*` tools could register and die but never resume. This module is the surface-free
  # half of that controller: the store round trip, the provider re-resolution, and the
  # record → `Session` rebuild, so all three surfaces list, resume and release the SAME rows
  # (DESIGN.md §2 — three surfaces, one engine).
  #
  # NOT required from `oast.cr`'s umbrella, for the same reason `provider_config.cr` is not:
  # that engine is deliberately Store-free, and this file pulls Store in. Its consumers
  # require it directly.
  #
  # Nothing here auto-resumes. Resuming is an operator decision on every surface (P4): a
  # process that opened a project must not start polling a third-party interaction server
  # because a row exists.
  module Sessions
    extend self

    # One persisted session as the three surfaces list it. Deliberately carries NO secret:
    # not `secret`, not `private_key_pem`, not `token`. A session list is printed, logged and
    # handed to an agent; the credentials that decrypt its callbacks stay in the row.
    record Info,
      id : Int64,
      kind : String,          # ProviderKind label as stored
      provider : String,      # display name of the provider it resolves to (or the kind)
      provider_key : String?, # scope-qualified key of that provider, nil when it is gone
      payload_host : String,
      server_url : String,
      created_at : Time,
      last_poll_at : Time?,
      hits : Int32

    # Why a session could not be bound. Both are operator-fixable and each surface phrases
    # them itself (`message_for` is the shared sentence).
    enum Problem
      Missing     # no row with that id in this project
      UnknownKind # the row names a provider kind this build does not have
    end

    # A bound session: everything a resume or a release needs, and nothing a surface has to
    # rebuild. `config` is the saved provider it resolved to, nil when that provider is gone.
    record Bound,
      session : Session,
      provider : Provider,
      label : String,
      config : ProviderConfig?

    # Every persisted session, NEWEST FIRST — a session list is read as a stack, and the one
    # you were just using is the one you want back (same order as the TUI's resume picker).
    def list(store : Store, configs : Array(ProviderConfig)? = nil) : Array(Info)
      cfgs = configs || Oast.provider_configs(store)
      store.oast_sessions.reverse.map do |rec|
        cfg = config_for(rec, cfgs)
        Info.new(
          id: rec.id,
          kind: rec.kind,
          provider: cfg.try(&.name) || rec.kind,
          provider_key: cfg.try(&.key),
          payload_host: session_from_record(rec).host,
          server_url: rec.server_url,
          created_at: Time.unix(rec.created_at // 1_000_000),
          last_poll_at: rec.last_poll_at.try { |us| Time.unix(us // 1_000_000) },
          hits: store.oast_callback_count(rec.id))
      end
    end

    # Rebuild the live objects for one persisted session, or say why it cannot be done.
    #
    # The HOST comes from the session, never from the provider config: the session's secrets
    # only mean anything to the server that minted them, and a provider whose host was edited
    # since would send this correlation id somewhere that has never heard of it. The TOKEN
    # does prefer the config — it is a credential, and a rotated one is the live one.
    #
    # Unlike the TUI, a missing provider config is NOT fatal here. The controller refuses it
    # because a TUI listener is addressed BY its provider key (^X, `g`, the payload picker
    # all resolve through `listener_for`), so a resumed session with no key would be a poller
    # the operator could see and never stop. A headless run has no such registry: the row
    # itself carries the endpoint and its own token, which is all a poll needs.
    def bind(store : Store, id : Int64,
             configs : Array(ProviderConfig)? = nil) : Bound | Problem
      rec = store.get_oast_session(id)
      return Problem::Missing unless rec
      kind = ProviderKind.parse?(rec.kind)
      return Problem::UnknownKind unless kind
      cfg = config_for(rec, configs || Oast.provider_configs(store))
      Bound.new(
        session: session_from_record(rec),
        provider: Provider.build(kind, rec.server_url, cfg.try(&.token) || rec.token),
        label: cfg.try(&.name) || kind.label,
        config: cfg)
    end

    # The sentence a surface reports for a `Problem`. One phrasing, three surfaces.
    def message_for(problem : Problem, id : Int64) : String
      case problem
      in .missing?      then "no OAST session ##{id} in this project"
      in .unknown_kind? then "OAST session ##{id} names a provider type this build does not have"
      end
    end

    # Re-arm the server-side state so the session's ALREADY-PLANTED payloads keep resolving.
    # MAY RAISE, deliberately (see `Provider#resume`): the operator asked for the session
    # back, and a resume that quietly failed would leave a poller watching a correlation id
    # the server has never heard of.
    def resume(bound : Bound, http : Http) : Nil
      bound.provider.resume(http, bound.session)
    end

    # Release the server-side registration. The local row and every callback it collected
    # stay — this releases the LISTENER, not the evidence. Returns false when deregister
    # raised (network / provider error) so a surface can refuse to print "released".
    def release(bound : Bound, http : Http) : Bool
      bound.provider.deregister(http, bound.session)
      true
    rescue
      false
    end

    # Persist one polled interaction against its session, with the interaction's OWN time
    # (not now) so a callback reads the same live and after a reload. The store's
    # UNIQUE(session_id, provider_uid) + INSERT OR IGNORE makes a re-poll idempotent.
    def record_callback(store : Store, session_id : Int64, i : Interaction) : Nil
      store.insert_oast_callback(session_id, i.unique_id, i.protocol, i.method, i.source_ip,
        i.full_id, i.raw_request.to_slice, i.raw_response.try(&.to_slice),
        i.at.to_unix_ms * 1000)
    end

    # The provider uids this session already has on file — the seed for a resumed listener's
    # dedup set. Without it a provider that returns its whole buffer on every poll
    # (webhook.site, postbin) would re-announce every old hit the moment you resumed.
    def seen_uids(store : Store, session_id : Int64) : Set(String)
      store.oast_callback_uids(session_id)
    end

    # Rebuild the engine Session from its row. The inverse of what a register persists, and
    # the reason `oast_sessions` carries the private key at all. `registered: true` because
    # the row exists precisely because a register once succeeded.
    def session_from_record(rec : Store::OastSessionRecord) : Session
      kind = ProviderKind.parse?(rec.kind) || ProviderKind::Interactsh
      Session.new(rec.id, kind, rec.server_url, rec.correlation_id, rec.secret,
        private_key_pem: rec.private_key_pem, token: rec.token, registered: true)
    end

    # The saved provider a session belongs to, by row id where it has one.
    #
    # A GLOBAL provider has no row in this project's DB, so the register recorded a NULL
    # provider_id for it — by design, and the reason this cannot simply give up on nil: a
    # global provider is the ordinary case for anyone who configured interactsh once and
    # reuses it across projects. Re-resolve those by the only identity the row still carries,
    # the kind and the server it registered against.
    def config_for(rec : Store::OastSessionRecord,
                   configs : Array(ProviderConfig)) : ProviderConfig?
      if pid = rec.provider_id
        return configs.find { |p| p.project_id == pid }
      end
      configs.find { |p| p.kind == rec.kind && same_endpoint?(p.host, rec.server_url) }
    end

    # Compare a configured host against a session's server_url the way `Provider#base_url`
    # normalises them — the session stored the NORMALISED form ("https://oast.pro") while the
    # provider row holds whatever was typed ("oast.pro"), so a raw == would never match.
    def same_endpoint?(host : String, server_url : String) : Bool
      Provider.normalize_endpoint(host) == Provider.normalize_endpoint(server_url)
    end

    # A session id as an operator types it: `7`, or the `#7` the TUI and the tables print.
    # nil when it is not a positive row id at all.
    def parse_id(token : String) : Int64?
      t = token.strip
      t = t[1..] if t.starts_with?('#')
      id = t.to_i64?
      id && id > 0 ? id : nil
    end
  end
end
