require "./env"

module Gori
  # One-shot re-spelling of STORED env tokens when an install changes `Settings.env_syntax`
  # (`gori settings env-syntax <value> --migrate`).
  #
  # A syntax switch re-reads bytes that are already in the project databases; it does not rewrite
  # them (see `Env::Syntax`). That is the safe default and it stays the default — but it leaves an
  # operator who switches with a project full of `$API_KEY` drafts holding text that is now
  # literal. This module is the opt-in other half: the PURE rewrite, so the CLI verb (and a TUI
  # action later) only has to orchestrate stores around it.
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
  module EnvMigration
    # WHICH grammar the text belongs to, which is a different question from which SYNTAX spells
    # its tokens. `$$` and `$1` mean different things in a request, in a rewrite rule's
    # replacement and in a line of display text, and a migration that gets that wrong silently
    # edits an operator's payload.
    enum Kind
      # Request / payload bytes, and a session-slot header value: the send seam owns `$$` and
      # consumes it, so the migration owns it too.
      Request
      # A rewriter rule's `replacement`. `Rules#substitute` owns `$$` (→ one `$`, nothing behind
      # it read) and `$1..$9` (a regex backref) in BOTH syntaxes, so both are copied through and
      # only a `$NAME` token is re-spelled.
      Rule
      # Text a masking pass wrote a token into — an issue title, a note body, a Repeater name.
      # Nothing ever expands it, so there is no escape to pair: `$$` is two bytes of text.
      Display

      # Whether `$$` is this grammar's ESCAPE (and therefore the migration's business) or just
      # bytes that belong to the surrounding grammar.
      def consumes_escape? : Bool
        request?
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
    # slots claim. A name in both is routed to `ENV` and flagged.
    def self.rewrite(bytes : Bytes, *, from : Env::Syntax, to : Env::Syntax,
                     env_names : Enumerable(String), bind_names : Enumerable(String),
                     kind : Kind = Kind::Request,
                     prefix : String = Settings.env_prefix) : {Bytes, Array(Change)}
      changes = [] of Change
      return {bytes, changes} if from == to || prefix.empty? || bytes.empty?
      env = env_names.to_set
      bind = bind_names.to_set
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
            forward(bytes, buf, changes, found, i, n, plen, prefix, env, bind, kind)
          else
            backward(bytes, buf, changes, found, i, n, plen, prefix, env, bind, kind)
          end
        i += consumed
      end
      changes.empty? ? {bytes, changes} : {buf.to_slice, changes}
    end

    # BARE → NAMESPACED. Returns how many bytes of the input this step claimed.
    private def self.forward(bytes, buf, changes, found : Env::Found, i, n, plen, prefix,
                             env : Set(String), bind : Set(String), kind : Kind) : Int32
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
        if ns = route(found.name, env, bind)
          after = Env.spell(found.name, ns, Env::Syntax::Namespaced, prefix)
          buf << after
          changes << Change.new(i, "#{prefix}#{found.name}", after, Env::Ref.new(ns, found.name),
            ambiguous: env.includes?(found.name) && bind.includes?(found.name))
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
                              env : Set(String), bind : Set(String), kind : Kind) : Int32
      case found.kind
      when Env::Kind::Escape
        # `$$ENV.X` → bare consumes `$$` and never reads the name behind it, so the very same
        # bytes ship `$ENV.X` in both grammars. Nothing to do, which is the answer that keeps
        # the wire byte-exact.
        buf.write(bytes[i, found.width])
        found.width
      when Env::Kind::Token
        after = "#{prefix}#{found.name}"
        ns = found.ns || Env::Namespace::Env
        buf << after
        changes << Change.new(i, Env.spell(found.name, ns, Env::Syntax::Namespaced, prefix),
          after, Env::Ref.new(ns, found.name),
          ambiguous: env.includes?(found.name) && bind.includes?(found.name))
        found.width
      else
        # A LITERAL sigil, and the only place this direction adds bytes. Bare would either pair
        # it into an escape (a sigil right behind it) or resolve the name behind it; either way
        # the escape has to be written now, or these bytes mean something new.
        if found.width == plen && (double_sigil?(bytes, prefix, i, n) ||
           resolvable_name_at?(bytes, i + plen, n, env, bind))
          buf << prefix << prefix
          changes << Change.new(i, prefix, prefix * 2, nil, note: "escape")
          plen
        else
          buf.write(bytes[i, found.width])
          found.width
        end
      end
    end

    # ENV wins a name held in both tables, because that is what the bare grammar DID: the
    # build-time pass ran first and the binding pass never saw the token. The migration's job is
    # to preserve the wire, not to improve it — the flag is how the operator hears about it.
    private def self.route(name : String, env : Set(String), bind : Set(String)) : Env::Namespace?
      return Env::Namespace::Env if env.includes?(name)
      return Env::Namespace::Bind if bind.includes?(name)
      nil
    end

    private def self.double_sigil?(bytes : Bytes, prefix : String, at : Int32, n : Int32) : Bool
      plen = prefix.bytesize
      at + 2 * plen <= n && at_prefix?(bytes, prefix, at) && at_prefix?(bytes, prefix, at + plen)
    end

    # A `$NS.NAME` token (NOT an escape) starting at `at` — what decides whether a bare `$$` in
    # front of it is already the namespaced escape for the same bytes.
    private def self.namespaced_ref_at?(bytes : Bytes, at : Int32, n : Int32,
                                        prefix : String) : Bool
      found = Env.read_token_at(bytes, at, n, syntax: Env::Syntax::Namespaced, prefix: prefix,
        escapes: Env::Owns::None)
      !!found.try(&.kind.token?)
    end

    # A bare NAME at `at` that the bare grammar would resolve out of either table.
    private def self.resolvable_name_at?(bytes : Bytes, at : Int32, n : Int32,
                                         env : Set(String), bind : Set(String)) : Bool
      parsed = Env.read_key_bytes?(bytes, at, n)
      return false unless parsed
      name = parsed[0]
      env.includes?(name) || bind.includes?(name)
    end

    private def self.at_prefix?(bytes : Bytes, prefix : String, at : Int32) : Bool
      pb = prefix.to_slice
      return false if at < 0 || at + pb.size > bytes.size
      j = 0
      while j < pb.size
        return false if bytes[at + j] != pb[j]
        j += 1
      end
      true
    end

    # ── the wire check ────────────────────────────────────────────────────────
    #
    # Whether `after` sends exactly what `before` sent. Every name is given a SENTINEL value
    # instead of its real one — distinct per namespace, so a token routed to the wrong table is
    # a difference rather than a coincidence — and both texts are run through the two passes a
    # request really takes (env vars at plan-build, bindings at the send seam).
    #
    # For `Kind::Request` only: it is the kind with a wire. A rule replacement is resolved by
    # `Rules#substitute` against its own grammar, and display text is resolved by nothing.
    def self.safe?(before : Bytes, after : Bytes, *, from : Env::Syntax, to : Env::Syntax,
                   env_names : Enumerable(String), bind_names : Enumerable(String),
                   prefix : String = Settings.env_prefix) : Bool
      env = sentinels(env_names, "E")
      bind = sentinels(bind_names, "B")
      wire(before, from, env, bind, prefix) == wire(after, to, env, bind, prefix)
    end

    private def self.sentinels(names : Enumerable(String), tag : String) : Hash(String, String)
      h = {} of String => String
      # No sigil in a sentinel: a value that carried one would be re-read by the second pass and
      # the check would be testing the sentinel rather than the text.
      names.each { |n| h[n] = "#{tag}:#{n}" }
      h
    end

    # The two passes, in the order a send path runs them. `Preserve`/`Consume` are the bare
    # grammar's knobs and map onto `Owns` exactly as production does (`Env.unescape_set`).
    private def self.wire(bytes : Bytes, syntax : Env::Syntax, env : Hash(String, String),
                          bind : Hash(String, String), prefix : String) : String
      built = Env.expand(String.new(bytes), env, prefix, nil, Env::Escape::Preserve,
        syntax: syntax, resolve: Env::Owns::Env)
      Env.expand(built, bind, prefix, nil, Env::Escape::Consume,
        syntax: syntax, resolve: Env::Owns::Bind, bind_vars: bind)
    end
  end
end
