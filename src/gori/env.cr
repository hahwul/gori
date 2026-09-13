require "json"
require "./settings"
require "./session_slot"
require "./store"

module Gori
  # Global + per-project environment variables for `$KEY`-style substitution in
  # outbound requests (Repeater, Fuzzer, Miner, Intercept, CLI, MCP). The editor
  # keeps the raw `$KEY` text; `expand` runs at send time only. Highlighting
  # reuses the same prefix/KEY rules via `token_regions`.
  module Env
    DEFAULT_PREFIX   = "$"
    PROJECT_VARS_KEY = "env.vars"

    # WHICH grammar the tokens stored in THIS project database are spelled in — the per-project
    # marker beside `env.vars` on the same settings KV. ABSENT means bare, which is exactly true of
    # every database written before namespaces existed; `EnvMigration.reconcile` compares it with
    # `Settings.env_syntax` the first time a surface opens the project and re-spells the rows when
    # they disagree.
    PROJECT_SYNTAX_KEY = "env.syntax"

    KEY_HEAD = /[A-Za-z_]/
    KEY_TAIL = /[A-Za-z0-9_]/

    # ── how a token is SPELLED (`Settings.env_syntax`) ────────────────────────
    #
    # `$NAME`'s grammar is byte-identical to a GraphQL variable (`$id`), a MongoDB operator
    # (`$ne`, `$where`), an OData option (`$filter`) and a JSON Schema keyword (`$ref`), and a
    # scan runs over the whole message INCLUDING the body. The provenance guards close that
    # for EVIDENCE bytes (a captured replay expands nothing), but they cannot close it for
    # DRAFT bytes — a paste, a `^E` round trip, `gori run repeater -r`, MCP `raw`/`body`, an
    # intercept edit-forward — because those have no provenance boundary at all. So the intent
    # goes IN THE BYTES:
    #
    #   * `Bare` — `$NAME`. What every install shipped with, and what an existing install
    #     keeps forever: the tokens are already written into project DBs, drafts, rule
    #     replacements and slot headers, and gori does not rewrite those behind the operator.
    #   * `Namespaced` — `$ENV.NAME` (build-time env vars) and `$BIND.NAME` (send-time session
    #     bindings). `$id` / `$ne` / `$ref` are then not references at all and need NO escape.
    #
    # A genuinely NEW home adopts `Namespaced` (`Settings.adopt_env_syntax_for_new_home`); the
    # ABSENCE of `env.syntax` in a settings file that was read in full means `Bare`, forever.
    enum Syntax
      Bare
      Namespaced
    end

    # WHICH resolution layer a scan is acting for — its tokens AND its escapes. A pass owns
    # exactly one namespace and copies everything else through byte-exact, which is what makes
    # two passes over one String (env vars at plan-build, bindings at send) composable: the
    # first pass cannot consume the second's escape, and the second cannot resolve a name the
    # first deliberately left literal.
    #
    # `None`/`All` come free with `@[Flags]`. In BARE mode a token carries no namespace, so
    # `All`/`None` is the whole question there (see `unescape_set`).
    @[Flags]
    enum Owns
      Env
      Bind
    end

    # The closed set of namespaces. UPPERCASE and case-sensitive: `$env.x` and `$Env.x` are not
    # tokens, so the spelling an operator reads is the spelling gori resolves.
    #
    # This is also the extension point the syntax was chosen for — a future generator namespace
    # (`RAND`, `OAST`, `TIME`) adds a member here and a resolution table in `vars_for`, with no
    # new grammar and no new escape.
    enum Namespace
      Env
      Bind

      # The literal that spells this namespace in a token — `$ENV.HOST`.
      def label : String
        case self
        in Namespace::Env  then "ENV"
        in Namespace::Bind then "BIND"
        end
      end

      # One line for a completion row / a settings hint. Kept to ≤ 24 cells: the TUI completer
      # prints it beside the label inside a dropdown that must fit a 60-column pane.
      def description : String
        case self
        in Namespace::Env  then "build-time env vars"
        in Namespace::Bind then "session bindings"
        end
      end

      # Whether a VALUE in this namespace must be masked wherever it is shown. A binding value
      # was observed from a real response — a session cookie, a bearer — so the peek, the
      # completion hint and every export treat it as secret. The policy lives with the
      # namespace rather than at each surface, which is how three surfaces come to disagree.
      def secret? : Bool
        bind?
      end

      def owns : Owns
        case self
        in Namespace::Env  then Owns::Env
        in Namespace::Bind then Owns::Bind
        end
      end

      # Whether this namespace resolves at SEND time rather than at plan-build. It is what decides
      # whether a scan may hand a token to a later pass (`scan_unresolved`'s `bind_resolvable`) and
      # whether a name can be DECLARED-but-unbound at all — asked here, exhaustively, rather than
      # spelled `ns.bind?` at each site, so a third namespace has to answer the question instead of
      # silently inheriting the env layer's answer.
      def send_time? : Bool
        case self
        in Namespace::Env  then false
        in Namespace::Bind then true
        end
      end

      # Case-SENSITIVE, deliberately: see the note above the enum.
      def self.parse?(s : String) : Namespace?
        NAMESPACES[s]?
      end
    end

    NAMESPACES = {"ENV" => Namespace::Env, "BIND" => Namespace::Bind}

    # The match order: LONGEST label first, so a future namespace whose label is a prefix of
    # another cannot shadow it. (`ENV`/`BIND` share no prefix; the rule is stated in code so
    # adding the third one is not a silent hazard.)
    private NAMESPACE_MATCH = NAMESPACES.to_a.sort_by { |(label, _)| -label.size }

    # One token's identity: WHICH table it resolves from and the name in that table. A name in
    # two namespaces is two different references — which is why the pair travels together
    # wherever a list is PRINTED, and why a list that INDEXES a table carries bare names plus
    # an explicit namespace instead.
    record Ref, ns : Namespace, name : String do
      def qualified : String
        Env.qualify(ns, name)
      end
    end

    # What `read_token_at` found at a sigil.
    enum Kind
      Token   # a reference: resolve it if this pass owns the namespace
      Escape  # `$$ENV.X` / bare `$$`: the operator asking for the literal spelling
      Literal # a sigil that opens nothing — copy `width` bytes and keep scanning
    end

    # `at` is where the SIGIL is; `width` spans the whole thing the reader claimed.
    record Found, kind : Kind, ns : Namespace?, name : String, at : Int32, width : Int32 do
      # How far a scan advances after a Token it owns but cannot resolve.
      #
      # BARE keeps advancing by the PREFIX alone — byte-identical to what shipped, where an
      # unknown `$AB` re-enters the scan at `A` — while a NAMESPACED miss consumes the whole
      # `$NS.NAME`, because there is nothing inside it that could open a second token.
      def miss_width(plen : Int32, syntax : Syntax) : Int32
        syntax.bare? ? plen : width
      end

      # What follows the single surviving sigil when a pass CONSUMES this escape: `ENV.NAME`
      # under the namespaced syntax, nothing under the bare one (`$$` → `$`).
      def escaped_text : String
        (n = ns) ? "#{n.label}.#{name}" : ""
      end

      # Whether `set` is the pass that resolves this token. A BARE token names no namespace, so
      # any pass that resolves anything owns it — the single-table behaviour that shipped.
      def owned_by?(set : Owns) : Bool
        (n = ns) ? set.includes?(n.owns) : !set.none?
      end
    end

    # One painted token, in CHAR offsets (`[start, stop)`) — see `regions`.
    record Region, start : Int32, stop : Int32, ns : Namespace?, name : String, known : Bool

    # What a scan does with `$$`, the ONE escape and the only way to put a literal `$NAME`
    # on the wire.
    #
    # `$NAME`'s grammar (`$` + `[A-Za-z_]` + `[A-Za-z0-9_]*`) is byte-identical to a GraphQL
    # variable reference, a MongoDB operator and a JSON Schema keyword, and the scan runs over
    # the whole message including the body. Those are not chance collisions — a parameterised
    # GraphQL document is MADE of `$id` / `$input` / `$userId`, and `id` / `ref` / `token` are
    # the most obvious names an operator gives an env var or an extract rule. So the operator
    # needs a way to say "this `$` is mine". `Rules#substitute` has had one since #501; this
    # brings the same spelling to every other seam.
    #
    # TWO modes because a request is expanded TWICE — the ENV-VAR layer at plan-build
    # (`expand_wire`, #356) and the BINDING layer at send (`expand_bindings`, #501) — and a
    # String is the only channel between them. Consuming the escape in the first pass would
    # hand the second pass a bare `$id` it would then resolve, so `$$id` would still not
    # survive. The layer that runs LAST is therefore the one that consumes:
    #
    #   * `Preserve` — the env-var pass. `$$` is copied through as `$$` and the token behind
    #     it is NOT read, so an env var named `id` cannot resolve into `$$id`.
    #   * `Consume` — `expand_bindings`, the send seam every wire path passes through
    #     (`Repeater::Sender`, `Fuzz::Sender`, `Discover::Engine`). `$$` → one literal `$`,
    #     the token behind it left alone.
    #
    # A surface whose env pass IS the last pass (the TUI intercept editor forwards straight to
    # the origin) asks for `Consume` explicitly. An EVIDENCE path expands nothing at all and
    # so unescapes nothing: a `$$` in captured bytes is two bytes the origin sent, not an
    # escape the operator typed.
    #
    # One place deliberately keeps `$$` as two bytes: a DIAL TUPLE (a `--target`, a URL, an
    # SNI). Those run `Env.expand` once and are never re-scanned by a send seam, so nothing
    # consumes the escape — and there is nothing to escape FROM, because `$` is not a legal
    # byte in a hostname. `unresolved` still walks the escape correctly, so a
    # `$$` there cannot be mis-reported as an unresolved name; it simply fails to resolve as a
    # host, visibly, which is the honest outcome.
    #
    # Escapes pair left to right, one `$` out per `$$` in: `$$id` → `$id`, `$$$$` → `$$`,
    # `$$$id` → `$` followed by an INTERPRETED `$id`.
    #
    # A BARE-MODE KNOB ONLY. Under `Syntax::Namespaced` the escape is namespaced too —
    # `$$ENV.X` and `$$BIND.X` are escapes, each consumed by the pass that owns that namespace
    # (`Owns`), a bare `$$` is two literal bytes with the second sigil re-examined, and there is
    # therefore nothing left for a "which pass consumes" flag to decide. `unescape_set` maps
    # this enum onto `Owns` for the bare case and ignores it for the namespaced one; a caller
    # that wants to say it directly passes `unescape:`.
    enum Escape
      Preserve
      Consume
    end

    @@highlight_rev : UInt32 = 0

    def self.highlight_rev : UInt32
      @@highlight_rev
    end

    def self.bump_highlight_rev : Nil
      @@highlight_rev += 1
    end

    # Merged vars: global first, then project (project wins on KEY collision).
    def self.effective_vars : Hash(String, String)
      h = {} of String => String
      Settings.env_vars.each { |(k, v)| h[k] = v }
      Settings.project_env_vars.each { |(k, v)| h[k] = v }
      h
    end

    # ── the formatter family: the ONLY code in the repo that spells a token ────
    #
    # Every surface that prints a token — a completion row, a peek label, a refusal, a log
    # line, a settings hint, a masked byte range — goes through one of these. Spelling is
    # mode-dependent now, and a hardcoded `"$#{name}"` is a sentence that is simply false on
    # half the installs; there were forty of them, and this is where they went.

    # `"$ENV.HOST"` (namespaced) or `"$HOST"` (bare). A `name` that is ALREADY qualified
    # (`"ENV.HOST"`) carries its own namespace and `ns` is ignored — so a caller holding a name
    # out of a printed list cannot double-qualify it.
    def self.spell(name : String, ns : Namespace, syntax : Syntax = Settings.env_syntax,
                   prefix : String = Settings.env_prefix) : String
      found, bare = split_qualified(name)
      return "#{prefix}#{bare}" if syntax.bare?
      "#{prefix}#{(found || ns).label}.#{bare}"
    end

    def self.spell(ref : Ref, syntax : Syntax = Settings.env_syntax,
                   prefix : String = Settings.env_prefix) : String
      spell(ref.name, ref.ns, syntax, prefix)
    end

    # The ESCAPED spelling — what an operator writes to put the token's own text on the wire.
    # `"$$BIND.SESSION"` / `"$$SESSION"`. For a HINT: every sentence that offers the escape as
    # a remedy has to offer the one that actually works in this mode.
    def self.spell_escaped(name : String, ns : Namespace, syntax : Syntax = Settings.env_syntax,
                           prefix : String = Settings.env_prefix) : String
      "#{prefix}#{spell(name, ns, syntax, prefix)}"
    end

    # What an input field prints BEFORE a typed name: `"$BIND."` / `"$"`. A label like
    # `"name: $"` is the affordance that teaches the syntax, so it has to be the live one.
    def self.input_hint(ns : Namespace, syntax : Syntax = Settings.env_syntax,
                        prefix : String = Settings.env_prefix) : String
      syntax.bare? ? prefix : "#{prefix}#{ns.label}."
    end

    # The inverse of the spellings above, for a field an operator TYPES a name into:
    # `"$BIND.SESSION"`, `"BIND.SESSION"`, `"$SESSION"`, `"SESSION"` → `"SESSION"`.
    # Tolerant on purpose — the surfaces using it accept a name pasted from anywhere.
    #
    # Tolerant of the SPELLING, not of the namespace. The fields calling it are scoped to ONE
    # namespace (`ns`): an extract rule's name is a BIND name, and nothing else can be one. A
    # `"$ENV.TOKEN"` typed there is not a BIND rule named `TOKEN` under a mistyped prefix, it is
    # a reference to the other namespace — so `raw` comes back UNCHANGED and the caller's
    # validator (`Bindings#validate` / `valid_key?`) refuses it by name. Stripping it would have
    # created a rule the operator never asked for, whose token then resolves from the other
    # table.
    #
    # BARE mode strips the sigil and nothing else: there are no namespaces there, so `ENV.TOKEN`
    # is simply not a key and the validator says so.
    def self.strip_spelling(raw : String, ns : Namespace, syntax : Syntax = Settings.env_syntax,
                            prefix : String = Settings.env_prefix) : String
      s = strip_sigils(raw.strip, prefix)
      return s if syntax.bare?
      found, bare = split_qualified(s)
      return raw if found && found != ns
      bare
    end

    # ONE whole token back to a Ref, or nil when `text` is not one. `default_ns` answers for an
    # UNQUALIFIED spelling (which is every token in bare mode, and a name typed into a
    # namespace-scoped field in either).
    def self.parse_ref?(text : String, default_ns : Namespace = Namespace::Env,
                        syntax : Syntax = Settings.env_syntax,
                        prefix : String = Settings.env_prefix) : Ref?
      s = text.strip
      return nil if s.empty?
      s = strip_sigils(s, prefix)
      ns, bare = split_qualified(s)
      return nil unless valid_key?(bare)
      Ref.new(ns || default_ns, bare)
    end

    # Leading sigils removed (`"$$X"` → `"X"`), so a pasted escape reads as the name it escapes.
    private def self.strip_sigils(s : String, prefix : String) : String
      return s if prefix.empty?
      while s.starts_with?(prefix)
        s = s[prefix.size..]
      end
      s
    end

    # `"ENV.HOST"` — the key shape for a list that is PRINTED, a dedup set, or a literal-name
    # set. Never the shape for a table LOOKUP: `vars_for(ns)` is keyed by bare name.
    def self.qualify(ns : Namespace, name : String) : String
      "#{ns.label}.#{name}"
    end

    # `"ENV.HOST"` → `{Env, "HOST"}`; `"HOST"` → `{nil, "HOST"}`. A name whose own text contains
    # a dot but no known namespace comes back whole, so nothing is silently truncated.
    def self.split_qualified(name : String) : {Namespace?, String}
      NAMESPACE_MATCH.each do |entry|
        label, ns = entry
        next unless name.size > label.size && name.starts_with?(label) && name[label.size] == '.'
        return {ns, name[(label.size + 1)..]}
      end
      {nil, name}
    end

    # Render token names back into the spelling the operator typed, comma-joined. Every surface
    # quotes the same list, so the spelling is applied here rather than in five builders that
    # could each drift.
    #
    # `ns` qualifies BARE names (a list that came out of a table keyed by bare name — declared
    # binding names, a slot's rule list). Without it a name that is already qualified is spelled
    # as it stands and a bare one falls back to `ENV`, which is what a list out of `unresolved`
    # already carries.
    def self.token_list(names : Enumerable(String), prefix : String = Settings.env_prefix,
                        ns : Namespace? = nil) : String
      names.join(", ") { |n| spell(n, ns || Namespace::Env, Settings.env_syntax, prefix) }
    end

    # ── the resolution tables, per namespace ──────────────────────────────────
    #
    # `vars_for` is the ONE map from a namespace to the table that resolves it. Adding a
    # namespace is a member plus a branch here; nothing else in the scans changes.
    def self.vars_for(ns : Namespace) : Hash(String, String)
      case ns
      in Namespace::Env  then effective_vars
      in Namespace::Bind then binding_values
      end
    end

    # As if `slot` were the ACTIVE session slot — see `expand_bindings_as`.
    def self.vars_for(ns : Namespace, slot : String) : Hash(String, String)
      case ns
      in Namespace::Env  then effective_vars
      in Namespace::Bind then binding_values_as(slot)
      end
    end

    # What a MASKING surface must treat as secret in this namespace — wider than `vars_for` for
    # BIND, which keeps a disabled rule's value: it stopped RESOLVING, it did not stop being a
    # credential sitting in memory. See `masking_vars`.
    def self.masking_for(ns : Namespace) : Hash(String, String)
      case ns
      in Namespace::Env  then effective_vars
      in Namespace::Bind then (@@layer.try(&.held_values) || {} of String => String)
      end
    end

    # Every maskable value with the Ref that spells it, ENV first and BIND second.
    #
    # An ARRAY and not a Hash, because a name can exist in BOTH namespaces and the two are
    # different secrets with different spellings — merging them into one table is exactly the
    # collision the namespaces exist to remove. Order fixes the tie-break in `mask_secrets`.
    def self.masking_table : Array({Ref, String})
      out = [] of {Ref, String}
      Namespace.values.each do |ns|
        masking_for(ns).each { |(k, v)| out << {Ref.new(ns, k), v} }
      end
      out
    end

    # Whether `text` could hold a token one of `owns`' passes would act on — the cheap gate in
    # front of every scan on a send path.
    #
    # BARE can only ask "is there a sigil", which is why a message full of `$id` paid for a full
    # scan. NAMESPACED can ask for a `$NS.` OPENER, so the overwhelmingly common body — one
    # with `$id`, `$ne` or nothing at all — is rejected without a scan.
    def self.may_contain_tokens?(text : String, owns : Owns = Owns::All,
                                 prefix : String = Settings.env_prefix,
                                 syntax : Syntax = Settings.env_syntax) : Bool
      may_contain_tokens?(text.to_slice, owns, prefix, syntax)
    end

    def self.may_contain_tokens?(bytes : Bytes, owns : Owns = Owns::All,
                                 prefix : String = Settings.env_prefix,
                                 syntax : Syntax = Settings.env_syntax) : Bool
      return false if prefix.empty? || owns.none?
      return false unless contains_prefix?(bytes, prefix)
      return true if syntax.bare?
      pb = prefix.to_slice
      head = pb[0]
      plen = pb.size
      n = bytes.size
      i = 0
      # HOP sigil to sigil, never byte to byte. This runs on the send seam over whole request bodies,
      # and the namespaced walk was calling `prefix_at?` at every single byte of them — a per-byte
      # call whose first act is to compare that byte against the sigil, which is precisely what
      # `Slice#index` does in one memchr for the entire remainder.
      while (at = bytes.index(head, i))
        break if at + plen >= n
        if prefix_at?(bytes, prefix, at) && (ref = read_ref(bytes, at + plen, n))
          return true if owns.includes?(ref[0].owns)
        end
        # No separate `$$NS.` probe. An escape's own second sigil is a sigil, so this loop lands on
        # it and reads the `NS.NAME` behind it directly — the escape branch that used to sit here was
        # asking a question the next iteration answers, at a second `read_ref` per sigil.
        i = at + 1
      end
      false
    end

    # ── the send-time layer (session bindings, #501) ──────────────────────────
    #
    # `$NAME` has exactly ONE syntax and TWO resolution times, and the split is the
    # point of the feature. An env var is BUILD-time: every plan builder expands it
    # once before a run starts (#356), and a name that resolves to nothing is refused
    # there (#519/#525). A BINDING is SEND-time: its value is observed from a response
    # and may change between request 1 and request 20 of the same run, which is exactly
    # the run that otherwise produces a page of 401s.
    #
    # So the two layers are never merged for expansion. `expand`'s default stays
    # `effective_vars` — build-time and static — and the send pass below resolves the
    # binding half ALONE. That is what keeps #356's "one Env.expand, at plan-build"
    # invariant literally true: nothing re-expands an env var, and a var whose value
    # happens to contain a `$` cannot acquire a second meaning on the way to the socket.
    #
    # An abstract Layer rather than a direct reference to `Gori::Bindings` so `env.cr`
    # stays free of Store/Repeater/InterceptFilter — everything the binding table needs
    # and nothing this module should know about.
    abstract class Layer
      # Names an extract rule declares, whether or not one is bound yet.
      abstract def declared : Array(String)
      # Values available for RESOLUTION — what `$NAME` may expand to at send time.
      abstract def values : Hash(String, String)

      # Values for RESOLUTION as if the slot named were the ACTIVE one. Defaults to `values`,
      # which is the right answer for a layer with no slot registry: one table, and the name
      # cannot select a different one. `Bindings` overrides it with the global table under
      # that slot's own. See `Env.expand_bindings_as` for who asks and why.
      def slot_values(slot : String) : Hash(String, String)
        values
      end

      # Every value the layer is HOLDING, resolvable or not. Defaults to `values`; a layer
      # whose two answers differ must override it. `Bindings` does: it keeps a disabled
      # rule's token so re-enabling costs no round trip, while refusing to resolve it. See
      # `Env.masking_vars` — a secret that stopped resolving has not stopped being a secret.
      def held_values : Hash(String, String)
        values
      end

      # Names the ACTIVE session slot CLAIMS, whether or not an extract rule of that name exists.
      #
      # A claim is a declaration by another door: `--identities FILE` and MCP
      # `create_session_slot` both write a slot whose `rules` name bindings the project may not have
      # yet, and `Env.unbound_in_slot` has always counted such a name as a reference for exactly
      # that reason. It is here so a consumer that judges a SPELLING (`Rules#bare_spelling_at`) can
      # ask the same question the send seam does instead of a narrower one.
      #
      # Defaults to empty: a layer with no slot registry claims nothing.
      def active_slot_claims : Array(String)
        [] of String
      end

      # Bumped on every rule edit and every rebind, so a consumer can cache a merged
      # snapshot instead of rebuilding one per message (see `Rules`).
      abstract def rev : UInt64

      # The ACTIVE SESSION SLOT's header overlay, applied to final wire bytes. Defaults to
      # the identity function; `Bindings` overrides it with the project's slot registry.
      #
      # The second half of "a slot is the send context": the first half is `values`, which
      # already resolves `$NAME` out of the active slot's table. A layer answers both, because
      # they are one question — WHICH SESSION are these bytes going out as — and splitting
      # them across two globals is how the overlay and the bindings would come to disagree
      # about it.
      def overlay(wire : Bytes) : Bytes
        wire
      end

      # WHICH slot `overlay` and `values` are answering as, or nil for as-captured. A
      # READOUT seam and nothing else: a surface has to be able to print the send context
      # next to a send button without reaching through `Env.layer` and downcasting to
      # `Bindings` (which is how three surfaces would each acquire their own idea of it).
      # Defaults to nil, so a layer with no slot registry reads as as-captured.
      def active_slot_name : String?
        nil
      end
    end

    # The open project's binding table, or nil when none is open. Set by `Session.open`
    # and cleared on close — the same per-project-global lifetime `Settings.project_env_vars`
    # already has, and for the same reason: `$SESSION` must mean one thing in the Rewriter,
    # a Repeater tab, a Fuzzer template and `--target` alike. A constructor argument would
    # have guaranteed only that the four send seams remember it, while leaving every OTHER
    # surface free to forget — the opposite of the property the feature needs.
    @@layer : Layer? = nil

    def self.layer : Layer?
      @@layer
    end

    def self.layer=(l : Layer?) : Layer?
      @@layer = l
      bump_highlight_rev
      l
    end

    # Names declared by an extract rule. A declared name is NOT "unresolved" at plan-build
    # time — it resolves later, at send — so `unresolved` skips it by default and the send
    # seams pass `deferred: nil` to get it back.
    def self.declared_bindings : Array(String)
      @@layer.try(&.declared) || [] of String
    end

    # Bound values only. Never merged into `effective_vars`; see the note above.
    def self.binding_values : Hash(String, String)
      @@layer.try(&.values) || {} of String => String
    end

    # `binding_values` as if `slot` were active — see `expand_bindings_as`.
    def self.binding_values_as(slot : String) : Hash(String, String)
      @@layer.try(&.slot_values(slot)) || {} of String => String
    end

    def self.binding_rev : UInt64
      @@layer.try(&.rev) || 0_u64
    end

    # THE send-seam overlay: the active session slot's header set/remove, applied to wire
    # bytes that are already `$NAME`-resolved. Returns the same slice when no slot is active,
    # which is the default and the whole compatibility story — `as-captured` is the
    # no-overlay baseline, and a project that never selects a slot never sees a changed byte.
    #
    # Called AFTER `expand_bindings` at every seam that owns a request going onto the wire
    # (`Repeater::Sender`, `Fuzz::Sender`, the intercept forward). Order matters and is stated
    # here because it is the invariant three files depend on: the message's own `$NAME`
    # references resolve first, against the active slot's table, and the overlay is then
    # written over the result. A slot header value carrying its OWN `$NAME` is resolved by the
    # layer as it applies the overlay, so `Authorization: Bearer $SESSION` on the "admin" slot
    # means admin's `$SESSION` and nobody else's.
    #
    # HEADER-ONLY by construction (`SessionSlot.overlay_wire`), so the body is byte-exact and
    # Content-Length never moves. That is what makes it safe on bytes the operator did not
    # author — a captured replay, a fuzz template with its payload already spliced.
    def self.overlay_slot(wire : Bytes) : Bytes
      (l = @@layer) ? l.overlay(wire) : wire
    end

    # ── a slot overlay's own unresolved references ────────────────────────────
    #
    # A SLOT header value is the one place `$NAME` is guaranteed to be a reference and never
    # a payload. An operator writes `Authorization: Bearer $SESSION` on a slot in order to
    # send that slot's token; there is no GraphQL `$id`, no Mongo `$ne`, no JSON Schema
    # `$ref` in a header value an operator typed for that purpose. That is what makes this
    # answerable at all, and it is why the send seams' "leave an unknown token literal"
    # rule (#525, `unbound`'s doc above) is not weakened by saying something HERE.
    #
    # Because with an empty binding table `expand_bindings` passes `$SESSION` through as five
    # literal bytes, and the binding table is memory-only: EVERY `gori run … --slot` process
    # starts with an empty one, so every such run without `--bind-from` sends the literal.
    # Exit 0, no warning, HTTP 200 from the origin, and the operator reads it as a session
    # that worked. In Authorize it is worse than useless: the identity goes out
    # unauthenticated, draws the same 401 as anonymous, and the row aggregates to `enforced` —
    # a MISSED bypass, the one direction `Authorize::Identity`'s doc says this tool must not
    # fail in.
    #
    # A REPORT and not a refusal, deliberately. A guard with no exit costs more than the loss
    # it prevents (the #525 measurement: a probe scan losing 7 of 9 active checks on a flow,
    # reported as scanned), and an operator who genuinely wants the four bytes `$SES…` on the
    # wire already has the escape: `$$SESSION`, the one escape this module defines, which
    # `expand` consumes and this scan honours for the same reason.

    # One name a slot header will ship LITERALLY, and WHY — because the two causes have different
    # remedies and only one of them is fixable by binding.
    #
    # `bare_spelled` marks the second cause, and it is the worse one: a `$SESSION` under a
    # NAMESPACED install is not an unbound reference at all, it is text. Binding it changes
    # nothing, ever — `$BIND.SESSION` is the only spelling that resolves.
    record SlotLiteral, name : String, bare_spelled : Bool do
      # What the operator should write instead. For a bare spelling that is the RE-SPELLING; for a
      # genuinely unbound reference it is the escape, since the value is what they wanted.
      def remedy : String
        bare_spelled ? Env.spell(name, Namespace::Bind) : Env.spell_escaped(name, Namespace::Bind)
      end
    end

    # Every `$NAME` in `slot`'s own header VALUES that will land on the wire LITERALLY when
    # this slot is the send context, in first-appearance order.
    #
    # Only names the BINDING half owns are reported — a name some enabled extract rule
    # declares, or one this slot claims (a slot naming a rule that does not exist yet is the
    # same operator mistake, one step earlier). An unknown `$FOO` is plan-build's business,
    # exactly as `unbound` above states; two answers to one syntax is what #525 rules out.
    def self.unbound_in_slot(slot : SessionSlot) : Array(String)
      slot_literals(slot).map(&.name)
    end

    # The same scan, with the CAUSE kept.
    #
    # Under the namespaced grammar this also reads the header with the BARE grammar, and that half
    # is the missed bypass this report exists to prevent. A slot is written from two doors no
    # migration reaches — `gori run … --identities FILE` and MCP `create_session_slot` — so an
    # operator (or an agent) hands gori `Authorization: Bearer $SESSION` on a namespaced install,
    # those eight characters go out verbatim, the origin answers 401 exactly as it would for
    # anonymous, and `Authorize::Identity` aggregates the row as `enforced`. A missed bypass, which
    # is the one direction that tool's doc says it must not fail in.
    #
    # A BOUND name is reported in this half, deliberately, and that is the difference from the
    # namespaced half above: a bare `$SESSION` ships literally whether or not something bound
    # `SESSION`, because the namespaced reader never looks at it.
    def self.slot_literals(slot : SessionSlot) : Array(SlotLiteral)
      literal = [] of SlotLiteral
      return literal if slot.set_headers.empty?
      prefix = Settings.env_prefix
      return literal if prefix.empty?
      syntax = Settings.env_syntax
      # Nothing to scan and nothing to allocate for the overwhelmingly common slot: header
      # values an operator typed with no reference in them. This runs per SEND.
      #
      # The gate asks the BARE question in both grammars — "is there a sigil" — because a bare
      # `$SESSION` is exactly what the namespaced `$NS.` fast path would reject before anything
      # looked at it. It is still a memchr; the scan below is what the gate protects.
      return literal unless slot.set_headers.any? { |(_, v)|
                              may_contain_tokens?(v, Owns::Bind, prefix, Syntax::Bare)
                            }
      vals = binding_values_as(slot.name)
      declared = declared_bindings
      seen = Set(String).new
      slot.set_headers.each do |(_, value)|
        # BARE names in the BIND namespace: they are matched against `vals` and `declared`, both
        # keyed by bare name, and an `$ENV.X` in a slot header is the env layer's business.
        token_names(value, prefix, Namespace::Bind).each do |name|
          next if vals.has_key?(name)
          next unless declared.includes?(name) || slot.claims?(name)
          literal << SlotLiteral.new(name, false) if seen.add?(name)
        end
        next if syntax.bare?
        each_token(value.to_slice, prefix, Syntax::Bare) do |found|
          name = found.name
          next unless declared.includes?(name) || slot.claims?(name)
          literal << SlotLiteral.new(name, true) if seen.add?(name)
        end
      end
      literal
    end

    # Names an overlay shipped literally, since the last `take_unbound_overlay`. A surface
    # that prints a run summary drains this and says so; the log line below is for the ones
    # that do not (the live proxy path, a TUI send).
    @@unbound_overlay = [] of {String, String}
    @@unbound_overlay_seen = Set(String).new
    @@unbound_overlay_lock = Mutex.new

    # Called by every seam that applies a slot overlay, BEFORE it applies it. Returns the
    # names so a caller with a better place to put them can use them directly; records them
    # for `take_unbound_overlay` and logs each (slot, name) pair once.
    def self.report_unbound_overlay(slot : SessionSlot?) : Array(String)
      return [] of String unless slot
      found = slot_literals(slot)
      return [] of String if found.empty?
      fresh = [] of SlotLiteral
      @@unbound_overlay_lock.synchronize do
        found.each do |lit|
          next unless @@unbound_overlay_seen.add?("#{slot.name} #{lit.name}")
          @@unbound_overlay << {slot.name, lit.name}
          fresh << lit
        end
      end
      unless fresh.empty?
        # gori.log (#411). Once per (slot, name) until a surface drains the list: this runs
        # per SEND, and a Fuzzer sweep under a slot would otherwise write one line per request.
        ::Log.warn do
          names = fresh.map(&.name)
          # A BARE spelling under the namespaced grammar is a different sentence, because binding
          # is not the remedy for it: the reader never looks at those bytes.
          stale = fresh.select(&.bare_spelled)
          String.build do |io|
            io << "session slot #{slot.name.inspect} sends "
            io << "#{token_list(names, ns: Namespace::Bind)} LITERALLY — "
            if stale.size == fresh.size
              io << "#{stale.size == 1 ? "it is" : "they are"} spelled the BARE way and this "
              io << "install reads #{spell("KEY", Namespace::Env)}/#{spell("NAME", Namespace::Bind)}, "
              io << "so no binding will ever resolve #{stale.size == 1 ? "it" : "them"}. Write "
              io << "`#{stale[0].remedy}`"
            else
              io << "nothing has bound #{fresh.size == 1 ? "it" : "them"} in this process (a "
              io << "binding value is memory-only and every run starts with an empty table). "
              io << "Bind first (`--bind-from`, a Repeater send under this slot), or write "
              io << "`#{fresh[0].remedy}`"
              unless stale.empty?
                io << " — and `#{spell(stale[0].name, Namespace::Bind)}` for "
                io << "#{token_list(stale.map(&.name), ns: Namespace::Bind)}, which "
                io << "#{stale.size == 1 ? "is" : "are"} spelled the bare way this install no "
                io << "longer reads"
              end
            end
          end
        end
      end
      found.map(&.name)
    end

    # Drain the record — `{slot name, binding name}` pairs, in the order they were first seen.
    # For a surface that ends a run with a summary: unresolved references are the one thing an
    # exit-0 run must not stay quiet about, and a log line the operator is not tailing is not
    # a report. Draining resets the log throttle too, so a second run says it again.
    def self.take_unbound_overlay : Array({String, String})
      @@unbound_overlay_lock.synchronize do
        out = @@unbound_overlay.dup
        @@unbound_overlay.clear
        @@unbound_overlay_seen.clear
        out
      end
    end

    # Names the ACTIVE session slot claims — see `Layer#active_slot_claims`. Empty with no slot
    # active, which is the default and the as-captured context.
    def self.active_slot_claims : Array(String)
      @@layer.try(&.active_slot_claims) || [] of String
    end

    # The active session slot's NAME, or nil for as-captured (the default). What a surface
    # prints beside a send — the Repeater's `session:` chip, `gori run`'s send banner, MCP's
    # `active_slot` field — so all three name one answer rather than three.
    def self.active_slot_name : String?
      @@layer.try(&.active_slot_name)
    end

    # What a DISPLAY path should treat as known: build-time vars plus whatever is bound
    # right now. Widening the default of `mask_secrets` / `token_regions` to this is what
    # makes every surface that already masks (or paints a `$KEY`) cover bindings too,
    # with no per-surface change. Deliberately NOT the default of `expand`.
    #
    # A DISPLAY table, and under the NAMESPACED grammar not a resolution table at all: the two
    # layers are keyed by bare name and merging them is exactly the collision the namespaces
    # remove, so anything that RESOLVES asks `vars_for(ns)` instead. This stays because "would
    # this token paint as known?" and "which names may completion offer?" are still one question
    # about both layers at once.
    def self.display_vars : Hash(String, String)
      h = effective_vars
      binding_values.each { |(k, v)| h[k] = v }
      h
    end

    # What a MASKING surface must treat as secret: build-time vars plus every value the
    # binding layer is holding, INCLUDING one whose rule is currently disabled.
    #
    # Deliberately wider than `display_vars`, and the two must not be merged. `display_vars`
    # answers "what will resolve", which is what `token_regions` paints and what completion
    # offers — a disabled name is not resolvable and must not paint as bound. Masking asks a
    # different question: those bytes were observed from a real response and are sitting in
    # memory, so a redaction that stopped the moment the operator toggled a rule off would
    # print the token into an export, a note or the detail view.
    def self.masking_vars : Hash(String, String)
      h = effective_vars
      (@@layer.try(&.held_values) || {} of String => String).each { |(k, v)| h[k] = v }
      h
    end

    # Substitute BOUND binding values in final wire bytes, at send time. Returns the same
    # slice when there is nothing to do — the common case, and byte-fidelity (P7) besides.
    #
    # Scans the whole message, head and body: injecting a token into a body is a designed
    # case (a `Replace` rule with `part: Body`, an operator's Repeater template). That is
    # safe in a way a head-only rule was not, because this matches a SPECIFIC declared name
    # rather than the `$`+`[A-Za-z_]` shape — and in any case nothing here refuses: a name
    # that does not resolve simply stays literal.
    # A value carrying CR/LF/NUL is withheld from the HEAD half and substituted freely in the
    # BODY. A binding value is the ORIGIN'S — see `Bindings.boundary_forging?` — and in a head
    # `abc\r\nX-Admin: true` becomes two header lines while `abc\r\n\r\nGET /...` forges a whole
    # second request onto a pooled keep-alive upstream. In a body it forges nothing, and the
    # sentence above is the designed case, so the split is by POSITION rather than by value.
    # A name whose value is withheld stays LITERAL, `Env.expand`'s documented contract for an
    # unknown key — visible in the request rather than silently dropped.
    #
    # `verbatim` names byte ranges of `bytes` that this pass must copy through with no scan
    # at all. The doc above justifies scanning the WHOLE message by naming the cases that
    # want it — a `Replace` rule with `part: Body`, an operator's Repeater template — and a
    # FUZZ PAYLOAD is not one of them: the operator authored `$TOKEN` as the thing under
    # test, and substituting the live session token there both sends a request nobody wrote
    # and puts a real credential in an arbitrary position of it, where it lands in the
    # target's access log. `Fuzz::Generator#emit` already computes each payload's span in
    # order to splice it, so the template resolves and the payload does not.
    def self.expand_bindings(bytes : Bytes, verbatim : Array({Int32, Int32})? = nil) : Bytes
      prefix = Settings.env_prefix
      # `may_contain_tokens?`, not just "is there a `$`": under the namespaced syntax a body full
      # of `$id` / `$ne` carries nothing this pass owns, and saying so costs one scan instead of
      # a full expansion of head and body.
      return bytes if prefix.empty? || !may_contain_tokens?(bytes, Owns::Bind, prefix)
      vals = binding_values
      # With nothing to resolve this pass would be a no-op — except that it is also the seam
      # that CONSUMES its own escape (see `Escape`/`Owns`), and a project with no extract rule is
      # exactly where an operator escaping a GraphQL `$id` is likeliest to be.
      return bytes if vals.empty? && !contains_escape?(bytes, prefix, owns: Owns::Bind)
      safe = boundary_safe(vals)
      boundary = head_body_boundary(bytes)
      head = expand(String.new(bytes[0...boundary]), safe, prefix,
        clip_spans(verbatim, 0, boundary), Escape::Consume,
        resolve: Owns::Bind, bind_vars: safe).to_slice
      return head if boundary >= bytes.size
      raw_body = bytes[boundary..]
      body = expand(String.new(raw_body), vals, prefix,
        clip_spans(verbatim, boundary, bytes.size), Escape::Consume,
        resolve: Owns::Bind, bind_vars: vals).to_slice
      unless body.size == raw_body.size
        shifted = shift_content_length(head, body.size - raw_body.size)
        warn_unshiftable_framing if shifted.same?(head)
        head = shifted
      end
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      buf.to_slice
    end

    # `head` with its `Content-Length` moved by `delta`, every other byte untouched. No-op
    # when the head declares none.
    #
    # ## Why this lives here and why it is a DELTA
    #
    # Binding values resolve at SEND time, which is after every plan builder has framed the
    # request — `Repeater::Plan` runs `resync_content_length`, `Fuzz::Generator#emit` runs
    # `ContentLength.sync`, both over bytes that still hold the literal `$NAME`. Nothing
    # re-framed afterwards, so a `$NAME` in a BODY shipped a Content-Length describing the
    # UNEXPANDED body: on a pipelined send-group the origin read the declared prefix and the
    # remainder became the front of the next request line — gori desyncing its own connection
    # and putting the session token on the wire as a method. A value shorter than the token
    # hangs the connection instead. On h2 a `content-length` disagreeing with the DATA frames
    # is malformed outright (RFC 9113 §8.1.2.6).
    #
    # A DELTA and not a resync, because both framing modes have to survive: an operator with
    # auto-Content-Length OFF (`Repeater`) or `update_content_length` off (`Fuzz`) authored a
    # deliberate mismatch as their payload, and a resync would silently destroy it. Shifting
    # by what the substitution actually added keeps that offset exactly, while a request that
    # WAS in sync stays in sync. It is also why this sits inside `expand_bindings` rather than
    # at the five send seams: the seam that forgets is the one that desyncs.
    # Only the DIGITS move. The field name's spelling, the colon and the optional whitespace
    # on either side are copied through byte-exact, because on this codebase's requests they
    # are the payload: `content-length:   2` with lower-case and extra OWS IS a
    # header-parsing-discrepancy probe, and canonicalising it to `Content-Length: 2` silently
    # sends a different test than the operator wrote.
    #
    # And with MORE THAN ONE Content-Length the shift is refused outright. A CL.CL request is
    # a desync probe whose whole content is the RELATIONSHIP between the two numbers; moving
    # one of them turns the operator's `2/99` into `10/99`, and there is no reading of "which
    # one did they mean" that is not a guess. Refusing leaves their bytes alone — the request
    # still goes out exactly as authored.
    private def self.shift_content_length(head : Bytes, delta : Int32) : Bytes
      span = content_length_digits(head)
      return head unless span
      start, stop = span
      current = String.new(head[start, stop - start]).to_i64?
      return head unless current
      # SATURATING, in Int128, because `current` is an operator-authored number: `to_i64?`
      # refuses a literal wider than 64 bits but returns `Int64::MAX` / `Int64::MIN` happily,
      # and Crystal's checked `+` then raised OverflowError out of the send — on `gori run
      # repeater` that is a raw backtrace, since `CLI.dispatch` rescues only `Gori::Error`.
      # `Content-Length: 9223372036854775807` and its negative twin ARE probes, so raising on
      # them is the one outcome this method's contract rules out (everything it cannot shift,
      # it leaves byte-exact). The lower bound is the `{…, 0_i64}.max` this replaces; delta is
      # an Int32, so the Int128 sum cannot itself overflow.
      shifted = (current.to_i128 + delta).clamp(0_i128, Int64::MAX.to_i128).to_i64.to_s
      buf = IO::Memory.new(head.size + shifted.bytesize)
      buf.write(head[0, start])
      buf << shifted
      buf.write(head[stop, head.size - stop])
      buf.to_slice
    end

    # The byte range of the Content-Length VALUE's digits, or nil when this head must not be
    # touched. Everything outside that range is copied verbatim, which is the whole point:
    # header casing, the space after the colon and a leading zero are live smuggling and
    # WAF-bypass variables on the send path, and this runs unconditionally with no
    # auto-Content-Length opt-out. `Fuzz::ContentLength.sync` is the same discipline.
    #
    # nil — leave the head exactly as authored — for each of:
    #
    #   * a `Transfer-Encoding` anywhere in the head. The framing is the chunk-size lines
    #     inside the BODY, and gori cannot re-chunk without rewriting the operator's framing
    #     payload. `ContentLength.sync` returns unchanged for chunked too. The caller warns,
    #     because a `$NAME` in a chunked body still desyncs and silence would be worse.
    #   * more than one Content-Length. A CL.CL request is a desync probe whose content IS the
    #     relationship between the two numbers; there is no "which one did they mean" that is
    #     not a guess.
    #   * a line starting with SP or HTAB — an obs-fold continuation. ` Content-Length: 2`
    #     folded under `X-Note:` is part of THAT header's value and invisible to a strict
    #     parser, which is exactly what an obfuscated-framing probe is built on.
    #
    # Line splitting is on LF with an optional preceding CR, per line, so a deliberately
    # MIXED-EOL head is handled rather than silently skipped.
    private def self.content_length_digits(head : Bytes) : {Int32, Int32}?
      found = nil.as({Int32, Int32}?)
      pos = 0
      first = true
      while pos < head.size
        lf = head.index(0x0a_u8, pos)
        stop = lf || head.size
        line_end = (stop > pos && head[stop - 1] == 0x0d_u8) ? stop - 1 : stop
        unless first || fold_or_blank?(head, pos, line_end)
          case header_name(head, pos, line_end)
          when "transfer-encoding" then return nil
          when "content-length"
            return nil if found # a second one: refuse, see above
            found = value_digits(head, pos, line_end)
          end
        end
        first = false
        break unless lf
        pos = lf + 1
      end
      found
    end

    # An obs-fold continuation (SP/HTAB first) or an empty line — neither is a header of its
    # own, and treating a fold as one is how a `Content-Length` hidden inside another header's
    # value gets edited.
    private def self.fold_or_blank?(head : Bytes, pos : Int32, line_end : Int32) : Bool
      pos >= line_end || head[pos] == 0x20_u8 || head[pos] == 0x09_u8
    end

    private def self.header_name(head : Bytes, pos : Int32, line_end : Int32) : String?
      colon = index_in(head, 0x3a_u8, pos, line_end)
      colon ? String.new(head[pos, colon - pos]).strip.downcase : nil
    end

    # The value's digit span with the OWS on both sides excluded, or nil when the value is
    # empty. The colon is re-found rather than threaded so `header_name` stays a pure lookup.
    private def self.value_digits(head : Bytes, pos : Int32, line_end : Int32) : {Int32, Int32}?
      colon = index_in(head, 0x3a_u8, pos, line_end)
      return nil unless colon
      vs = colon + 1
      while vs < line_end && (head[vs] == 0x20_u8 || head[vs] == 0x09_u8)
        vs += 1
      end
      ve = line_end
      while ve > vs && (head[ve - 1] == 0x20_u8 || head[ve - 1] == 0x09_u8)
        ve -= 1
      end
      ve > vs ? {vs, ve} : nil
    end

    @@warned_unshiftable = false

    # A binding substitution changed the body's length and the head's framing could not follow
    # — chunked, a CL.CL pair, an obs-folded Content-Length, or no Content-Length at all. The
    # message goes out as authored, which for a chunked body means the chunk-size lines now
    # disagree with the chunk: the same desync the Content-Length shift exists to prevent,
    # surviving in the other framing mode. gori will not re-chunk (that would rewrite the
    # framing the operator authored), so the honest answer is to say so. Once per process:
    # this is a send loop.
    private def self.warn_unshiftable_framing : Nil
      return if @@warned_unshiftable
      @@warned_unshiftable = true
      ::Log.warn do
        "a session binding changed a request body's length, but its head's framing could not " \
        "be adjusted (chunked, more than one Content-Length, an obs-folded one, or none). The " \
        "request goes out exactly as authored, so its declared framing may now disagree with " \
        "the body — bind the value into a header, or size the body yourself"
      end
    end

    private def self.index_in(bytes : Bytes, byte : UInt8, from : Int32, to : Int32) : Int32?
      i = from
      while i < to
        return i if bytes[i] == byte
        i += 1
      end
      nil
    end

    # The String form has no head/body split to take, so the caller says whether what it holds
    # is boundary-sensitive. A `--target` or an SNI lands on the request line or in a header
    # and is (`guard_boundary: true`, the default); a WebSocket frame is ALL payload — there is
    # no head in it for a CR/LF to forge a line into, and the proxy's own WS path agrees
    # (`Rules#head_scoped?` maps `part: Ws` to false). Withholding there would kill exactly the
    # multi-line values this feature allows: a PEM block, a SAML assertion, a formatted JSON
    # sub-document.
    def self.expand_bindings(text : String, guard_boundary : Bool = true) : String
      prefix = Settings.env_prefix
      return text if prefix.empty? || !may_contain_tokens?(text, Owns::Bind, prefix)
      expand_binding_text(text, binding_values, prefix, guard_boundary)
    end

    # `expand_bindings` resolved as if the slot NAMED were the active one, for the caller that
    # sends several identities in one run and cannot activate each in turn.
    #
    # `activate` is process-global and every other tab's send seam reads it, so walking it
    # across a set would race whatever else is in flight — the same argument that gave
    # `Fuzz::Sender` its `slot_overlay: false`. `Authorize` is the caller: it applies each
    # identity's overlay ITSELF, and an identity's `Authorization: Bearer $SESSION` has to mean
    # THAT identity's `$SESSION`. Resolving it against `binding_values` would hand every
    # identity in the run the active slot's token — one credential wearing several names, which
    # is the fabricated `⚠ same` on every row that `slot_overlay: false` already exists to
    # prevent; leaving it unresolved ships the literal `$SESSION` and the identity goes out
    # unauthenticated, which reads as `enforced` — a MISSED bypass, the direction this tool
    # must not fail in.
    #
    # An unregistered name (an `--identities` file, the baseline gori prepends) resolves out of
    # the global table alone. That is the honest answer: an identity with no slot has no private
    # table, and it is what a project with no slots at all has always done.
    def self.expand_bindings_as(text : String, slot : String, guard_boundary : Bool = true) : String
      prefix = Settings.env_prefix
      return text if prefix.empty? || !may_contain_tokens?(text, Owns::Bind, prefix)
      expand_binding_text(text, binding_values_as(slot), prefix, guard_boundary)
    end

    private def self.expand_binding_text(text : String, vals : Hash(String, String),
                                         prefix : String, guard_boundary : Bool) : String
      # see the Bytes form
      return text if vals.empty? && !contains_escape?(text.to_slice, prefix, owns: Owns::Bind)
      table = guard_boundary ? boundary_safe(vals) : vals
      expand(text, table, prefix, escape: Escape::Consume, resolve: Owns::Bind, bind_vars: table)
    end

    # A WebSocket FRAME payload. All body, and that is the whole of why it needs its own door
    # rather than a flag on either overload above:
    #
    #   * no HEAD/BODY split — there is no head, so `head_body_boundary` on a frame either finds
    #     a CRLFCRLF the payload happens to contain (splitting a JSON document in half) or finds
    #     none and calls the WHOLE frame a head, which then withholds every CR/LF-carrying value.
    #   * no CONTENT-LENGTH delta — a frame declares its length in its own header, which
    #     `WS.encode` writes AFTER this pass, so there is nothing here to re-sync.
    #   * no BOUNDARY-FORGING withholding — there are no header lines for a CR/LF to forge one
    #     into, which is the reason `Repeater::Sender#expand_messages` reaches for the String
    #     overload with `guard_boundary: false` today, and why a PEM block or a formatted JSON
    #     sub-document must survive as a binding value here.
    #
    # `verbatim` is what that path has never had, and it is the point of this method: the FUZZ
    # PAYLOAD's own span inside the frame. `--payloads '$TOKEN'` aimed at a WebSocket app is the
    # operator's test case — SSTI, env reflection, a GraphQL `$id` — and substituting the live
    # session credential there both sends a frame nobody wrote and puts a real credential on the
    # wire. The Bytes overload's own comment makes this argument for the HTTP half; a frame is
    # where it had no implementation.
    def self.expand_bindings_frame(payload : Bytes,
                                   verbatim : Array({Int32, Int32})? = nil) : Bytes
      prefix = Settings.env_prefix
      return payload if prefix.empty? || !may_contain_tokens?(payload, Owns::Bind, prefix)
      vals = binding_values
      # See the Bytes overload: this is also the seam that CONSUMES its own escape, so an empty
      # table is not on its own a reason to skip.
      return payload if vals.empty? && !contains_escape?(payload, prefix, owns: Owns::Bind)
      expand(String.new(payload), vals, prefix, verbatim, Escape::Consume,
        resolve: Owns::Bind, bind_vars: vals).to_slice
    end

    # `spans` restricted to `[from, to)` and rebased so 0 is `from` — what a half of a
    # head/body split needs when the caller's offsets are into the whole message. Returns
    # nil (not an empty Array) when nothing survives, so the scans below keep their
    # allocation-free fast path on the overwhelmingly common "no verbatim regions" call.
    # Spans arrive sorted and disjoint (`Fuzz::Generator` emits them in splice order) and
    # come out that way, which is what lets the scanners walk them with one cursor.
    private def self.clip_spans(spans : Array({Int32, Int32})?, from : Int32,
                                to : Int32) : Array({Int32, Int32})?
      return nil if spans.nil? || spans.empty?
      out = [] of {Int32, Int32}
      spans.each do |(a, b)|
        s = a > from ? a : from
        e = b < to ? b : to
        out << {s - from, e - from} if e > s
      end
      out.empty? ? nil : out
    end

    # `vals` minus every value that would forge a message boundary where it is injected.
    # Returns the SAME Hash when nothing is withheld, which is the common case.
    private def self.boundary_safe(vals : Hash(String, String)) : Hash(String, String)
      return vals unless vals.any? { |(_, v)| Bindings.boundary_forging?(v) }
      vals.reject { |_, v| Bindings.boundary_forging?(v) }
    end

    # Declared binding names in `bytes` that have no value yet, first-appearance order.
    #
    # A REPORT, never a gate. `$NAME` without a value is a literal string on the wire — the
    # same answer `expand` has always given an unknown key, now given to a DECLARED-but-unbound
    # name too. The send seams used to refuse here (#491/#525's shape) and no longer do: the
    # token grammar collides structurally with GraphQL `$id`, Mongo `$ne` and JSON Schema
    # `$ref`, so a name an operator declared for one request silently killed every OTHER
    # request whose captured body happened to contain it — a probe scan losing 7 of 9 active
    # checks on a flow, reported as scanned. An operator who wants a value on the wire binds
    # it; an operator who wrote `$ne` gets `$ne`, and `$$ne` if they need the escape.
    #
    # The one remaining caller is `Rules#report_refused`, which explains a rewrite rule that
    # did not apply — a rule-scoped SKIP that blocks no traffic, not a send refusal.
    #
    # `verbatim` is `expand_bindings`' argument and has to be the SAME list, so the two agree
    # about which bytes are the operator's payload rather than a reference.
    def self.unbound(bytes : Bytes, verbatim : Array({Int32, Int32})? = nil) : Array(String)
      unbound(String.new(bytes), verbatim)
    end

    def self.unbound(text : String, verbatim : Array({Int32, Int32})? = nil) : Array(String)
      declared = declared_bindings
      return [] of String if declared.empty?
      prefix = Settings.env_prefix
      return [] of String if prefix.empty? || !may_contain_tokens?(text, Owns::Bind, prefix)
      vals = binding_values
      # `deferred: nil` — the whole point here is to REPORT a declared name, and only a
      # declared one: an unknown `$FOO` is plan-build's business (#525) and reporting it
      # again from a send seam would be the second behaviour for one syntax the design
      # rules out.
      #
      # BARE names (`owns: Bind`, unqualified): the answer indexes the declared-name list and the
      # binding table, both of which are keyed by bare name. The callers that PRINT it spell it
      # with `token_list(…, ns: Bind)`.
      #
      # `bind_resolvable: true` is this method's own question, and it is the OPPOSITE of
      # `unresolved(deferred: nil)`'s: here the binding table is exactly the right judge ("this
      # name is declared and still has no value"), because this scan runs ON the send seam that
      # resolves BIND. One scanner, two callers, so the reading is passed rather than inferred.
      names = scan_unresolved(text.to_slice, vals, prefix, nil, verbatim,
        owns: Owns::Bind, qualify_names: false, bind_vars: vals, bind_resolvable: true)
      names.select { |n| declared.includes?(n) }
    end

    # Anchored on `Slice#index`, which is `memchr` for a `UInt8` slice — NOT a byte loop.
    #
    # This is the FIRST thing `may_contain_tokens?` asks, on every request and response body on
    # every send path, and the loop it replaces ran `pb.each_with_index.all?` at every offset: an
    # iterator pair allocated per byte of the body, to answer "is there a `$` in here". Bare mode
    # on main asked `String#byte_index`, which is memchr; the byte-level rewrite lost that.
    #
    # The prefix is one byte on every install that has not changed it, so the single-byte case is
    # the whole answer and gets no compare at all.
    private def self.contains_prefix?(bytes : Bytes, prefix : String) : Bool
      pb = prefix.to_slice
      return false if pb.empty? || pb.size > bytes.size
      head = pb[0]
      return !bytes.index(head).nil? if pb.size == 1
      last = bytes.size - pb.size
      i = 0
      while i <= last
        at = bytes.index(head, i)
        return false unless at && at <= last
        return true if bytes[at, pb.size] == pb
        i = at + 1
      end
      false
    end

    # Expand env tokens in wire-form HTTP text (LF or CRLF) and return CRLF bytes.
    # Normalizes newlines with a byte-level scan (`normalize_crlf`) — NOT
    # `gsub(/\r?\n/, "\r\n")` and NOT `split('\n').join("\r\n")` — for two reasons:
    # the gsub-vs-split/join distinction avoids doubling already-CRLF input
    # (captured flow bytes) into `\r\r\n`, which would destroy the head/body
    # separator and break framing on every CLI/MCP repeater+mine send path; and a
    # `Regex` (gsub) *requires* valid UTF-8 and raises `ArgumentError` on a subject
    # string that isn't — which a captured flow's binary body routinely isn't. See
    # `expand` below for why the text reaching this point may carry invalid UTF-8.
    #
    # CRLF normalization is HEAD-ONLY: a raw `0x0A` inside the BODY is just a byte
    # (binary/compressed data, or a bare LF a client legitimately sent) — not a line
    # ending — and must never be rewritten to `0x0D 0x0A`. Only HTTP header lines
    # require CRLF termination on the wire; the editors that feed this (Repeater,
    # Miner) store the whole head+body blob as one LF-joined buffer, so naively
    # normalizing the entire buffer corrupted every bare-LF byte in the body
    # (silently, since Content-Length gets resynced to the corrupted body
    # afterward). `head_body_boundary` locates the blank-line separator first;
    # only the head (through and including that separator) is normalized, and the
    # body is copied through byte-for-byte untouched.
    #
    # `escape` defaults to `Preserve`: this is the plan-build pass and `expand_bindings` runs
    # over the same bytes at the send seam. A surface where THIS is the last pass before the
    # socket (the TUI intercept editor) passes `Escape::Consume`.
    #
    # `unescape` is the namespaced spelling of that decision — `Owns::All` for the surface where
    # this IS the last pass, since under the namespaced grammar there are two escapes to consume
    # (`$$ENV.X` and `$$BIND.X`) and one flag cannot name them both.
    def self.expand_wire(text : String, vars : Hash(String, String) = effective_vars,
                         prefix : String = Settings.env_prefix,
                         escape : Escape = Escape::Preserve, *,
                         syntax : Syntax = Settings.env_syntax,
                         resolve : Owns = Owns::Env,
                         unescape : Owns? = nil) : Bytes
      bytes = expand(text, vars, prefix, escape: escape,
        syntax: syntax, resolve: resolve, unescape: unescape).to_slice
      boundary = head_body_boundary(bytes)
      head = normalize_crlf(bytes[0...boundary])
      return head if boundary >= bytes.size

      body = bytes[boundary..]
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      buf.to_slice
    end

    # `expand_wire` MINUS the expansion: the head's bare LFs promoted to CRLF, every body
    # byte copied through untouched.
    #
    # `expand_wire` is two passes welded together and EVIDENCE wants exactly one of them.
    # Substituting a project value into a captured `$filter` / `$where` sends a request
    # nobody captured (`Repeater::PlanOptions#evidence?` argues this at length); promoting a
    # bare LF in the head is different — the TUI editors hold a request as an LF-joined line
    # buffer and `TextArea#insert_newline` names `expand_wire` as what promotes a typed
    # line's terminator back, so an evidence path that skipped it would put a bare-LF header
    # terminator — itself a front-end/back-end desync primitive — on the wire.
    #
    # Public and here rather than re-derived per surface: `FuzzerView#evidence_template`
    # already spells this out by hand, and a fourth copy is how two surfaces come to
    # disagree about the bytes they send for one flow.
    def self.normalize_wire(text : String) : Bytes
      bytes = text.to_slice
      boundary = head_body_boundary(bytes)
      head = normalize_crlf(bytes[0...boundary])
      return head if boundary >= bytes.size
      body = bytes[boundary..]
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      buf.to_slice
    end

    # Substitute registered `prefix+KEY` tokens; unknown keys stay literal.
    #
    # Operates on raw bytes, not `String#chars`. `prefix` and KEY names are always
    # ASCII (`KEY_HEAD`/`KEY_TAIL`), so a token can be found/replaced by scanning
    # bytes alone — never decoding to codepoints. That matters because the text
    # here can be a captured flow's body loaded verbatim into the Repeater editor,
    # which may contain byte sequences that are not valid UTF-8 (a raw binary
    # body). `String#chars` (the previous implementation) decodes lossily: any
    # invalid sequence is silently replaced by U+FFFD, corrupting the wire bytes
    # on every send — even when the text has no `$KEY` token at all. Scanning
    # bytes instead means every span that isn't part of a matched token — valid
    # UTF-8 or not — is copied through byte-for-byte, unchanged.
    #
    # `verbatim` byte ranges are copied through with no token scan at all. Not the same
    # thing as "no variable happened to match there": the ranges are bytes whose PROVENANCE
    # differs from the rest of the message (today, a fuzz payload spliced into a template),
    # so a `$NAME` inside one is the operator's test case rather than a reference. nil — the
    # overwhelmingly common call — keeps the loop exactly as it was.
    #
    # `escape` says what `$$` means here — see `Escape`. The default is `Preserve` because
    # this method IS the env-var layer, and the binding layer scans the same bytes afterwards.
    # `resolve` names the pass: which namespace's tokens this call may substitute. The default
    # is `Owns::Env`, so `expand` IS the env-var layer and a `$BIND.NAME` survives it byte-exact
    # for the send seam to resolve. `bind_vars` is the BIND table for the namespaced grammar
    # (`vars` stays the ENV one); the bare grammar has a single table and `vars` is it, which is
    # why `expand_bindings` passes its values in BOTH places.
    #
    # `unescape` says which escapes THIS call consumes, overriding the `escape` enum — the
    # namespaced spelling of the same decision. See `unescape_set`.
    def self.expand(text : String, vars : Hash(String, String) = effective_vars,
                    prefix : String = Settings.env_prefix,
                    verbatim : Array({Int32, Int32})? = nil,
                    escape : Escape = Escape::Preserve, *,
                    syntax : Syntax = Settings.env_syntax,
                    resolve : Owns = Owns::Env,
                    unescape : Owns? = nil,
                    bind_vars : Hash(String, String)? = nil) : String
      return text if prefix.empty?
      return text unless text.byte_index(prefix) # fast, lossless no-op when the prefix never occurs

      bytes = text.to_slice
      n = bytes.size
      plen = prefix.bytesize
      escapes = unescape_set(syntax, escape, resolve, unescape)
      buf = IO::Memory.new(n)
      i = 0
      vi = 0 # cursor into `verbatim`; sorted + disjoint, so one pass suffices
      while i < n
        if verbatim
          while vi < verbatim.size && verbatim[vi][1] <= i
            vi += 1
          end
          if vi < verbatim.size && verbatim[vi][0] <= i
            stop = verbatim[vi][1]
            stop = n if stop > n
            buf.write(bytes[i, stop - i])
            i = stop
            next
          end
        end
        # The sigil test stays INLINE here rather than being left to the reader: this loop runs
        # per BYTE of every request body on every send path, and a call per byte is not the same
        # cost as a call per `$`.
        unless prefix_at?(bytes, prefix, i)
          buf.write_byte(bytes[i])
          i += 1
          next
        end
        # A verbatim span starting ahead of `i` caps how far a token opened here may read: its
        # NAME (and the second `$` of an escape) must stop at the span, never reach INTO it.
        # Without the cap a `$NAME` whose `$` sits just before a fuzz payload consumed and
        # substituted the payload's leading bytes — the exact splice `verbatim` exists to
        # prevent (a live credential spliced into the payload under test). vi already points
        # past every span ending at/behind `i`, and we are NOT inside one (that branch ran
        # above), so `verbatim[vi]` is the next span ahead. No verbatim → `limit == n`, the
        # unchanged common path.
        limit = (verbatim && vi < verbatim.size) ? verbatim[vi][0] : n
        found = read_token_at(bytes, i, limit, syntax: syntax, prefix: prefix, escapes: escapes)
        unless found
          buf.write_byte(bytes[i])
          i += 1
          next
        end
        if found.kind.escape?
          # One sigil survives, and the token behind it is never resolved — which is what makes
          # the escape mean the same thing whether or not the name after it would resolve.
          buf << prefix
          buf << found.escaped_text
        elsif found.kind.token? && found.owned_by?(resolve) &&
              (val = table_for(found.ns, vars, bind_vars)[found.name]?)
          buf << val
        else
          # A Literal, a token this pass does not own, or an owned token with no value — all
          # three are "copy what is there". An unknown name staying LITERAL is `expand`'s
          # documented contract (#525); a token belonging to the OTHER pass must survive
          # byte-exact so that pass can still see it.
          w = found.kind.token? && found.owned_by?(resolve) ? found.miss_width(plen, syntax) : found.width
          buf.write(bytes[i, w])
          i += w
          next
        end
        i += found.width
      end
      String.new(buf.to_slice)
    end

    # "A pass owns its escapes." In NAMESPACED mode that is literal — the escape carries the
    # namespace, so the pass that resolves `$BIND.X` is the pass that consumes `$$BIND.X`, and
    # `Escape` has nothing to decide. In BARE mode the escape is anonymous, so the enum still
    # answers: `Consume` (the last pass before the socket) unescapes everything, `Preserve` (the
    # env-var layer, which is re-scanned by the send seam) nothing.
    private def self.unescape_set(syntax : Syntax, escape : Escape, resolve : Owns,
                                  given : Owns?) : Owns
      return given if given
      syntax.bare? ? (escape.consume? ? Owns::All : Owns::None) : resolve
    end

    # The table a token resolves from. BARE has one table and `vars` is it.
    #
    # Exhaustive over the namespace set, not `ns.bind? ? bind : env`: a two-way branch answers for a
    # THIRD namespace by routing it to the env vars, silently, and "silently resolves out of the
    # wrong table" is the one failure the namespaces exist to remove.
    private def self.table_for(ns : Namespace?, vars : Hash(String, String),
                               bind_vars : Hash(String, String)?) : Hash(String, String)
      return vars unless ns
      case ns
      in Namespace::Env  then vars
      in Namespace::Bind then bind_vars || binding_values
      end
    end

    # Whether `bytes` holds an escape one of `owns`' passes would CONSUME. Only asked on the send
    # seam's "there are no bindings" fast path: with nothing to resolve the pass would be a
    # no-op, EXCEPT that the send seam is also the one that consumes the escape, and skipping it
    # there would ship `$$id` (bare) / `$$BIND.X` (namespaced) to the origin.
    private def self.contains_escape?(bytes : Bytes, prefix : String, *,
                                      owns : Owns = Owns::All,
                                      syntax : Syntax = Settings.env_syntax) : Bool
      pb = prefix.to_slice
      return false if pb.empty? || owns.none?
      plen = pb.size
      head = pb[0]
      n = bytes.size
      last = n - 2 * plen
      i = 0
      # Sigil-hopping for the same reason as `may_contain_tokens?` above: this is the send seam's
      # "there are no bindings" fast path, so it walks bodies that almost never hold a `$` at all,
      # and the per-byte `prefix_at?` was re-deriving the memchr `Slice#index` gives for free.
      while (at = bytes.index(head, i))
        break if at > last
        if prefix_at?(bytes, prefix, at) && prefix_at?(bytes, prefix, at + plen)
          return true if syntax.bare?
          if ref = read_ref(bytes, at + 2 * plen, n)
            return true if owns.includes?(ref[0].owns)
          end
        end
        i = at + 1
      end
      false
    end

    # The KEYs in `text` that `expand` would NOT substitute — every `prefix+KEY`
    # whose KEY is unregistered — in first-appearance order, deduplicated. Empty
    # means every token resolved.
    #
    # This is a QUERY, never a mutation of `expand`'s contract: leaving an unknown
    # token literal is correct on a display path (it is honest about what could not
    # be resolved, and `token_regions` already paints it), and wrong on a path that
    # then puts those bytes on a socket. So the send paths ask this first and refuse,
    # and `expand` keeps its meaning for everyone else (issue #519).
    #
    # Shares `read_key_bytes` and mirrors `expand`'s scan positions exactly —
    # INCLUDING the `i += plen` advance on a miss — rather than re-deriving the token
    # grammar. That is what makes the answer trustworthy: a name reported here is a
    # name `expand` tried to resolve at that same offset and could not, so it is a
    # name that lands on the wire literally.
    #
    # NOT `token_regions`, which computes the same `known` fact: that one is
    # char-based (`text.chars`), and the text this runs over is routinely not valid
    # UTF-8 (a captured flow's body loaded verbatim). `String#chars` decodes lossily
    # to U+FFFD, which can both invent and destroy a token boundary — the exact
    # hazard `expand` was made byte-level to avoid.
    #
    # `deferred` names are skipped: a name an extract rule declares is not unresolved, it
    # is resolved LATER (see `unbound`). Without that, `$SESSION` in a Fuzzer template
    # would be refused at plan-build — leaving one syntax with two contradictory rules,
    # which is the thing #525's shape exists to prevent.
    #
    # `deferred: nil` is the DIAL-TUPLE reading and it says something stronger than "report the
    # declared names too": it says nothing in this text is deferred to a later pass at all. The
    # callers passing it are a target, an SNI and a URL — bytes that go to the scope gate and to
    # DNS, and that the paired `Env.expand` resolves with `resolve: Owns::Env` alone, never a
    # binding. So under the namespaced grammar a `$BIND.X` is reported HERE whether or not it is
    # bound: it resolves in no pass this text ever sees, and judging it against the live binding
    # table said "resolved" about a host that then reached the resolver spelled `$BIND.HOST`.
    # With `deferred` GIVEN (the request-body callers, whose bytes the send seam re-scans with
    # `resolve: Owns::Bind`) a bound BIND name is genuinely resolved and stays unreported.
    #
    # Names come back QUALIFIED under the namespaced syntax (`"ENV.HOST"`, `"BIND.SESSION"`) —
    # a name that does not resolve in one namespace may well resolve in the other, so a bare
    # name here would be a refusal that names the wrong thing. `token_list` spells them.
    def self.unresolved(text : String, vars : Hash(String, String) = effective_vars,
                        prefix : String = Settings.env_prefix,
                        deferred : Array(String)? = declared_bindings) : Array(String)
      return [] of String if prefix.empty?
      return [] of String unless text.byte_index(prefix) # same fast no-op as `expand`
      # `deferred: nil` means "nothing in this text is deferred to a later pass" — and the ENV
      # pass this query pairs with (`expand`, `resolve: Owns::Env`) never resolves BIND. So a
      # `$BIND.X` here is reported whether or not it is BOUND: see `bind_resolvable`.
      scan_unresolved(text.to_slice, vars, prefix, deferred, bind_resolvable: !deferred.nil?)
    end

    # EVERY `$NAME` the text references, set or not, in first-appearance order.
    #
    # `unresolved` with an empty var table: nothing resolves, so every name is reported —
    # and reported through the SAME byte-level scan `expand` walks, `$$` escapes included.
    # A second hand-rolled scanner is how two answers to "what tokens are in here?" come to
    # disagree; there is exactly one, and this is a call into it.
    #
    # `ns` narrows it to ONE namespace and answers in BARE names — the shape a caller that will
    # INDEX a table with them needs (`vars_without`, a slot's literal report). Without it the
    # names come back qualified under the namespaced syntax, like `unresolved`'s.
    def self.token_names(text : String, prefix : String = Settings.env_prefix,
                         ns : Namespace? = nil) : Array(String)
      return [] of String if prefix.empty?
      return [] of String unless text.byte_index(prefix)
      empty = {} of String => String
      # The table is EMPTY, so `bind_resolvable` cannot change the answer either way: every ref
      # is a miss and every ref is listed.
      scan_unresolved(text.to_slice, empty, prefix, nil,
        owns: ns ? ns.owns : Owns::All, qualify_names: ns.nil?, bind_vars: empty)
    end

    # `vars` minus `names` — the substitution table for a surface where some names must stay
    # LITERAL on the wire.
    #
    # Subtracting from the TABLE rather than special-casing the scan is what keeps this one
    # rule instead of two: an excluded name is simply a name gori does not have a value for,
    # which is the already-defined "unset `$KEY` ships literally, never refused" behaviour
    # every send path shares. Nothing downstream needs to learn a new state.
    #
    # The caller with a reason to use it is an EVIDENCE buffer (see
    # `RepeaterView#operator_env_vars`): a `$filter` the capture arrived with is an origin
    # byte, while a `$TOKEN` the operator typed into the same buffer is a variable reference.
    # Provenance is per NAME there, not per buffer.
    def self.vars_without(names : Enumerable(String),
                          vars : Hash(String, String) = effective_vars) : Hash(String, String)
      excluded = names.is_a?(Set) ? names : names.to_set
      return vars if excluded.empty?
      vars.reject { |k, _| excluded.includes?(k) }
    end

    private def self.scan_unresolved(bytes : Bytes, vars : Hash(String, String),
                                     prefix : String, deferred : Array(String)?,
                                     verbatim : Array({Int32, Int32})? = nil, *,
                                     syntax : Syntax = Settings.env_syntax,
                                     owns : Owns = Owns::All,
                                     qualify_names : Bool = true,
                                     bind_vars : Hash(String, String)? = nil,
                                     bind_resolvable : Bool = false) : Array(String)
      names = [] of String
      seen = Set(String).new
      n = bytes.size
      plen = prefix.bytesize
      i = 0
      vi = 0 # see `expand`: the same walk over the same sorted, disjoint list
      while i < n
        if verbatim
          while vi < verbatim.size && verbatim[vi][1] <= i
            vi += 1
          end
          if vi < verbatim.size && verbatim[vi][0] <= i
            stop = verbatim[vi][1]
            i = stop > n ? n : stop
            next
          end
        end
        unless prefix_at?(bytes, prefix, i)
          i += 1
          next
        end
        # Cap the token at the next verbatim span exactly as `expand` does — the two MUST agree
        # about where a token ends (see the note there), so a `$NAME` reaching into a payload
        # span is neither substituted by `expand` nor reported here. `escapes: All` for the same
        # reason: an escape is not a reference in EITHER pass's reading, and the advance past one
        # is the same width whoever owns it.
        limit = (verbatim && vi < verbatim.size) ? verbatim[vi][0] : n
        found = read_token_at(bytes, i, limit, syntax: syntax, prefix: prefix, escapes: Owns::All)
        unless found
          i += 1
          next
        end
        unless found.kind.token? && found.owned_by?(owns)
          i += found.width
          next
        end
        # `bind_resolvable` decides whether a BIND token may be answered by the live binding
        # table at all. A scan whose caller has a LATER pass to hand the token to (a request
        # body: `deferred` given, the send seam re-scans with `resolve: Owns::Bind`) says yes;
        # a scan for bytes no binding pass will ever touch (`unresolved(deferred: nil)` on a
        # target/SNI/URL) says no, and a bound `$BIND.HOST` is reported rather than blessed.
        # Bare mode never reaches it: there is one namespace, `found.ns` is nil, and `vars` is
        # the one table.
        resolvable = bind_resolvable || !found.ns.try(&.send_time?)
        if resolvable && table_for(found.ns, vars, bind_vars).has_key?(found.name)
          i += found.width
          next
        end
        # A DEFERRED name is dropped from the report but still walks the MISS branch: `expand`
        # does not know about bindings, so in bare mode it re-scans from just past the prefix
        # here, and this has to walk the same offsets or the two could disagree about what a
        # later token even is. In namespaced mode the whole `$NS.NAME` is consumed by both.
        #
        # Only a BIND name is deferrable: `deferred` is the declared-binding list, and an
        # `$ENV.SESSION` miss is a genuine env-var miss even when a rule declares `SESSION`.
        key = qualify_names ? qualified_of(found) : found.name
        if seen.add?(key)
          ns = found.ns
          deferrable = ns.nil? || ns.send_time?
          names << key unless deferrable && deferred && deferred.includes?(found.name)
        end
        i += found.miss_width(plen, syntax)
      end
      names
    end

    # The reporting spelling of one Found: `"ENV.HOST"` under the namespaced syntax, the bare
    # name under the bare one (where there is no second namespace to tell it apart from).
    private def self.qualified_of(found : Found) : String
      (ns = found.ns) ? qualify(ns, found.name) : found.name
    end

    # The same answer for a caller holding a `Ref` rather than a scan result — the NAME a report
    # carries (`unresolved`'s and `token_names`' list shape), not the token's spelling. Bare mode
    # has one namespace, so a qualified name there would be a distinction nothing can act on.
    def self.report_name(ref : Ref, syntax : Syntax = Settings.env_syntax) : String
      syntax.bare? ? ref.name : ref.qualified
    end

    # Every Token in `bytes`, in order, for the queries that want the tokens themselves rather
    # than a resolution verdict. Escapes are skipped whole (they are not references) and a
    # Literal is stepped over — the same reader, so the same token boundaries.
    private def self.each_token(bytes : Bytes, prefix : String, syntax : Syntax, & : Found ->) : Nil
      n = bytes.size
      i = 0
      while i < n
        unless prefix_at?(bytes, prefix, i)
          i += 1
          next
        end
        if found = read_token_at(bytes, i, n, syntax: syntax, prefix: prefix, escapes: Owns::All)
          yield found if found.kind.token?
          i += found.width
        else
          i += 1
        end
      end
    end

    # Every reference in `text` as a `Ref`, in first-appearance order, duplicates included.
    # A BARE token names no namespace and is reported as `ENV` — the layer whose table the bare
    # grammar's build-time pass resolves from.
    def self.token_refs(text : String, prefix : String = Settings.env_prefix,
                        syntax : Syntax = Settings.env_syntax) : Array(Ref)
      refs = [] of Ref
      return refs if prefix.empty? || !text.byte_index(prefix)
      each_token(text.to_slice, prefix, syntax) do |found|
        refs << Ref.new(found.ns || Namespace::Env, found.name)
      end
      refs
    end

    # Every KEY a text's tokens should be remembered by — the QUALIFIED key and the BARE name
    # for each one. For a TUI literal set (evidence bytes whose `$id` is the origin's, not a
    # reference): the set outlives a mid-session syntax toggle, and one spelling would either
    # stop matching or start matching the other namespace's name.
    def self.literal_keys(text : String, prefix : String = Settings.env_prefix,
                          syntax : Syntax = Settings.env_syntax) : Set(String)
      keys = Set(String).new
      return keys if prefix.empty? || !text.byte_index(prefix)
      each_token(text.to_slice, prefix, syntax) do |found|
        keys << found.name
        if ns = found.ns
          keys << qualify(ns, found.name)
        end
      end
      keys
    end

    # Finds the head/body boundary in wire-form text: the byte offset where the
    # body starts, right after the first blank line. Checks for both a bare
    # `\n\n` (how the Repeater/Miner editors store the blob internally) and,
    # defensively, an already-CRLF `\r\n\r\n` (e.g. captured flow bytes loaded
    # verbatim). Returns `bytes.size` when no blank line is found — an all-head
    # buffer (no body), which `expand_wire` then normalizes in full, matching the
    # pre-existing behavior for header-only text.
    # The end of the head (index of the first byte of the body) in wire-form bytes:
    # the FIRST of `\n\n`, `\n\r\n`, or `\r\n\r\n`, whichever occurs earlier — never a
    # fixed preference for one spelling, which is how a body containing a CRLFCRLF has
    # repeatedly moved this boundary in this codebase. Returns `bytes.size` when the
    # message has no terminator at all (a hand-authored head is still a head).
    #
    # Public because it is the ONLY correct answer to this question and every surface
    # that splits a request must share it: MCP's History recording used to scan for
    # `\r\n\r\n` alone and REFUSED to send a bare-LF-terminated request — the exact
    # payload its `verbatim` flag advertises.
    def self.head_body_boundary(bytes : Bytes) : Int32
      if sep = head_body_separator(bytes)
        offset, width = sep
        offset + width
      else
        bytes.size
      end
    end

    # `{offset of the blank-line separator, its width in bytes}`, or nil when the message
    # carries none. The SCANNING half of `head_body_boundary`, and the only place the
    # three terminator spellings are enumerated.
    #
    # Two shapes exist because callers want two different things and deriving one from the
    # other needs the width. `head_body_boundary` wants where the BODY starts (to normalize
    # or expand the head and copy the body through untouched). A projection that renders the
    # head as text wants the head WITHOUT its terminator, which is `bytes[0, offset]` — and
    # it cannot recover that from the boundary alone, because subtracting a fixed 4 is only
    # right for `\r\n\r\n`. `MCP::Serialize.head_and_body` hard-coded that 4 alongside its own
    # CRLFCRLF-only scan, so a bare-LF-terminated held message — a CL/TE desync primitive gori
    # stores byte-exact (P7) — reported its whole body as part of the head with `body_size: 0`,
    # on MCP `intercept_get`/`intercept_list` AND `gori run intercept show`/`list`, while the
    # edit path on the same bytes split it correctly.
    def self.head_body_separator(bytes : Bytes) : {Int32, Int32}?
      n = bytes.size
      i = 0
      while i < n
        if bytes[i] == 0x0A_u8 && i + 1 < n && bytes[i + 1] == 0x0A_u8
          return {i, 2}
        end
        # `\n\r\n` (0x0A 0x0D 0x0A): a bare-LF header terminator followed by a CRLF blank
        # line. The two neighboring checks both miss it — LFLF needs `bytes[i+1]==0x0A`
        # and CRLFCRLF starts on `0x0D` — so without this branch the message reads as
        # all-head and the body's bare LFs get promoted to CRLF. Body starts at i+3.
        if bytes[i] == 0x0A_u8 && i + 2 < n &&
           bytes[i + 1] == 0x0D_u8 && bytes[i + 2] == 0x0A_u8
          return {i, 3}
        end
        if bytes[i] == 0x0D_u8 && i + 3 < n &&
           bytes[i + 1] == 0x0A_u8 && bytes[i + 2] == 0x0D_u8 && bytes[i + 3] == 0x0A_u8
          return {i, 4}
        end
        i += 1
      end
      nil
    end

    # Byte-level equivalent of `gsub(/\r?\n/, "\r\n")`: inserts `\r` before any
    # `\n` not already preceded by one, leaving everything else untouched. Used
    # instead of a `Regex` because `bytes` (the expanded request text) may carry
    # invalid UTF-8, which `Regex` cannot accept as a subject. Public: also reused
    # by `gori run intercept edit --raw-file` (a locally-read file may be an
    # arbitrary binary body, same invalid-UTF-8 hazard).
    def self.normalize_crlf(bytes : Bytes) : Bytes
      buf = IO::Memory.new(bytes.size)
      prev : UInt8 = 0
      bytes.each do |b|
        buf.write_byte(0x0D_u8) if b == 0x0A_u8 && prev != 0x0D_u8
        buf.write_byte(b)
        prev = b
      end
      buf.to_slice
    end

    # Scans the text for occurrences of any registered env var value and replaces
    # it with the corresponding token (e.g. "$KEY"). Longest value wins at each
    # position (avoids "secret_value" vs "secret" sub-string collisions).
    #
    # Single left-to-right pass (NOT sequential `gsub` per value): a `gsub` chain
    # can re-match a token an earlier replacement inserted — e.g. value "OKEN"
    # matching inside a just-inserted "$TOKEN" — silently corrupting the mask. The
    # pass never re-scans replaced spans, so inserted tokens stay intact.
    #
    # Byte-level, same reasoning as `expand`: callers pass raw request/response
    # text (e.g. MCP `send`/`repeater` tools mask a captured flow's raw bytes for
    # display), which may not be valid UTF-8. Scanning `text.chars` would silently
    # replace any invalid byte sequence with U+FFFD even where no secret value
    # matches nearby — corrupting the displayed/logged text on every call, not
    # just the masked spans. Byte-level value matching is also strictly more
    # precise than char matching: it finds a value's literal bytes regardless of
    # whether the surrounding haystack happens to be well-formed UTF-8.
    # `masking_vars`, not `effective_vars`: a bound session token is exactly the value a
    # masking surface must not print, and widening the default here is what makes every
    # existing caller mask it without a per-caller change (the design's "for free"). Wider
    # than `display_vars` on purpose — see `masking_vars`: a value whose rule was disabled
    # stops RESOLVING but is still a secret sitting in memory.
    #
    # `vars` nil — every namespace's maskable values (`masking_table`), each masked back to ITS
    # OWN spelling, so a bound `$BIND.SESSION` and an env `$ENV.SESSION` holding different values
    # are not both printed as one name. A table passed explicitly is read as the ENV layer's,
    # which is what every existing caller means and what the bare grammar has.
    def self.mask_secrets(text : String, vars : Hash(String, String)? = nil,
                          prefix : String = Settings.env_prefix,
                          syntax : Syntax = Settings.env_syntax) : String
      return text if prefix.empty?
      candidates = mask_candidates(vars, syntax)
      return text if candidates.empty?

      bytes = text.to_slice
      n = bytes.size
      buf = IO::Memory.new(n)
      i = 0
      while i < n
        hit = candidates.find do |(_, vbytes)|
          i + vbytes.size <= n && vbytes.each_with_index.all? { |b, j| bytes[i + j] == b }
        end
        if hit
          buf << spell(hit[0], syntax, prefix)
          i += hit[1].size
        else
          buf.write_byte(bytes[i])
          i += 1
        end
      end
      String.new(buf.to_slice)
    end

    # Longest value first, and ENV before BIND on a tie. Both halves are ORDER, not filtering:
    # the scan below takes the first candidate that matches at a position, so "secret_value"
    # must be offered before "secret", and two namespaces holding the same value must resolve to
    # one spelling deterministically rather than to whichever the sort happened to leave first.
    #
    # Empty and short values are dropped: a 3-byte value matches everywhere and would mask the
    # text into nonsense.
    private def self.mask_candidates(vars : Hash(String, String)?,
                                     syntax : Syntax) : Array({Ref, Bytes})
      table =
        if v = vars
          v.map { |(k, val)| {Ref.new(Namespace::Env, k), val} }
        elsif syntax.bare?
          # `masking_vars`, not `masking_table`: the bare grammar has ONE table, so a name held
          # in both layers is one secret with one spelling, exactly as it always was.
          masking_vars.map { |(k, val)| {Ref.new(Namespace::Env, k), val} }
        else
          masking_table
        end
      table
        .reject { |(_, v)| v.strip.empty? || v.size < 4 }
        .sort_by! { |(ref, v)| {-v.bytesize, ref.ns.value, ref.name} }
        .map { |(ref, v)| {ref, v.to_slice} }
    end

    # Char offsets [start, end) of each env-shaped token in `text` (end exclusive).
    # Char-based (not byte) — the consumer (Highlight.env_spans_in) slices with
    # `text[a...b]`, which is char-indexed in Crystal, so multi-byte text stays aligned.
    # `known` is true when KEY is registered in `vars`.
    # `known` is `display_vars`-wide, so a BOUND `$SESSION` paints like a set env var and
    # a declared-but-unbound one paints like an unknown key — visible before send, which is
    # the affordance the TUI gets for free and the CLI/MCP have to state in a refusal.
    #
    # `vars` nil — the live tables. `known` is then answered PER NAMESPACE (`vars_for`), which is
    # what lets one editor paint `$ENV.HOST` bound and `$BIND.SESSION` unbound in the same line.
    # A table passed explicitly answers for both, which is the bare grammar's single-table
    # reading and what every existing caller means.
    def self.regions(text : String, prefix : String = Settings.env_prefix,
                     vars : Hash(String, String)? = nil,
                     syntax : Syntax = Settings.env_syntax) : Array(Region)
      acc = [] of Region
      return acc if prefix.empty?
      chars = text.chars
      n = chars.size
      i = 0
      env_table = vars || (syntax.bare? ? display_vars : vars_for(Namespace::Env))
      bind_table = nil.as(Hash(String, String)?)
      while i < n
        unless prefix_at?(chars, prefix, i)
          i += 1
          next
        end
        # `escapes: All`: painting the `$id` inside `$$id` (or the `$ENV.X` inside `$$ENV.X`) as
        # a resolvable token would tell the operator the opposite of what the wire will carry.
        found = read_token_at(chars, i, n, syntax: syntax, prefix: prefix, escapes: Owns::All)
        unless found
          i += 1
          next
        end
        if found.kind.token?
          ns = found.ns
          # Exhaustive, for `table_for`'s reason: a two-way branch paints a third namespace's token
          # `known` because the ENV table happens to hold a name of its own.
          table =
            if ns.nil?
              env_table
            else
              case ns
              in Namespace::Env  then env_table
              in Namespace::Bind then bind_table ||= vars || binding_values
              end
            end
          acc << Region.new(i, i + found.width, ns, found.name, table.has_key?(found.name))
        end
        i += found.width
      end
      acc
    end

    # `regions` projected to the 3-tuple its oldest consumers read. Kept because `Highlight` and
    # `MCP::Serialize` want exactly this and nothing more.
    def self.token_regions(text : String, prefix : String = Settings.env_prefix,
                           vars : Hash(String, String) = display_vars) : Array({Int32, Int32, Bool})
      regions(text, prefix, vars).map { |r| {r.start, r.stop, r.known} }
    end

    # Parse "KEY VALUE" or "KEY=value" (value may contain spaces when using the
    # space form). Which syntax was used is decided by whichever separator — `=`
    # or whitespace — appears FIRST in the string, not by whether `=` appears
    # anywhere at all: a space-form value that itself contains `=` (e.g. a
    # base64-padded API key, `APIKEY dGVzdA==`) must still split on the leading
    # whitespace, not on the `=` buried inside the value. Returns nil when KEY is
    # invalid.
    def self.parse_line(text : String) : {String, String}?
      # `.scrub` first: `text` is an operator-supplied env line (`gori run project env set
      # KEY VALUE`, the TUI env editor), and both the `index(/\s/)` and `split(/\s+/, 2)`
      # below are PCRE2 calls, which raise `ArgumentError` on a subject that is not valid
      # UTF-8. That escapes `CLI.run`'s `Gori::Error`-only rescue as a raw backtrace.
      raw = text.scrub.strip
      return nil if raw.empty?
      eq = raw.index('=')
      ws = raw.index(/\s/)
      if eq && (ws.nil? || eq < ws)
        key = raw[0...eq].strip
        val = raw[eq + 1..]
        return nil unless valid_key?(key)
        {key, val}
      else
        parts = raw.split(/\s+/, 2)
        return nil if parts.size < 2
        key = parts[0]
        return nil unless valid_key?(parts[0])
        {key, parts[1]}
      end
    end

    def self.parse_vars_json(raw : String?) : Array({String, String})
      return [] of {String, String} if raw.nil? || raw.strip.empty?
      # A malformed row degrades to "no vars", matching every sibling reader of a persisted
      # JSON blob (`Notes.parse`, `CaptureStatus.parse_file`, `Analyzer#load_disabled`). The
      # `.as_a?` below already says that is the intent for a bad SHAPE; without this rescue a
      # bad PARSE escaped instead — out of `load_project`, and so out of `Session.open` and
      # `CLI::Run.open_store`, failing the whole project open on a raw JSON::ParseException.
      arr = begin
        JSON.parse(raw).as_a?
      rescue JSON::ParseException
        nil
      end
      return [] of {String, String} unless arr
      out = [] of {String, String}
      arr.each do |e|
        next unless o = e.as_h?
        key = o["key"]?.try(&.as_s?)
        val = o["value"]?.try(&.as_s?)
        next if key.nil? || key.empty? || val.nil?
        next unless valid_key?(key)
        out << {key, val}
      end
      out
    end

    def self.serialize_vars(vars : Array({String, String})) : String
      JSON.build do |j|
        j.array do
          vars.each do |(key, val)|
            j.object do
              j.field "key", key
              j.field "value", val
            end
          end
        end
      end
    end

    # Publish (and invalidate) only on a real DELTA. Both repeat callers ask on a cadence —
    # the TUI's `apply_external_change` fires whenever `data_version` moves, which own captures
    # do, and MCP's `refresh_project_env` runs before every outbound tool call — while
    # `bump_highlight_rev` is the invalidation signal for two caches that assume it is rare:
    # every `TextArea`'s styled buffer, and `Rules#subst_snapshot`, whose own doc names the
    # bump set as "a settings load, a project env write, a rule edit and every rebind". An
    # unchanged table publishes nothing, so re-reading it costs one row and one parse.
    #
    # `Array({String, String})` compares elementwise, so this is order-sensitive as it must be:
    # the pane renders the table in stored order.
    def self.load_project(store : Store) : Nil
      vars = parse_vars_json(store.setting(PROJECT_VARS_KEY))
      return if vars == Settings.project_env_vars
      Settings.project_env_vars = vars
      bump_highlight_rev
    end

    # Returns whether the persisted write committed (false = store busy/locked). The
    # in-memory Settings.project_env_vars is updated regardless (the TUI relies on the
    # immediate update; an MCP caller that got false reloads from the store on its next
    # active tool, so a rolled-back change doesn't stick).
    def self.save_project(store : Store, vars : Array({String, String})) : Bool
      committed =
        if vars.empty?
          store.delete_setting(PROJECT_VARS_KEY)
        else
          store.set_setting(PROJECT_VARS_KEY, serialize_vars(vars))
        end
      Settings.project_env_vars = vars.dup
      bump_highlight_rev
      # NAMES only, never values: a `$KEY` table is where a session token, an API key or a
      # bearer lands, and this is the one config surface whose whole content is secret by
      # default. The count and the key list are what an audit needs — "who added $ADMIN_TOKEN",
      # not what it was. Persisted WHOLESALE, so the line describes the resulting set rather
      # than a delta the caller never computed.
      if committed
        names = vars.map(&.[0]).sort!
        summary = names.empty? ? "cleared" : "#{names.size} var#{names.size == 1 ? "" : "s"} — #{names.join(", ")}"
        ConfigLog.record(store, "env", "project env vars saved: #{summary}")
      end
      committed
    end

    # Read-modify-write the project env table with the READ taken INSIDE the store's write
    # transaction (`Store#mutate_setting`).
    #
    # `save_project` above persists the WHOLE array, which is right for the surface that owns
    # the whole array (the TUI's env pane edits it in place) and wrong for every per-KEY
    # mutator: those load the array, change one entry and save it back, so the loser of a
    # race commits an array built before the winner's row landed and silently DELETES every
    # var the peer added. MCP's own `ENV_REFRESH_TOOLS` comment already names that hazard and
    # treats a pre-read as the mitigation; measured on the note set (the same shape) the
    # pre-read narrows the window to a few hundred microseconds and loses half the writes
    # anyway. One transaction closes it.
    #
    # `block` is handed the table as the transaction reads it and returns the table to
    # persist, or nil to write nothing. It runs on the WRITER FIBER — see
    # `Store#mutate_setting` for what that forbids.
    #
    # Unlike `save_project` an empty table is WRITTEN (as `[]`) rather than deleting the row:
    # a delete and an insert are two different statements and this is one. `parse_vars_json`
    # reads `[]` and a missing row identically, so nothing downstream can tell them apart.
    def self.mutate_project(store : Store,
                            &block : Array({String, String}) -> Array({String, String})?) : Bool
      applied = nil.as(Array({String, String})?)
      committed = store.mutate_setting(PROJECT_VARS_KEY) do |raw|
        vars = block.call(parse_vars_json(raw))
        if vars
          applied = vars
          serialize_vars(vars)
        end
      end
      return false unless committed
      if vars = applied
        Settings.project_env_vars = vars.dup
        bump_highlight_rev
      end
      true
    end

    # Set one `$KEY`, keeping its position when it is already there (the pane renders the
    # table in stored order, so an edit must not move a row). False = nothing was persisted.
    def self.set_project_var(store : Store, key : String, value : String) : Bool
      mutate_project(store) do |vars|
        idx = vars.index { |(k, _)| k == key }
        idx ? (vars[idx] = {key, value}) : (vars << {key, value})
        vars
      end
    end

    # Drop one `$KEY`. False when the store did not commit. Deliberately NOT answering "there
    # was no such key": that is a deterministic refusal, the caller already holds the table to
    # make it from (it reloads before every env tool), and folding it into the same `false` a
    # busy store returns is what makes an agent retry a refusal forever — the split
    # `SessionSlots`' list edits document.
    def self.delete_project_var(store : Store, key : String) : Bool
      mutate_project(store) do |vars|
        vars.reject! { |(k, _)| k == key }
        vars
      end
    end

    def self.valid_key?(key : String) : Bool
      return false if key.empty?
      return false unless KEY_HEAD.matches?(key[0].to_s)
      key.chars[1..].all? { |c| KEY_TAIL.matches?(c.to_s) }
    end

    # ── THE reader ────────────────────────────────────────────────────────────
    #
    # What sits at `at`, or nil when no sigil does. ONE implementation of the token grammar for
    # every scan in the repo — `expand`, `scan_unresolved`, `regions`, `each_token` and
    # `Rules#substitute` — because the moment there are two, two surfaces disagree about where
    # a token ends and the one that sends bytes is the one that is wrong.
    #
    # Both representations are served: BYTES for every path that may hold invalid UTF-8 (a
    # captured body loaded verbatim into an editor), CHARS for painting, whose consumer slices
    # with `text[a...b]`. Names and namespace labels are pure ASCII, so the two answers are the
    # same answer measured in different units.
    #
    # `limit` caps how far a token opened here may READ — the start of a verbatim span (a fuzz
    # payload) or the end of the buffer. The SIGIL itself is matched against the whole source:
    # a `$` immediately before a payload span is a sigil that opens nothing, which is what the
    # cap exists to produce (`$EN` cut by a span is a Literal, a NAME cut mid-way is truncated
    # exactly as it always was).
    #
    # `escapes` names the escapes this reader should REPORT. A namespace outside it comes back
    # as a Literal spanning the WHOLE escape, so the caller copies it through byte-exact and
    # nothing inside it is re-read — that is how `$$BIND.X` survives the env pass intact.
    # `Owns::None` turns escape recognition off entirely (`Rules#substitute` owns `$$` itself,
    # in both syntaxes, before it asks anything else).
    def self.read_token_at(src : Bytes, at : Int32, limit : Int32, *,
                           syntax : Syntax = Settings.env_syntax,
                           prefix : String = Settings.env_prefix,
                           escapes : Owns = Owns::All) : Found?
      read_token_impl(src, at, limit, syntax, prefix, escapes)
    end

    def self.read_token_at(src : Array(Char), at : Int32, limit : Int32, *,
                           syntax : Syntax = Settings.env_syntax,
                           prefix : String = Settings.env_prefix,
                           escapes : Owns = Owns::All) : Found?
      read_token_impl(src, at, limit, syntax, prefix, escapes)
    end

    # Untyped in `src` on purpose: Crystal instantiates it once per representation, so the
    # byte path keeps its byte comparisons and the char path its char comparisons with no
    # runtime dispatch between them.
    private def self.read_token_impl(src, at, limit, syntax : Syntax, prefix : String,
                                     escapes : Owns) : Found?
      plen = plen_of(src, prefix)
      return nil if plen == 0
      return nil unless prefix_at?(src, prefix, at)
      if syntax.namespaced?
        read_namespaced(src, at, limit, plen, prefix, escapes)
      else
        read_bare(src, at, limit, plen, prefix, escapes)
      end
    end

    private def self.read_bare(src, at, limit, plen, prefix, escapes) : Found
      if at + 2 * plen <= limit && prefix_at?(src, prefix, at + plen)
        # `$$`. Both sigils are claimed either way, so the name behind them is never read —
        # which is what makes the escape mean the same thing whether or not it would resolve.
        return Found.new(escapes.none? ? Kind::Literal : Kind::Escape, nil, "", at, 2 * plen)
      end
      if parsed = read_name(src, at + plen, limit)
        name, consumed = parsed
        Found.new(Kind::Token, nil, name, at, plen + consumed)
      else
        Found.new(Kind::Literal, nil, "", at, plen)
      end
    end

    # The namespaced grammar at a sigil:
    #
    #   `$ENV.HOST`        → Token(Env, "HOST")
    #   `$$ENV.X`          → Escape(Env, "X") for the ENV pass; Literal(whole) for any other
    #   `$$`, `$$id`, `$$1`→ Literal(plen) — two literal bytes, the second sigil re-examined
    #   `$ENVX`, `$ENV.`, `$ENV.1x`, `$env.X`, `$FOO.bar`, `$id` → Literal(plen)
    #   `$ENV.A$BIND.B`    → two adjacent Tokens
    #   `$BIND.A.B`        → Token(Bind, "A") followed by the bytes `.B`
    private def self.read_namespaced(src, at, limit, plen, prefix, escapes) : Found
      if at + 2 * plen <= limit && prefix_at?(src, prefix, at + plen)
        if ref = read_ref(src, at + 2 * plen, limit)
          ns, name, consumed = ref
          width = 2 * plen + consumed
          owned = !escapes.none? && escapes.includes?(ns.owns)
          return Found.new(owned ? Kind::Escape : Kind::Literal, ns, name, at, width)
        end
        # A bare `$$` is NOT an escape here: `$ne` needs none, so `$$` is two bytes and the
        # second one is re-examined on its own (`$$ENV.X` is the escape, `$$$ENV.X` is a
        # literal `$` followed by it).
        return Found.new(Kind::Literal, nil, "", at, plen)
      end
      if ref = read_ref(src, at + plen, limit)
        ns, name, consumed = ref
        Found.new(Kind::Token, ns, name, at, plen + consumed)
      else
        Found.new(Kind::Literal, nil, "", at, plen)
      end
    end

    # `NS.NAME` at `at` → `{namespace, name, units consumed}`. Longest label first; the dot is
    # STRUCTURAL (never a name character), so `$BIND.A.B` ends the name at the second dot.
    private def self.read_ref(src, at, limit) : {Namespace, String, Int32}?
      NAMESPACE_MATCH.each do |entry|
        label, ns = entry
        llen = label.size
        next unless at + llen + 1 <= limit
        next unless prefix_at?(src, label, at)
        next unless unit?(src, at + llen, '.')
        if parsed = read_name(src, at + llen + 1, limit)
          name, consumed = parsed
          return {ns, name, llen + 1 + consumed}
        end
      end
      nil
    end

    # ── per-representation primitives ─────────────────────────────────────────

    private def self.plen_of(src : Bytes, prefix : String) : Int32
      prefix.bytesize
    end

    private def self.plen_of(src : Array(Char), prefix : String) : Int32
      prefix.size
    end

    # `needle` occurs at `at`. Used for the sigil AND for a namespace label — both are
    # "does this literal sit here", and the prefix is operator-configurable so neither can be
    # a constant.
    #
    # Public because `EnvMigration` walks the same bytes with the same reader and had grown its
    # own byte-identical copy. Two spellings of "is the sigil here" is how a migration ends up
    # disagreeing with the grammar it is migrating.
    def self.prefix_at?(bytes : Bytes, needle : String, at : Int32) : Bool
      nb = needle.to_slice
      return false if at < 0 || at + nb.size > bytes.size
      j = 0
      while j < nb.size
        return false if bytes[at + j] != nb[j]
        j += 1
      end
      true
    end

    def self.prefix_at?(chars : Array(Char), needle : String, at : Int32) : Bool
      return false if at < 0 || at + needle.size > chars.size
      j = at
      needle.each_char do |c|
        return false if chars[j] != c
        j += 1
      end
      true
    end

    private def self.unit?(bytes : Bytes, at : Int32, c : Char) : Bool
      at < bytes.size && bytes[at] == c.ord.to_u8
    end

    private def self.unit?(chars : Array(Char), at : Int32, c : Char) : Bool
      at < chars.size && chars[at] == c
    end

    # KEY_HEAD/KEY_TAIL as byte tests. Pure ASCII, so a byte from an invalid UTF-8 sequence
    # simply fails both and is left alone by the caller — the property that lets every scan
    # here run over a captured binary body without decoding it.
    private def self.key_head?(c : Char) : Bool
      c.ascii_letter? || c == '_'
    end

    private def self.key_tail?(c : Char) : Bool
      c.ascii_alphanumeric? || c == '_'
    end

    private def self.read_name(bytes : Bytes, start : Int32, limit : Int32) : {String, Int32}?
      read_key_bytes?(bytes, start, limit)
    end

    private def self.read_name(chars : Array(Char), start : Int32, limit : Int32) : {String, Int32}?
      return nil if start >= limit || !key_head?(chars[start])
      j = start + 1
      while j < limit && key_tail?(chars[j])
        j += 1
      end
      {chars[start...j].join, j - start}
    end

    # Public form: `Rules#substitute` (#501) resolves a token inside a rule's replacement in
    # ONE pass that also handles `$1` and `$$`, so it cannot call `expand` — but it must read a
    # NAME exactly the way the reader above does, or the two would disagree about where a token
    # ends. Kept as its own door (rather than folded into `read_token_at`) because a rule's
    # replacement grammar owns `$$` in BOTH syntaxes, which no other scan does.
    def self.read_key_bytes?(bytes : Bytes, start : Int32, n : Int32) : {String, Int32}?
      return nil if start >= n || !key_head?(bytes[start].unsafe_chr)
      j = start + 1
      while j < n && key_tail?(bytes[j].unsafe_chr)
        j += 1
      end
      {String.new(bytes[start...j]), j - start}
    end
  end
end
