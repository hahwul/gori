require "../env_migration"
require "../session_slot"

module Gori
  class Store
    # A STALE-GRAMMAR process writing into this database, made harmless.
    #
    # The open-time reconcile (`EnvMigration.reconcile`) makes a project single-grammar and stamps
    # the marker. What it cannot do is stop a LONG-LIVED process that missed the switch from writing
    # rows in the grammar it was born under: a `gori mcp` server started under bare, an operator's
    # second TUI. Those rows are worse than wrong — the marker already says `namespaced`, so the
    # next reconcile finds `from == to` and skips them FOREVER. A bare `$SESSION` in a draft or in a
    # rule replacement then reads as literal text for the life of the project, with nothing anywhere
    # saying so.
    #
    # `EnvMigration.follow_disk` closes the common case at the READ end (both peer ticks adopt the
    # file's grammar and re-spell what they find). This is the belt: at the moment text is WRITTEN,
    # compare the writing process's grammar with the marker and re-spell into the MARKER's grammar
    # when they differ. Cheaper than refusing — nothing to report, nothing for a caller to handle —
    # and it keeps the invariant the reconcile depends on: ONE grammar per database.
    #
    # Deliberately not a refusal and not a notice. The operator asked for the write; the grammar is
    # bookkeeping they did not ask about, and the honest answer is to store what they meant.

    # ── the name tables the routing asks about ────────────────────────────────
    #
    # Read off the STORE rather than off `Settings.project_env_vars` / `Env.declared_bindings`: both
    # the open-time reconcile and this guard run for a database whose layers may not be the process
    # globals at all (the reconcile runs BEFORE `Env.load_project`, and one process opens several
    # projects). Defined here so `Store` owns the queries and `EnvMigration` owns the policy.

    # The ENV table's KEYS as the bare grammar resolved them: the global vars with this project's
    # own merged over them — exactly `Env.effective_vars`' membership.
    def env_var_names : Set(String)
      names = Settings.env_vars.map(&.[0]).to_set
      Env.parse_vars_json(setting(Env::PROJECT_VARS_KEY)).each { |(k, _)| names << k }
      names
    end

    # The BIND table, wider than what is bound: every extract rule's name (enabled or not) plus
    # every name a session slot claims. A binding value is memory-only, so "what is bound right now"
    # is empty at open time and would re-spell nothing; what the operator WROTE is the declared name,
    # and a disabled rule's name is still the name they wrote.
    def bind_declared_names : Set(String)
      names = extract_rules.map(&.name).to_set
      SessionSlot.parse_json(setting(SESSION_SLOTS_KEY)).each { |slot| slot.rules.each { |r| names << r } }
      names
    end

    # The half of `bind_declared_names` that ever RESOLVED: the names an ENABLED extract rule
    # declares. Both halves of the live binding table filter on `enabled?` (`Bindings#values`,
    # `Bindings#declared`), so a switched-off rule's name was an ordinary unknown key under bare.
    def bind_enabled_names : Set(String)
      extract_rules.select(&.enabled?).map(&.name).to_set
    end

    # The grammar THIS database's tokens are spelled in. `EnvMigration.stored_syntax`'s reading, on
    # the store's own handle — absent (or unreadable) means bare, which is exactly true of every
    # database written before namespaces existed.
    def env_token_syntax : Env::Syntax
      raw = setting(Env::PROJECT_SYNTAX_KEY)
      return Env::Syntax::Bare unless raw
      Env::Syntax.parse?(raw.strip) || Env::Syntax::Bare
    rescue
      Env::Syntax::Bare
    end

    # The marker as a STATEMENT: nil when the database carries none.
    #
    # The distinction is what scopes this guard. An absent marker means bare, and it means it
    # correctly — but it also means NOTHING HAS RECONCILED THIS DATABASE YET, and re-spelling a
    # write into a grammar no reconcile was willing to stamp is the same overreach
    # `Settings.env_syntax_stated?` refuses on the read side. A project gori declined to migrate
    # (unreadable settings, a typo where the grammar should be) must not have its writes quietly
    # rewritten either; and a brand-new database is stamped at birth, so the case this guard is
    # actually for — a peer already moved this project — always carries an explicit marker.
    def env_token_syntax? : Env::Syntax?
      setting(Env::PROJECT_SYNTAX_KEY).try { |raw| Env::Syntax.parse?(raw.strip) }
    rescue
      nil
    end

    # Everything one stale-grammar write needs, read ONCE — the two grammars and the three name
    # tables the routing asks about. A record rather than four calls, because a row with a request,
    # a target and an SNI in it must not re-read the project's extract rules three times.
    record EnvWrite, from : Env::Syntax, to : Env::Syntax,
      env : Set(String), bind : Set(String), live : Set(String), prefix : String do
      def call(bytes : Bytes, kind : EnvMigration::Kind) : Bytes
        return bytes if bytes.empty?
        after, _ = EnvMigration.rewrite(bytes, from: from, to: to,
          env_names: env, bind_names: bind, enabled_bind_names: live, kind: kind, prefix: prefix)
        after
      rescue
        # A write must never fail over bookkeeping: the caller's own bytes are the behaviour that
        # shipped before this guard existed.
        bytes
      end

      def call(text : String, kind : EnvMigration::Kind) : String
        return text if text.empty?
        String.new(call(text.to_slice, kind))
      end

      def call(text : String?, kind : EnvMigration::Kind) : String?
        text.try { |t| call(t, kind) }
      end
    end

    # The re-speller for a write into THIS database, or nil when this process and this database
    # already agree about the grammar — which is every write but the ones made across a switch, so
    # the common path costs one settings-row read and allocates nothing.
    def env_write : EnvWrite?
      to = env_token_syntax?
      return nil unless to
      from = Settings.env_syntax
      prefix = Settings.env_prefix
      return nil if from == to || prefix.empty?
      EnvWrite.new(from, to, env_var_names, bind_declared_names, bind_enabled_names, prefix)
    rescue
      nil
    end
  end
end
