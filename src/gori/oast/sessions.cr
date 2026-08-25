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

    # What a release actually DID. Four states because "released" and "not released" were
    # never the only two, and collapsing them is how three surfaces came to report a teardown
    # that had not happened: `Provider#deregister`'s default is a no-op, so for webhook.site,
    # postbin, BOAST and custom-http `release` returned true without a packet leaving the
    # process while the docs promised "payloads minted from it stop resolving".
    enum Release
      Released      # the server was told, and acknowledged
      NoServerState # there was never a third-party registration to release (custom-http)
      Unsupported   # this backend registered state and offers no way to release it (BOAST)
      Failed        # a teardown exists and it errored — the registration is still live

      # Is the listener actually gone? The one question a surface asks before printing
      # "released" or refusing to. `NoServerState` counts: nothing was ever registered, so
      # nothing is still listening on anyone else's server.
      def torn_down? : Bool
        case self
        in Released, NoServerState then true
        in Unsupported, Failed     then false
        end
      end
    end

    # Release the server-side registration. The local row and every callback it collected
    # stay — this releases the LISTENER, not the evidence.
    def release_outcome(bound : Bound, http : Http) : Release
      release_detail(bound.provider, bound.session, http)[0]
    end

    # The outcome PLUS the failing teardown's own text, for a caller that has the pieces but
    # not a `Bound` — the TUI performs its release on a detached fiber and reports it from a
    # later drain. It takes the pair rather than re-deciding, because deciding it a second
    # time is precisely how the tab came to print "released" for a backend that has no
    # teardown: four branches hand-rolled beside the three lines that already own them.
    #
    # The text is the one thing `release_message` cannot know — `Failed` reads "(provider
    # error)" on its own, which is indistinguishable between a 503 and a DNS failure.
    def release_detail(provider : Provider, session : Session, http : Http) : {Release, String?}
      return {Release::NoServerState, nil} unless provider.server_state?
      return {Release::Unsupported, nil} unless provider.deregisters?
      provider.deregister(http, session)
      {Release::Released, nil}
    rescue ex
      {Release::Failed, ex.message}
    end

    # The sentence a surface prints for a release outcome. One phrasing, three surfaces — the
    # same contract `message_for` keeps for `Problem`, and the reason it names the provider:
    # "BOAST cannot be released" is actionable (rotate the secret, or accept a live listener)
    # where a bare "could not deregister" reads as a transient network fault.
    def release_message(outcome : Release, bound : Bound, id : Int64, callbacks : Int32) : String
      release_message(outcome, bound.session.kind.label, id, callbacks)
    end

    # The same sentence for a caller that no longer holds the `Bound` — the TUI reports a
    # release from a drain loop, after the fiber that performed it is gone. The label is the
    # only thing the phrasing takes from the binding, so passing it keeps the three surfaces
    # on one wording instead of growing a fourth.
    def release_message(outcome : Release, kind_label : String, id : Int64, callbacks : Int32) : String
      kept = callbacks == 1 ? "its 1 callback stays" : "its #{callbacks} callbacks stay"
      case outcome
      in Release::Released
        "released OAST session ##{id} — #{kept}."
      in Release::NoServerState
        "OAST session ##{id} needed no release — #{kind_label} keeps no " \
        "server-side registration (it polls an endpoint you run); #{kept}."
      in Release::Unsupported
        "OAST session ##{id} was NOT released — #{kind_label} has no " \
        "deregistration API, so payloads minted from it keep resolving; #{kept}."
      in Release::Failed
        "could not deregister OAST session ##{id} (provider error) — payloads minted from it " \
        "may still resolve; #{kept}."
      end
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
    #
    # The row id alone is NOT an identity. `oast_providers.id` is a plain `INTEGER PRIMARY KEY`
    # with no AUTOINCREMENT, so SQLite hands a deleted row's id to the next insert — delete the
    # second interactsh provider and add a webhook.site one, and the sessions that pointed at
    # the first now resolve to the second. `bind` takes the HOST from the session and the TOKEN
    # from the config, so that mismatch does not merely mislabel a row: it puts a webhook.site
    # api key in an `Authorization:` header aimed at an interactsh host the operator never
    # meant to hand it to. Accept the id ONLY when the kind agrees, and fall through to the
    # kind+endpoint re-resolution below when it does not.
    #
    # Falling through when the id is simply GONE matters for its own reason: deleting a provider
    # and re-adding the same one used to strand every session it minted with a provider_key of
    # nil, which the TUI reads as "not resumable" forever. `Store#delete_oast_provider` now
    # NULLs the column, and this is the path those rows land on.
    def config_for(rec : Store::OastSessionRecord,
                   configs : Array(ProviderConfig)) : ProviderConfig?
      if pid = rec.provider_id
        hit = configs.find { |p| p.project_id == pid }
        return hit if hit && same_kind?(hit.kind, rec.kind)
      end
      configs.find { |p| same_kind?(p.kind, rec.kind) && same_endpoint?(p.host, rec.server_url) }
    end

    # Do a provider row and a session row name the same backend? Through `ProviderKind.parse?`
    # rather than by string ==, because the two columns are written by different producers:
    # a config's `kind` is the LABEL ("webhook.site", "custom-http") while a session's is
    # whatever the register persisted, and `parse?` already accepts both spellings. A kind
    # neither side can parse falls back to the literal compare so an unknown backend still
    # matches itself.
    def same_kind?(config_kind : String, session_kind : String) : Bool
      a = ProviderKind.parse?(config_kind)
      b = ProviderKind.parse?(session_kind)
      a && b ? a == b : config_kind == session_kind
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
