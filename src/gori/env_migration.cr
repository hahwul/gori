require "./env"

module Gori
  # Re-spelling of STORED env tokens when this install's `Settings.env_syntax` and a project's own
  # marker disagree — the PURE rewrite, with the orchestration around it in `env_migration/store.cr`
  # (a project database, at the moment a surface opens it) and `env_migration/globals.cr`
  # (settings.json's global rewrite rules, at the moment the install's grammar moves).
  #
  # It exists because a grammar switch only changes how stored bytes are READ: without this, an
  # operator whose project is full of `$API_KEY` drafts would be holding text that is now literal.
  # Nothing asks them — see `EnvMigration.reconcile`.
  #
  # ## The contract
  #
  # The rewrite is driven by the reader of the syntax being LEFT (`from`), so "what that grammar
  # would have substituted" is exactly what gets re-spelled. `Env.read_token_at` is that reader —
  # not a regex — which is what makes the offsets agree with what the old grammar actually did,
  # escapes and adjacency included.
  #
  # The invariant is WIRE EQUIVALENCE: the bytes a send seam puts on the socket must be the same
  # before and after. That is stronger than "re-spell the tokens", and it is what forces the
  # escape work below:
  #
  #   * bare → namespaced, in REQUEST text: bare's send seam CONSUMED `$$` (`$$id` shipped `$id`),
  #     while under the namespaced grammar `$$` is two literal bytes. So `$$` becomes a single
  #     `$` — unless what follows is a `NS.NAME`, where `$$ENV.X` is already the namespaced
  #     escape for the same bytes and is left exactly as it stands.
  #   * namespaced → bare: a literal `$NAME` whose NAME the bare grammar WOULD resolve has to
  #     become `$$NAME`, and a literal sigil that bare would pair into an escape has to be
  #     doubled, or the wire changes under the operator.
  #
  # Not every input is representable in the target grammar. `$$$id` under bare ships a literal
  # `$` immediately followed by `id`'s VALUE, and the namespaced grammar has no spelling for that
  # (`$$ENV.id` is the escape, so the `$` and the token cannot sit side by side). `safe?` is the
  # check for it — the caller runs it and SKIPS the row rather than shipping different bytes.
  #
  # ONE difference is structural and is not a defect: a BINDING with no value ships literally, and
  # its literal is its spelling, so a `$FOO` that went out as four bytes goes out as `$BIND.FOO`
  # after the rewrite. `safe?` judges the RESOLVED wire (every name gets a sentinel value), which
  # is the case a re-spelling exists for; the CLI says the other case out loud instead.
  module EnvMigration
    # WHICH grammar the text belongs to, which is a different question from which SYNTAX spells
    # its tokens. `$$` and `$1` mean different things in a request, in a rewrite rule's
    # replacement and in a line of display text, and a migration that gets that wrong silently
    # edits an operator's payload.
    # A kind answers THREE questions, and they are not the same question:
    #
    #   1. does `$$` belong to this grammar (`consumes_escape?`),
    #   2. which TABLES does this consumer resolve a bare name out of, and IN WHICH ORDER
    #      (`route`) — because bare resolved a name by shape and each consumer ran a different
    #      set of passes over it,
    #   3. and can a literal sigil the target grammar WOULD resolve be escaped at all
    #      (`escapes_literal?`).
    enum Kind
      # Request / payload bytes. The send seam owns `$$` and consumes it, so the migration owns it
      # too; under bare it runs the ENV pass and then the BINDING pass, so both tables resolve and
      # ENV — the pass that ran FIRST — wins a name held in both.
      Request
      # A rewriter rule's `replacement`. `Rules#substitute` owns `$$` (→ one `$`, nothing behind
      # it read) and `$1..$9` (a regex backref) in BOTH syntaxes, so both are copied through and
      # only a `$NAME` token is re-spelled. Under bare it resolves against ONE merged table
      # (`Env.display_vars`) in which the BINDING values are layered over the env vars, so a name
      # held in both resolved to the BINDING — the opposite of a request.
      Rule
      # Text a masking pass wrote a token into — an issue title, a note body, a Repeater name.
      # Nothing ever expands it, so there is no escape to pair (`$$` is two bytes of text) and
      # nothing to escape INTO: a literal `$NAME` here means the same four bytes in both grammars.
      Display
      # A session-slot header VALUE. `$$` is the send seam's, exactly as in a request
      # (`Env.expand_bindings_as`, `Escape::Consume`) — but that seam is the ONLY pass over these
      # bytes, and it resolves BIND alone. So an env-only name in a slot header shipped literally
      # under bare and must stay a bare literal, which is the same wire.
      Slot
      # A DIAL TUPLE: a Repeater/workbench `target`, an `sni`. Expanded ONCE, by the env pass with
      # `Escape::Preserve` — so `$$` is two bytes that nothing consumes, and the ENV table is the
      # only one that resolves (a `$BIND.X` in a target is reported unresolved, never bound).
      # Split from `Display` because these bytes ARE expanded: the token spelling has to follow
      # the grammar even though the escape cannot.
      Dial

      # Whether `$$` is this grammar's ESCAPE (and therefore the migration's business) or just
      # bytes that belong to the surrounding grammar.
      def consumes_escape? : Bool
        request? || slot?
      end

      # Whether this kind can spell "a literal sigil the TARGET grammar would resolve".
      #
      # Only a grammar that CONSUMES an escape can: doubling the sigil in one that does not just
      # adds a byte. Display text is never expanded, so there is nothing to protect from; a dial
      # tuple IS expanded but nothing unescapes it, so `$$id` would reach the resolver as `$$id`
      # — the name is reported as "will resolve under bare" instead (`bare_resolution_hint?`).
      def escapes_literal? : Bool
        consumes_escape? || rule?
      end

      # Whether a literal the target grammar would resolve should be NAMED to the operator,
      # because this kind cannot escape it and the resolution is a real change to the wire.
      def bare_resolution_hint? : Bool
        dial?
      end

      # Whether these bytes reach a socket at all, and so whether `safe?` can judge the
      # re-spelling. DISPLAY text is the one kind that does not: nothing ever expands an issue
      # title, so there is no wire to compare.
      #
      # A RULE REPLACEMENT does have one, and leaving it out was the gap: it is resolved by
      # `Rules#substitute` rather than by `Env`'s passes, so `safe?` had nothing to run — and the
      # one kind whose routing question is hardest (bare resolved it against ONE merged table, in
      # the opposite precedence to a request) was also the one kind nothing checked. `wire` models
      # that grammar directly (`rule_wire`) instead of borrowing a pass list that is not its own.
      def has_wire? : Bool
        !display?
      end
    end

    # One re-spelled token, for the report. `at` is the byte offset of the sigil in the ORIGINAL
    # text, so the rows come out in the order an operator reads them.
    #
    # `ambiguous` marks the one case the bare grammar could not distinguish and this one can: a
    # NAME that is both an env var and a binding. Bare ran the env pass first, so the migration
    # routes it to `ENV` — the same value the wire carried — and says so, because the operator
    # may well have meant the binding and only ever saw one of the two.
    record Change,
      at : Int32,
      before : String,
      after : String,
      ref : Env::Ref?,
      ambiguous : Bool = false,
      note : String? = nil

    # `text` re-spelled from `from` to `to`, plus one `Change` per edit.
    #
    # Byte-level throughout (`Bytes` in, `Bytes` out): a stored request body is routinely not
    # valid UTF-8, and `String#gsub` needs a `Regex` that is — the same reason `Env.expand` is
    # byte-level. Returns the SAME slice when nothing changed, so a caller can test identity.
    #
    # `env_names` / `bind_names` are the two tables' KEYS, bare — global env vars ∪ this
    # project's project vars, and the project's declared binding names ∪ the names its session
    # slots claim. Which table a name is routed to, and which one wins when both hold it, is the
    # CONSUMER's question: see `route`.
    #
    # `enabled_bind_names` is the NARROWER binding set: the names an ENABLED extract rule declares,
    # which is the only half of `bind_names` that ever RESOLVED (`Bindings#values` and
    # `Bindings#declared` both filter on `enabled?`). It decides precedence and the ambiguity flag,
    # and for a rule replacement it decides membership outright — see `route`. Defaults to
    # `bind_names`, so a caller that does not know the distinction keeps the behaviour it had.
    #
    # `hints`, when given, collects the spellings a `Kind::Dial` row carries that the TARGET grammar
    # would resolve and this kind cannot escape — the one thing a re-spelling can neither fix nor
    # ignore, so it is said out loud instead (`EnvMigration::StoreReport#notices`).
    def self.rewrite(bytes : Bytes, *, from : Env::Syntax, to : Env::Syntax,
                     env_names : Enumerable(String), bind_names : Enumerable(String),
                     enabled_bind_names : Enumerable(String)? = nil,
                     kind : Kind = Kind::Request,
                     prefix : String = Settings.env_prefix,
                     hints : Array(String)? = nil) : {Bytes, Array(Change)}
      changes = [] of Change
      return {bytes, changes} if from == to || prefix.empty? || bytes.empty?
      env = env_names.to_set
      bind = bind_names.to_set
      live = enabled_bind_names ? enabled_bind_names.to_set : bind
      plen = prefix.bytesize
      # `Owns::None` turns escape RECOGNITION off, which is what the rule and display grammars
      # want: `$$` is theirs, and the reader must not claim it (nor read the name behind it).
      escapes = kind.consumes_escape? ? Env::Owns::All : Env::Owns::None
      buf = IO::Memory.new(bytes.size)
      i = 0
      n = bytes.size
      while i < n
        # No pre-test for the sigil: this runs once over a handful of stored rows, and one reader
        # is worth more here than a byte loop that could disagree with it. `read_token_at`
        # returns nil at every byte that is not a sigil.
        found = Env.read_token_at(bytes, i, n, syntax: from, prefix: prefix, escapes: escapes)
        unless found
          buf.write_byte(bytes[i])
          i += 1
          next
        end
        # `$$` in a grammar that owns it: both sigils through, nothing behind them read — the
        # same claim `Rules#substitute` makes, so the two agree about where a token can start.
        if !kind.consumes_escape? && double_sigil?(bytes, prefix, i, n)
          buf.write(bytes[i, 2 * plen])
          i += 2 * plen
          next
        end
        consumed =
          if from.bare?
            forward(bytes, buf, changes, found, i, n, plen, prefix, env, bind, live, kind)
          else
            backward(bytes, buf, changes, found, i, n, plen, prefix, env, bind, live, kind, hints)
          end
        i += consumed
      end
      changes.empty? ? {bytes, changes} : {buf.to_slice, changes}
    end

    # BARE → NAMESPACED. Returns how many bytes of the input this step claimed.
    private def self.forward(bytes, buf, changes, found : Env::Found, i, n, plen, prefix,
                             env : Set(String), bind : Set(String), live : Set(String),
                             kind : Kind) : Int32
      case found.kind
      when Env::Kind::Escape
        # A bare escape is anonymous (`$$`, nothing behind it read). Under the namespaced grammar
        # the SAME two bytes in front of a `NS.NAME` are already that grammar's escape for the
        # same wire bytes, so leave them; in front of anything else `$$` no longer means one `$`,
        # and dropping a sigil is the only way the wire stays put.
        if namespaced_ref_at?(bytes, i + plen, n, prefix)
          buf.write(bytes[i, found.width])
        else
          buf << prefix
          changes << Change.new(i, prefix * 2, prefix, nil, note: "escape")
        end
        found.width
      when Env::Kind::Token
        if ns = route(found.name, env, bind, live, kind)
          after = Env.spell(found.name, ns, Env::Syntax::Namespaced, prefix)
          buf << after
          changes << Change.new(i, Env.spell(found.name, ns, Env::Syntax::Bare, prefix), after,
            Env::Ref.new(ns, found.name), ambiguous: ambiguous?(found.name, env, live, kind))
        else
          # A name in neither table is a literal in BOTH grammars — a GraphQL `$id`, a Mongo
          # `$ne`. Touching it is how a migration invents a reference nobody wrote.
          buf.write(bytes[i, found.width])
        end
        found.width
      else
        buf.write(bytes[i, found.width])
        found.width
      end
    end

    # NAMESPACED → BARE. The lossy direction, and the reason is here: bare resolves a name by
    # SHAPE, so text that was inert under the namespaced grammar can start resolving.
    private def self.backward(bytes, buf, changes, found : Env::Found, i, n, plen, prefix,
                              env : Set(String), bind : Set(String), live : Set(String),
                              kind : Kind, hints : Array(String)?) : Int32
      case found.kind
      when Env::Kind::Escape
        # `$$ENV.X` → bare consumes `$$` and never reads the name behind it, so the very same
        # bytes ship `$ENV.X` in both grammars. Nothing to do, which is the answer that keeps
        # the wire byte-exact.
        buf.write(bytes[i, found.width])
        found.width
      when Env::Kind::Token
        ns = found.ns || Env::Namespace::Env
        after = Env.spell(found.name, ns, Env::Syntax::Bare, prefix)
        buf << after
        changes << Change.new(i, Env.spell(found.name, ns, Env::Syntax::Namespaced, prefix),
          after, Env::Ref.new(ns, found.name),
          ambiguous: ambiguous?(found.name, env, live, kind))
        found.width
      else
        # A LITERAL sigil, and the only place this direction adds bytes — for the kinds that CAN
        # add them. Bare would either pair it into an escape (a sigil right behind it) or resolve
        # the name behind it, so an escape has to be written now or these bytes mean something new.
        #
        # `escapes_literal?` is why `kind` is a parameter and not decoration. Display text is
        # expanded by nothing, so `$$id` there is not an escape — it is two characters in an issue
        # title, and doubling the sigil corrupted the text it was supposed to preserve. A dial
        # tuple IS expanded, but with `Escape::Preserve` and never unescaped, so `$$id` in a target
        # reaches the resolver as `$$id`: the name is NAMED to the operator instead.
        name = resolvable_name_at(bytes, i + plen, n, env, bind, live, kind)
        unless kind.escapes_literal?
          if name && hints && kind.bare_resolution_hint?
            hints << Env.spell(name, Env::Namespace::Env, Env::Syntax::Bare, prefix)
          end
          buf.write(bytes[i, found.width])
          return found.width
        end
        if found.width == plen && (name || double_sigil?(bytes, prefix, i, n))
          buf << prefix << prefix
          # Reported with the NAME when there is one (`$id → $$id`), because that is the line an
          # operator reads the report for; a doubled sigil in front of another sigil has no name
          # to carry and says only what it did. Spelled through the formatter family so a
          # non-default sigil is not hand-concatenated into the report either.
          ns = Env::Namespace::Env
          changes << Change.new(i,
            name ? Env.spell(name, ns, Env::Syntax::Bare, prefix) : prefix,
            name ? Env.spell_escaped(name, ns, Env::Syntax::Bare, prefix) : "#{prefix}#{prefix}",
            nil, note: "escape")
          plen
        else
          buf.write(bytes[i, found.width])
          found.width
        end
      end
    end

    # Which namespace a bare `$NAME` belonged to — answered by THE CONSUMER of these bytes, not by
    # a house rule.
    #
    # The bare grammar resolved a name by shape, and the three consumers did not resolve the same
    # shapes in the same order. Getting this wrong is silent: the name exists in both tables, both
    # spellings look right, and the wire carries the OTHER value.
    #
    #   * `Request` (and `Display`, which resolves nothing and only needs a consistent spelling):
    #     the send path runs the ENV pass at plan-build and the BINDING pass at the seam, so ENV
    #     ran FIRST and the binding pass never saw the token. ENV wins; the `ambiguous` flag is how
    #     the operator hears that the other reading existed.
    #   * `Rule`: `Rules#substitute` resolves against ONE merged table, `Env.display_vars`, which
    #     layers the binding values OVER the env vars — so the BINDING is what a bare rule
    #     replacement actually injected. And only an ENABLED one: both halves of that table
    #     (`Bindings#values`, `Bindings#declared`) filter on `enabled?`, which is why this kind asks
    #     `live` and not `bind`. Routing a DISABLED rule's name to BIND was a wire change in the
    #     worst shape available — a name that is both an env var and a switched-off extract rule
    #     injected the ENV value under bare and became a `$BIND.name` that resolves in no table, so
    #     the rule silently started shipping its own spelling into live traffic.
    #
    #     A name that is ONLY a disabled binding routes NOWHERE and stays a bare literal, which is
    #     what bare shipped for it too (no value, not declared → literal). Nothing is lost by
    #     leaving it: the moment the operator switches that rule back on, `Rules#substitute`'s
    #     `BareSpelling` refusal names the re-spelling instead of injecting the text.
    #   * `Slot`: `Env.expand_bindings_as` is the only pass over a slot header value and it
    #     resolves BIND alone. An env-only name there is not a token at all: it shipped as literal
    #     text under bare, and leaving it a bare literal is the same wire. The DECLARED set rather
    #     than `live`, because a slot header is a reference by construction — `Env.unbound_in_slot`
    #     counts a name the slot merely claims — and `$BIND.X` is the spelling that keeps working
    #     when its rule comes back on.
    #   * `Dial`: one `Env.expand` with `resolve: Owns::Env`. The ENV table alone.
    private def self.route(name : String, env : Set(String), bind : Set(String),
                           live : Set(String), kind : Kind) : Env::Namespace?
      case kind
      when .rule?
        return Env::Namespace::Bind if live.includes?(name)
        env.includes?(name) ? Env::Namespace::Env : nil
      when .slot?
        bind.includes?(name) ? Env::Namespace::Bind : nil
      when .dial?
        env.includes?(name) ? Env::Namespace::Env : nil
      else
        return Env::Namespace::Env if env.includes?(name)
        bind.includes?(name) ? Env::Namespace::Bind : nil
      end
    end

    # A name this KIND could have resolved out of either table — the one case the bare grammar
    # could not distinguish and this one can. Not every kind has the ambiguity: a slot header and a
    # dial tuple resolve one table, so there was never a second reading to lose.
    #
    # Asked of `live`, not of `bind`: a DISABLED extract rule resolved nothing under bare either, so
    # a name it happens to share with an env var had exactly one reading, and flagging it ambiguous
    # would send an operator looking for a choice that was never offered.
    private def self.ambiguous?(name : String, env : Set(String), live : Set(String),
                                kind : Kind) : Bool
      return false if kind.slot? || kind.dial?
      env.includes?(name) && live.includes?(name)
    end

    private def self.double_sigil?(bytes : Bytes, prefix : String, at : Int32, n : Int32) : Bool
      plen = prefix.bytesize
      at + 2 * plen <= n && Env.prefix_at?(bytes, prefix, at) && Env.prefix_at?(bytes, prefix, at + plen)
    end

    # A `$NS.NAME` token (NOT an escape) starting at `at` — what decides whether a bare `$$` in
    # front of it is already the namespaced escape for the same bytes.
    private def self.namespaced_ref_at?(bytes : Bytes, at : Int32, n : Int32,
                                        prefix : String) : Bool
      found = Env.read_token_at(bytes, at, n, syntax: Env::Syntax::Namespaced, prefix: prefix,
        escapes: Env::Owns::None)
      !!found.try(&.kind.token?)
    end

    # The bare NAME at `at` that THIS CONSUMER would resolve under the bare grammar, or nil. Asked
    # through `route` so the tables and their order are named in exactly one place: a slot header
    # resolves bindings alone, so an env-only name there needs no escape — it was literal text
    # before the switch and stays literal text after it.
    private def self.resolvable_name_at(bytes : Bytes, at : Int32, n : Int32,
                                        env : Set(String), bind : Set(String), live : Set(String),
                                        kind : Kind) : String?
      parsed = Env.read_key_bytes?(bytes, at, n)
      return nil unless parsed
      name = parsed[0]
      route(name, env, bind, live, kind) ? name : nil
    end

    # ── the wire check ────────────────────────────────────────────────────────
    #
    # Whether `after` sends exactly what `before` sent. Every name is given a SENTINEL value
    # instead of its real one — distinct per namespace, so a token routed to the wrong table is
    # a difference rather than a coincidence — and both texts are run through the two passes a
    # request really takes (env vars at plan-build, bindings at the send seam).
    #
    # For every kind that HAS a wire, which is all but `Display`. They do not share a pass list,
    # so `kind` picks it — a slot header value is only ever seen by the binding seam, a dial tuple
    # only by the env pass, a rule replacement only by `Rules#substitute` — and asking the request
    # model of any of them would call a row unsafe for a pass that never runs over it.
    #
    # The BINDING sentinels come from `enabled_bind_names`, because that is the only half of the
    # binding table that ever resolved: giving a disabled rule's name a value would have this check
    # bless a routing that ships nothing.
    def self.safe?(before : Bytes, after : Bytes, *, from : Env::Syntax, to : Env::Syntax,
                   env_names : Enumerable(String), bind_names : Enumerable(String),
                   enabled_bind_names : Enumerable(String)? = nil,
                   kind : Kind = Kind::Request,
                   prefix : String = Settings.env_prefix) : Bool
      env = sentinels(env_names, "E")
      bind = sentinels(enabled_bind_names || bind_names, "B")
      wire(before, from, env, bind, prefix, kind) == wire(after, to, env, bind, prefix, kind)
    end

    private def self.sentinels(names : Enumerable(String), tag : String) : Hash(String, String)
      h = {} of String => String
      # No sigil in a sentinel: a value that carried one would be re-read by the second pass and
      # the check would be testing the sentinel rather than the text.
      names.each { |n| h[n] = "#{tag}:#{n}" }
      h
    end

    # The passes THIS kind's bytes really go through, in the order a send path runs them.
    # `Preserve`/`Consume` are the bare grammar's knobs and map onto `Owns` exactly as production
    # does (`Env.unescape_set`).
    private def self.wire(bytes : Bytes, syntax : Env::Syntax, env : Hash(String, String),
                          bind : Hash(String, String), prefix : String, kind : Kind) : String
      # A RULE REPLACEMENT is resolved by `Rules#substitute`, whose grammar is nobody else's:
      # it owns `$$` and `$1..$9` in BOTH syntaxes and resolves against ONE table with the
      # bindings layered over the env vars. Modelled directly rather than approximated with two
      # `Env.expand` passes, which disagree with it about `$$` in namespaced mode.
      return rule_wire(bytes, syntax, env, bind, prefix) if kind.rule?
      text = String.new(bytes)
      # A SLOT header value: `Env.expand_bindings_as` and nothing else. It is the last pass before
      # the socket, so it consumes the escape, and it resolves BIND alone.
      if kind.slot?
        return Env.expand(text, bind, prefix, nil, Env::Escape::Consume,
          syntax: syntax, resolve: Env::Owns::Bind, bind_vars: bind)
      end
      built = Env.expand(text, env, prefix, nil, Env::Escape::Preserve,
        syntax: syntax, resolve: Env::Owns::Env)
      # A DIAL TUPLE stops there: one `Env.expand`, never re-scanned, which is exactly why nothing
      # unescapes it.
      return built if kind.dial?
      Env.expand(built, bind, prefix, nil, Env::Escape::Consume,
        syntax: syntax, resolve: Env::Owns::Bind, bind_vars: bind)
    end

    # `Rules#substitute`'s grammar, as a model: `$$` → one sigil (both syntaxes), `$1..$9` copied
    # through unchanged (identical on both sides, so the regex/literal distinction cannot decide
    # this check), and a token resolved out of the table its namespace names — bare's ONE table
    # being the env vars with the bindings layered OVER them, which is the precedence `route`
    # follows for this kind.
    #
    # Byte-level and reader-driven, like everything else here: a replacement is operator bytes and
    # a `Regex` over them would need valid UTF-8.
    private def self.rule_wire(bytes : Bytes, syntax : Env::Syntax, env : Hash(String, String),
                               bind : Hash(String, String), prefix : String) : String
      merged = env.dup
      bind.each { |(k, v)| merged[k] = v }
      plen = prefix.bytesize
      n = bytes.size
      buf = IO::Memory.new(n)
      i = 0
      while i < n
        unless Env.prefix_at?(bytes, prefix, i)
          buf.write_byte(bytes[i])
          i += 1
          next
        end
        if Env.prefix_at?(bytes, prefix, i + plen)
          buf << prefix
          i += 2 * plen
          next
        end
        found = Env.read_token_at(bytes, i, n, syntax: syntax, prefix: prefix,
          escapes: Env::Owns::None)
        if found && found.kind.token?
          table = rule_table(found.ns, merged, env, bind)
          if v = table[found.name]?
            buf << v
            i += found.width
            next
          end
          w = found.miss_width(plen, syntax)
          buf.write(bytes[i, w])
          i += w
          next
        end
        buf << prefix
        i += plen
      end
      String.new(buf.to_slice)
    end

    # Which table `Rules#substitute` resolves one token out of. Exhaustive over the namespace set,
    # so a THIRD namespace is a compile error here rather than a silent trip through the env vars.
    private def self.rule_table(ns : Env::Namespace?, merged : Hash(String, String),
                                env : Hash(String, String),
                                bind : Hash(String, String)) : Hash(String, String)
      return merged unless ns
      case ns
      in Env::Namespace::Env  then env
      in Env::Namespace::Bind then bind
      end
    end
  end
end
