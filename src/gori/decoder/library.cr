module Gori::Decoder
  # The global named-chain library (settings.json `decoder.chains`) rendered as CONVERTERS,
  # so a saved name is a chain step like any built-in: `myenc > url-encode` runs wherever a
  # spec is accepted — the Decoder tab, the Repeater/Fuzzer `§value¦chain§` marker, `gori run
  # decoder`, MCP `decode`. Registering into the registry rather than teaching `run` a second
  # kind of token is what buys that reach: every surface already resolves a step through
  # `Registry#[]?`, and the ^Y autocomplete already feeds off `Registry#match`.
  #
  # Settings pushes the entries in (Decoder.library=); the engine never reads settings itself.
  module Library
    # Ceiling on ONE saved chain's flattened step count. Splicing is exponential in the worst
    # case (`a = b > b`, `b = c > c`, …), so a library that would expand past this is refused
    # as a whole rather than turned into a multi-second step nobody asked for.
    MAX_TOKENS = 256

    # Register one converter per saved entry, in library order. NEVER raises: the caller is
    # Settings.load's parse path, whose blanket rescue would turn one hand-edited name into a
    # factory reset of every other section. A name that cannot work is skipped (a built-in
    # already answers to it, so the built-in must keep winning) or registered as a step that
    # FAILS with its reason (recursive / over-long), which is visible where a silent omission
    # would look like "unknown converter" for no stated cause.
    def self.register_all(r : Registry, entries : Array({String, String})) : Nil
      specs = {} of String => {String, String} # normalized name => {name as typed, spec}
      order = [] of String
      entries.each do |(name, spec)|
        nk = Registry.normalize(name)
        next if nk.empty?
        next if r[nk]?             # a built-in (name OR alias) owns this key
        next if specs.has_key?(nk) # first wins; save_chain already replaces by normalized name
        specs[nk] = {name, spec}
        order << nk
      end

      flat = {} of String => Array(String)?
      why = {} of String => String
      # TWO passes, and the split is the whole point. `flatten` asks `r[tok]?` to decide
      # "built-in, leave it alone" from "saved name, splice it" — so flattening and registering
      # in ONE loop mutated the registry it was probing: by the time entry i was flattened,
      # entries 0..i-1 answered `r[tok]?` and every BACKWARD reference stayed a run-time nested
      # `Decoder.run` instead of being spliced. Only forward references were spliced, so only
      # forward references were counted against MAX_TOKENS — and the ordinary authoring order
      # (save the helper, THEN save the chain that calls it) is entirely backward references,
      # which left the guard dead on the path it exists for. Measured: a 25-deep library written
      # helper-last is refused at MAX_TOKENS; the same library written helper-first ran 73
      # seconds of CPU for one `run decoder`, and 2.8 s for three fuzz requests at depth 18.
      # It also made one library mean two different things — the two orderings reported
      # different failing tokens at different prefix depths for the same broken entry.
      #
      # With `r` held pristine (built-ins only) for the whole flatten phase, both orderings
      # produce the same `flat`/`why`, so the library's meaning no longer depends on the order
      # its entries happen to sit in settings.json.
      order.each { |nk| flatten(nk, specs, r, flat, why, [] of String) }
      order.each do |nk|
        name, spec = specs[nk]
        begin
          # `flat` is total over `order` after the first pass: `flatten` writes `flat[nk]` on
          # every path that reaches its tail, and the one path that returns WITHOUT memoizing
          # (the `stack.includes?` cycle frame) cannot fire at depth 0, where the stack is empty.
          r.register build(name, spec, flat[nk]?, why[nk]?, r)
        rescue
          # Registry#register raises on a duplicate key, and the two filters above already
          # exclude every way one can arise. This bounds the blast radius if that ever drifts:
          # an exception here reaches Settings.load's blanket rescue, which factory-resets
          # every OTHER settings section over one hand-edited name.
        end
      end
    end

    # Splice a saved chain's tokens down to built-in-only tokens, so a registered chain never
    # calls another AT RUN TIME — the recursion is resolved once, here, where a cycle is a
    # visible stack rather than a hang in a fuzz worker. Returns nil when the entry is
    # unusable (cycle, or past MAX_TOKENS), with the reason in `why`.
    #
    # A token that is neither a built-in nor a saved name makes the chain unusable: leaving
    # it "as typed" registered the entry with `unusable: nil`, so `Fuzz::Plan`'s up-front
    # `refuse_unusable_chains` never fired and `Template#apply_chains` sent the payload
    # untransformed (a typo'd `url-encode > nosuchthing` put a raw space on the wire).
    # Marking it here surfaces the same "unknown converter" answer the plan gate already
    # knows how to report — before the first dial.
    #
    # `r` MUST be the pristine built-in registry here — see `register_all`'s two passes. If a
    # saved entry has already been registered into it, `r[tok]?` answers true for that name and
    # the reference below is left as a run-time call rather than spliced.
    private def self.flatten(nk : String, specs, r : Registry,
                             flat : Hash(String, Array(String)?), why : Hash(String, String),
                             stack : Array(String)) : Array(String)?
      return flat[nk] if flat.has_key?(nk)
      if stack.includes?(nk)
        why[nk] = "recursive definition (#{(stack + [nk]).join(" > ")})"
        return nil # NOT memoized: this frame only failed because it is on the stack
      end

      stack << nk
      out = [] of String
      failed = false
      Decoder.parse_spec(specs[nk][1]).each do |tok|
        tk = Registry.normalize(tok)
        # A built-in wins (register_all never lets a saved name shadow one). An unknown
        # token fails the chain as unusable (see comment above). Everything else is a
        # saved name and gets spliced — in EITHER direction, because `r` holds no saved
        # entry at this point.
        if Decoder.exec_step?(tok)
          # An `exec:` step is not a name and cannot be spliced — it stays as written and runs
          # when the saved chain does (#818). It IS refused here when its argv does not
          # tokenize, for the same reason an unknown converter is: the entry would otherwise
          # register as usable and the payload would go out untransformed.
          if reason = Decoder.exec_step_error(tok)
            failed = true
            why[nk] = reason
            break
          end
          out << tok
        elsif r[tok]?
          out << tok
        elsif !specs.has_key?(tk)
          failed = true
          why[nk] = "unknown converter \"#{tok}\""
          break
        else
          inner = flatten(tk, specs, r, flat, why, stack)
          if inner.nil?
            failed = true
            why[nk] = why[tk]? || "unresolvable step \"#{tok}\""
            break
          end
          out.concat(inner)
        end
        if out.size > MAX_TOKENS
          failed = true
          why[nk] = "expands past #{MAX_TOKENS} steps"
          break
        end
      end
      stack.pop

      result = failed ? nil : out
      flat[nk] = result
      result
    end

    private def self.build(name : String, spec : String, tokens : Array(String)?,
                           reason : String?, r : Registry) : Converter
      msg = tokens.nil? ? "#{name}: #{reason || "unusable saved chain"}" : nil
      fn =
        if m = msg
          # The `: Bytes` return annotation is what lets an unconditionally-raising body sit in
          # a Proc(Bytes, Bytes) without a dead trailing expression to type it.
          ->(_input : Bytes) : Bytes { raise DecoderError.new(m) }
        else
          flat = tokens.not_nil!.join(" > ")
          ->(input : Bytes) { apply(name, r, flat, input) }
        end
      # `Array(String).new` and not `[] of String`: a positional `[] of T` followed by more
      # positional args makes the parser read the rest as a PROC TYPE ("expecting '->'").
      #
      # `unusable: msg` carries the SAME sentence the proc raises, askable without calling it —
      # this entry is registered only so its name resolves and the reason is visible, and a
      # caller that has to refuse a plan before the first dial has to be able to see that
      # without running the converter over the operator's payload.
      Converter.new(name, Array(String).new, Category::Saved, Direction::Transform,
        "saved chain: #{spec.strip.empty? ? "(empty)" : spec.strip}", fn, unusable: msg)
    end

    # Run the flattened spec as this one step. A failure INSIDE the recipe is re-raised with
    # the inner token and message attached, so the pipeline row reads "myenc: step 2 'gunzip':
    # …" instead of a bare "myenc failed" that hides which part of the recipe broke. An empty
    # saved chain is the identity, exactly as an empty spec is.
    private def self.apply(name : String, r : Registry, flat : String, input : Bytes) : Bytes
      res = Decoder.run(r, input, flat)
      if idx = res.failed_at
        step = res.steps[idx]
        raise DecoderError.new("#{name}: step #{idx + 1} '#{step.token}': #{step.error || "failed"}")
      end
      res.output || input
    end
  end
end
