require "../protobuf"
require "../protobuf/lens"
require "../protobuf/encoder"
require "../protobuf/schemas"
require "../proxy/h2/grpc"
require "./matcher" # GrpcVerdict — the content-type / body split every fuzz surface shares
require "./payload"
require "./template"

module Gori::Fuzz
  # A run named a gRPC field it cannot sweep.
  #
  # Deliberately NOT a `PlanError::Reason`, for the reason `ChainError` and `WsError` give
  # directly above them in `plan.cr`: that enum is the machine-readable fact behind a sentence
  # each surface writes in ITS OWN idiom, three surfaces `case … in` it exhaustively, and these
  # refusals have no surface idiom to write. "the schema does not declare field 9" reads
  # identically on the CLI, in MCP and in the Fuzzer tab, so the builder writes the sentence
  # once and every surface's existing `Gori::Error` path carries it unchanged.
  class GrpcFieldError < Gori::Error
  end

  # ONE schema-known gRPC field this run sweeps, resolved against the SEED message.
  #
  # `seed` is the capture's own value in the syntax `Protobuf::Encoder.encode` takes back, so
  # it doubles as this position's DEFAULT: a Sniper variation that is not injecting here
  # re-encodes what was captured, and re-encoding a field's own value gives the capture back
  # byte for byte (#837's specced property, which is what makes P7 hold across a whole run).
  struct GrpcFieldPosition
    # What the operator named — `role`, `profile.age`, `tags[1]`, `9` — kept verbatim so
    # every refusal and every report quotes back the thing that was typed.
    getter spec : String
    # `Protobuf::Encoder.replace`'s path: field OCCURRENCE indices, not numbers, because a
    # field number can occur more than once and only the index says which one was picked.
    getter path : Array(Int32)
    getter defn : Protobuf::Schema::FieldDef
    getter seed : String
    # The position's inline Decoder chain, in the `§value¦chain§` spelling — see the
    # "what a chain means on a TYPED field" note on `GrpcFieldTemplate`.
    getter chain : String
    # The occurrence being replaced arrived length-delimited on a repeated packable field, so
    # a comma/space list goes back packed. Read off the WIRE, never off the schema — the same
    # rule `Encoder#encode` documents.
    getter? packed : Bool

    def initialize(@spec : String, @path : Array(Int32), @defn : Protobuf::Schema::FieldDef,
                   @seed : String, @chain : String = "", @packed : Bool = false)
    end

    # What a surface prints when it names this position, ONE home: `role (Role)`,
    # `profile.age (int32)`. The SPEC rather than the declared name, because the operator has
    # to be able to match it against what they typed — `9` and `tags[1]` name a field whose
    # declared name alone would not identify it.
    def label : String
      "#{@spec} (#{@defn.type_label})"
    end
  end

  # A marked HTTP template PLUS N schema-known gRPC field positions, under one global position
  # index space.
  #
  # ## Why a sibling of `Template`, like `WsScript`
  #
  # Every attack mode, `--mark`, each position's `¦chain`, `PayloadSet` and `AutoEncode` are
  # defined over the payload-VALUE vector, not over a buffer — the only buffer-level operation
  # in `Generator#emit` is the splice itself. So a composite that concatenates its parts'
  # position lists into one vector, and fans a rendered value vector back out to the parts,
  # leaves `Mode`, `Generator#sniper/battering/pitchfork/cluster`, `Plan.refuse_unusable_chains`
  # and the payload layer working unchanged. `WsScript` made that argument first; this is the
  # same trick with a different splice, so a Pitchfork can lock a header to a typed field.
  #
  # The request's own `§…§` byte positions are part 0, and the fields follow in the order they
  # were named. So `--mark` / `--auto` keep their meaning and `plan.template` stays a `Template`.
  #
  # ## The splice: everything not fuzzed is COPIED (P7)
  #
  # A variation is built from the CAPTURE's own message octets, `Protobuf::Encoder.replace`-d
  # once per field. That call is a splice, not a serializer: it copies every other byte through
  # unchanged — an undeclared field number, a field whose wire type the schema contradicts, a
  # group, a non-minimal varint some other producer emitted, and the unparsed tail of a
  # truncated capture. Rendering every position with its own default therefore reproduces the
  # seed request byte for byte, which is the property the whole run rests on.
  #
  # ## The type is the point
  #
  # `-3` is a different set of octets as `int32` (ten bytes, sign-extended), `sint32` (one,
  # zigzagged), `bool` or an enum. The payload is TEXT, the declaration decides the bytes, and
  # `Protobuf::Encoder` — the encoder #837 specced against a reference-encoded message — is
  # what applies it. Which is also why a field the schema does not declare, and one whose wire
  # type the declaration contradicts, are refused as positions rather than swept: there is no
  # declaration to encode by, and picking the schema over the bytes is the guess the whole lens
  # exists to avoid. The Repeater's `␣E` form draws that line by rendering those rows read-only;
  # both surfaces read it off the same `Protobuf::Lens.read` + `Protobuf::Encoder.seed` pair, so
  # they cannot come to disagree about which fields exist and which can be typed.
  #
  # ## What `¦chain` and `--encode` mean here, and why
  #
  # They transform the TEXT, BEFORE the declared type turns it into bytes. `--prefix/--suffix/
  # --encode/--case/--hash/--regex-replace` run inside `PayloadSet`, a position's `¦chain` runs
  # in `Generator#chained_reported`, and both are upstream of the encode by construction.
  #
  # The other reading — transform the wire bytes the declaration produced — is not defensible.
  # What comes out of `Encoder.encode` is a tag plus a payload the declaration describes;
  # base64-ing or hashing THAT yields octets no declaration describes, spliced into a message
  # whose length prefix then honestly measures garbage. It is also not a test anyone loses:
  # byte-level mutation of a gRPC body is exactly what a `§…§` position over the same bytes
  # already does, which is the surface this feature sits beside rather than replaces. So the
  # chain acts where the value is still a value: `--encode base64` on a `string` field sends the
  # base64 of the payload AS that string, and on an `int32` field it is refused at plan time
  # (see `refuse_unencodable`) because base64 text is not an integer — which is the honest
  # answer rather than a silent one.
  #
  # ## Framing
  #
  # A re-encoded message changes length, so the 5-byte gRPC prefix is rebuilt by
  # `Proxy::H2::Grpc.frame` — the framer the Repeater's `␣F:FRAME` path is made of. Not a second
  # framer, and not `Config#reframe_grpc?`: that knob repairs a prefix a byte-level payload left
  # stale, and is documented as opt-in because a deliberately-wrong prefix is one of the standard
  # gRPC parser tests. Here the message was re-encoded THROUGH the schema at the operator's
  # request, so a prefix that measured the old one would make every request in the sweep a
  # framing-layer rejection and nothing else. The flag byte is the reason `build` refuses a
  # non-zero one: `Grpc.frame` composes the flag out of the compressed and trailer bits, so a
  # frame carrying anything else could not be re-emitted verbatim, and gori refuses rather than
  # normalizes.
  struct GrpcFieldTemplate
    # Segments one `--field` spec may carry. A `.proto` message nests, but a spec this deep is
    # a typo long before it is a field.
    MAX_SPEC_SEGMENTS = 16

    # Payloads of one field position's set checked against the declaration BEFORE the first
    # dial. A sweep of ten thousand requests needs its refusals up front — the argument
    # `Plan.refuse_unusable_chains` already makes — and unlike a `¦chain`, "can this type hold
    # this text" is answerable with no side effect and no target.
    #
    # Bounded because a payload SET is not: `--brute 'abc:1-8'` is 200 billion values and
    # `WordlistFile#size` is a full file walk. Past this the check stops and the render-time
    # backstop takes over, which reports the reason on the row (`Job#chain_error`) and leaves
    # the capture's own octets in place — never a silently different request.
    PREFLIGHT_MAX = 100_000

    # Field names listed back when a spec does not resolve. A menu, not a dump.
    MENU_MAX = 24

    getter base : Template
    getter fields : Array(GrpcFieldPosition)
    # Every part's positions concatenated — the base template's, then one per field — re-indexed
    # to the global space, exactly as `WsScript.build` does it.
    getter positions : Array(Template::Position)
    getter schema : Protobuf::Schema
    # The rpc this run resolved through, for the surfaces that say so once up front.
    getter method_path : String
    getter message_type : String
    # The capture's own unary message octets. Frozen at plan time and never re-read from a
    # rendered request: it is the P7 source every variation is spliced out of.
    getter message : Bytes
    # The BASELINE body's size. All `§…§` positions are in the head (`build` refuses one in the
    # body), so the body of any rendering is this many bytes and the head is everything before
    # it — which is exact, and immune to a header payload that itself carries a CRLFCRLF.
    getter body_size : Int32

    def initialize(@base : Template, @fields : Array(GrpcFieldPosition),
                   @positions : Array(Template::Position), @schema : Protobuf::Schema,
                   @method_path : String, @message_type : String, @message : Bytes,
                   @body_size : Int32)
    end

    # --- building -------------------------------------------------------------

    # nil when the run named no field, so every existing sweep keeps the plain `Template` path
    # untouched. Raises `GrpcFieldError` — one sentence, every surface — for each way the
    # template, the schema or the spec can fail to produce a position.
    #
    # `baseline` / `baseline_spans` are the template rendered with every position at its own
    # default, which is the request this run actually seeds from and the one the scope gate was
    # matched on. Taken as arguments rather than re-rendered because `Plan.build` already has
    # them and a second rendering is a second answer.
    def self.build(base : Template, baseline : Bytes,
                   baseline_spans : Array({Int32, Int32}), specs : Array(String),
                   request_target : String) : GrpcFieldTemplate?
      return nil if specs.empty?
      msg, body_size = unary_message(baseline, baseline_spans)
      binding = Protobuf::Schemas.resolve(request_target, request: true)
      unless binding
        raise GrpcFieldError.new(
          "no descriptor set resolves #{Protobuf::Schemas.method_path(request_target).inspect} to a " \
          "request message — #{Protobuf::Schemas.status}. Point the project at one " \
          "(Project → Project settings → Proto schema) or fetch it with `gori run grpc reflect URL`")
      end
      assemble(base, specs, binding, msg, body_size)
    end

    # `build`, against a binding the caller already holds.
    #
    # Class-level and binding-taking for the reason `RepeaterView.grpc_form_rows` is: the
    # position/path model has to be exercisable against ANY message in a descriptor set, not
    # only the ones an rpc's REQUEST side happens to use.
    def self.build(base : Template, baseline : Bytes,
                   baseline_spans : Array({Int32, Int32}), specs : Array(String),
                   binding : Protobuf::Schemas::Binding) : GrpcFieldTemplate
      msg, body_size = unary_message(baseline, baseline_spans)
      assemble(base, specs, binding, msg, body_size)
    end

    # Every way the TEMPLATE can fail to carry one editable unary gRPC message, answered before
    # a schema is even looked up — these are facts about the bytes, and they read the same
    # whether or not a descriptor set is loaded. Returns `{the message, the body's size}`.
    private def self.unary_message(baseline : Bytes,
                                   baseline_spans : Array({Int32, Int32})) : {Proxy::H2::Grpc::Message, Int32}
      unless GrpcVerdict.grpc_request?(baseline)
        raise GrpcFieldError.new(
          "a gRPC field position needs a gRPC request: this template declares " \
          "#{(GrpcVerdict.content_type(baseline) || "no content-type").inspect}. " \
          "Seed from a captured gRPC call, or mark bytes with §…§ to fuzz them raw")
      end
      if Proxy::H2::Grpc.web_text?(GrpcVerdict.content_type(baseline))
        raise GrpcFieldError.new(
          "grpc-web-text carries its frames base64-encoded on the wire, so re-encoding one " \
          "field means decode/re-encode of the whole body — gori will not rewrite that much " \
          "of a capture. Sweep it with §…§ byte positions instead")
      end
      if (residual = GrpcVerdict.residual(baseline)) != 0
        raise GrpcFieldError.new(
          "this template's gRPC body does not frame cleanly — #{Proxy::H2::Grpc.framing_error(residual)}. " \
          "A seed that is already mis-framed is your own parser test, and re-encoding a field " \
          "would repair it; sweep it with §…§ byte positions instead")
      end
      body = GrpcVerdict.body(baseline)
      unless body && !body.empty?
        raise GrpcFieldError.new("this template declares gRPC but carries no body to read a message out of")
      end
      msgs, _ = Proxy::H2::Grpc.scan(body)
      unless msgs.size == 1
        raise GrpcFieldError.new(
          "a gRPC field position is unary-only: this body carries #{msgs.size} messages. " \
          "Which message a payload belongs to has no answer left in the bytes of a streaming " \
          "body, so gori refuses rather than picks one")
      end
      msg = msgs[0]
      if msg.compressed
        raise GrpcFieldError.new(
          "this message's frame flag says the payload is COMPRESSED, and compressed bytes are " \
          "not a protobuf message until something inflates them — which gori does not. " \
          "The same carve-out the Repeater's ␣E form and every other gRPC pane make")
      end
      if msg.trailer
        raise GrpcFieldError.new("this frame is a grpc-web TRAILER frame (header text), not a protobuf message")
      end
      unless body[0] == 0_u8
        raise GrpcFieldError.new(
          "this message's frame flag byte is 0x#{body[0].to_s(16).rjust(2, '0')}, and the two bits " \
          "`Grpc.frame` composes a flag out of — compressed (0x01) and grpc-web trailer (0x80) — " \
          "are both refused above. What is left is a bit gori cannot re-emit, and it will not " \
          "silently normalize a byte the producer meant (P7). Sweep it with §…§ byte positions instead")
      end
      refuse_body_positions(baseline, baseline_spans, body.size)
      {msg, body.size}
    end

    # The specs resolved against the seed message, and the composite around them.
    private def self.assemble(base : Template, specs : Array(String),
                              binding : Protobuf::Schemas::Binding,
                              msg : Proxy::H2::Grpc::Message, body_size : Int32) : GrpcFieldTemplate
      decoded = Protobuf.decode(msg.data)
      fields = specs.map { |raw| resolve(binding.schema, binding.type, decoded, raw) }
      refuse_duplicate_paths(fields)

      positions = [] of Template::Position
      cursor = 0
      # `Position#index` is written at parse time and read nowhere in `src/` — every consumer
      # indexes the array instead — so re-stamping it with the global index is free and keeps
      # the record honest for anything that later does read it. Same as `WsScript.build`.
      base.positions.each do |p|
        positions << Template::Position.new(cursor, p.default, p.chain)
        cursor += 1
      end
      fields.each do |f|
        positions << Template::Position.new(cursor, f.seed, f.chain)
        cursor += 1
      end
      new(base, fields, positions, binding.schema, binding.method.path,
        binding.type.full_name, msg.data.dup, body_size)
    end

    # A `§…§` position whose splice point lands in the gRPC BODY cannot combine with a field
    # position, and the run is refused rather than one of them silently dropped.
    #
    # Both write the same octets: the field splice rebuilds the message from the CAPTURE's
    # bytes (P7), so a byte position's payload inside it would be discarded — and `--auto` can
    # make one without anybody asking. `Template.mark_body`'s urlencoded sniff wants only an
    # `=` and no newline, which a protobuf payload carrying byte 0x3D satisfies by accident;
    # `auto_mark_payload` already carries that scar for WebSocket BIN frames. So the operator
    # would watch a marked position do nothing, under a clean run.
    private def self.refuse_body_positions(baseline : Bytes,
                                           spans : Array({Int32, Int32}), body_size : Int32) : Nil
      head_size = baseline.size - body_size
      inside = spans.each_with_index.select { |(span, _)| span[0] >= head_size }.map { |(_, k)| k }.to_a
      return if inside.empty?
      raise GrpcFieldError.new(
        "position#{inside.size == 1 ? "" : "s"} #{inside.map { |k| k + 1 }.join(", ")} " \
        "(§…§ in the gRPC message body) cannot combine with a field position: the message is " \
        "rebuilt from the capture's own octets, so those payloads would never reach the wire. " \
        "Sweep the body by bytes or by fields, not both — and if you did not mark it yourself, " \
        "an auto-marking pass can carve a position out of a protobuf payload that happens to " \
        "carry an `=`")
    end

    # Two specs naming the SAME occurrence would splice twice into one span, and the second
    # would win silently while the sweep reported two positions.
    private def self.refuse_duplicate_paths(fields : Array(GrpcFieldPosition)) : Nil
      seen = {} of String => String
      fields.each do |f|
        key = f.path.join('.')
        if prior = seen[key]?
          raise GrpcFieldError.new(
            "#{f.spec.inspect} and #{prior.inspect} name the same field occurrence — " \
            "two positions over one span would sweep only the last one")
        end
        seen[key] = f.spec
      end
    end

    # --- resolving one spec ----------------------------------------------------

    # `profile.age`, `tags[1]`, `9`, `role¦base64`. A segment is a declared field NAME or a
    # field NUMBER, plus an optional 0-based `[occurrence]` for a field that occurs more than
    # once. `.` is safe as the separator: a protobuf field name is `[A-Za-z_][A-Za-z0-9_]*`.
    def self.resolve(schema : Protobuf::Schema, type : Protobuf::Schema::MessageType,
                     msg : Protobuf::Message, raw : String) : GrpcFieldPosition
      spec, chain = split_chain(raw)
      segments = parse_spec(spec)
      descend(schema, type, msg, segments, [] of Int32, spec, chain)
    end

    # Split `role¦base64` at the first `¦`, the same delimiter `§value¦chain§` uses —
    # so a chain reads the same however the position was declared, and `Template
    # .apply_chains_reported` (which every surface's chains go through) is the one author of
    # both the transform and its failure sentence. No `¦¦` escape, unlike a marker interior: a
    # protobuf field name is `[A-Za-z_][A-Za-z0-9_]*` and a path segment adds only `.` and
    # `[i]`, so the left side can never legitimately carry one.
    private def self.split_chain(raw : String) : {String, String}
      i = raw.index(Template::CHAIN_SEP)
      return {raw.strip, ""} unless i
      {raw[0, i].strip, raw[(i + 1)..].strip}
    end

    private record Segment, key : String, occurrence : Int32?

    private def self.parse_spec(spec : String) : Array(Segment)
      if spec.empty?
        raise GrpcFieldError.new("an empty field spec names nothing — use a field name (`role`), " \
                                 "a path into a nested message (`profile.age`), or a field number (`3`)")
      end
      parts = spec.split('.')
      if parts.size > MAX_SPEC_SEGMENTS
        raise GrpcFieldError.new("#{spec.inspect} nests #{parts.size} deep — past the #{MAX_SPEC_SEGMENTS} a field spec takes")
      end
      parts.map do |part|
        s = part.strip
        raise GrpcFieldError.new("#{spec.inspect} has an empty path segment") if s.empty?
        open = s.index('[')
        next Segment.new(s, nil) unless open && s.ends_with?(']')
        key = s[0, open].strip
        idx = s[(open + 1)...(s.size - 1)].to_i?
        unless !key.empty? && idx && idx >= 0
          raise GrpcFieldError.new("#{s.inspect}: an occurrence selector is `name[0]`, `name[1]`, … (0-based)")
        end
        Segment.new(key, idx)
      end
    end

    # One level of the walk. Reads every field through `Protobuf::Lens.read` — the SAME call
    # the Repeater's `␣E` form reads its rows through — so "which fields exist, and which of
    # them can carry a typed value" has exactly one author.
    private def self.descend(schema : Protobuf::Schema, type : Protobuf::Schema::MessageType,
                             msg : Protobuf::Message, segments : Array(Segment),
                             path : Array(Int32), spec : String, chain : String) : GrpcFieldPosition
      seg = segments.first
      matches = [] of {Int32, Protobuf::Field, Protobuf::Lens::Reading?}
      msg.fields.each_with_index do |f, i|
        r = Protobuf::Lens.read(schema, type, f)
        # By declared NAME, or by the wire's field NUMBER — which is the only handle an
        # UNDECLARED field has, and naming one has to reach the refusal that says so rather
        # than "no such field".
        next unless r.try(&.defn.name) == seg.key || f.number.to_s == seg.key
        matches << {i, f, r}
      end
      if matches.empty?
        raise GrpcFieldError.new(
          "#{spec.inspect}: #{type.full_name} carries no field #{seg.key.inspect} on this message — " \
          "it has #{menu(type, msg)}")
      end
      occ = seg.occurrence || 0
      chosen = matches[occ]?
      unless chosen
        raise GrpcFieldError.new(
          "#{spec.inspect}: #{seg.key.inspect} occurs #{matches.size} time#{matches.size == 1 ? "" : "s"} " \
          "on this message, so [#{occ}] is out of range (0..#{matches.size - 1})")
      end
      i, f, r = chosen
      here = path + [i]
      if segments.size > 1
        # A path segment that is not a container. An UNDECLARED one gets the same sentence the
        # leaf would give it — "the schema does not declare field N" is the fact, and it is the
        # fact whether the operator stopped there or tried to descend through it.
        raise undeclared_error(f, type, spec) unless r
        nested = r.nested
        unless nested
          raise GrpcFieldError.new(
            "#{spec.inspect}: #{seg.key.inspect} is declared #{r.defn.type_label}, not a message — " \
            "there is nothing to descend into")
        end
        inner = f.message || Protobuf.decode(f.bytes || Bytes.empty)
        return descend(schema, nested, inner, segments[1..], here, spec, chain)
      end
      leaf(schema, type, f, r, here, spec, chain)
    end

    # The three outcomes `Protobuf::Lens` decides, applied to a fuzz POSITION rather than to a
    # form row. Two of them are refusals here for the same reason they are read-only there.
    private def self.leaf(schema : Protobuf::Schema, type : Protobuf::Schema::MessageType,
                          f : Protobuf::Field, r : Protobuf::Lens::Reading?,
                          path : Array(Int32), spec : String, chain : String) : GrpcFieldPosition
      raise undeclared_error(f, type, spec) unless r
      d = r.defn
      if r.disagrees
        raise GrpcFieldError.new(
          "#{spec.inspect}: #{r.note} — re-encoding here would mean picking the schema over the " \
          "bytes, which is the guess the lens exists to avoid (the Repeater's ␣E form keeps this " \
          "row read-only for the same reason). Mark its octets with §…§ to fuzz them raw")
      end
      if r.nested
        raise GrpcFieldError.new(
          "#{spec.inspect}: #{d.name} is a #{d.type_label} — name a field inside it " \
          "(#{spec}.<field>), or mark its octets with §…§")
      end
      packed = f.wire.length_delimited? && d.repeated && d.type.packable?
      seed = Protobuf::Encoder.seed(d, f, r)
      unless seed
        raise GrpcFieldError.new(
          "#{spec.inspect}: #{r.note || "this field has no single-line value form"} — a payload " \
          "typed over it would not round-trip the bytes that are there. Mark its octets with §…§")
      end
      GrpcFieldPosition.new(spec, path, d, seed, chain, packed)
    end

    # A field number the message type does not declare. ONE sentence, raised from both the
    # descend step and the leaf, because it is the same fact in both places: there is no
    # declaration to encode a typed payload by. #837 renders that row read-only for exactly this
    # reason and points at `^X`; the headless twin of `^X` is a `§…§` over the octets.
    private def self.undeclared_error(f : Protobuf::Field, type : Protobuf::Schema::MessageType,
                                      spec : String) : GrpcFieldError
      GrpcFieldError.new(
        "#{spec.inspect}: the schema does not declare field #{f.number} of #{type.full_name} — " \
        "there is no declaration to encode a typed payload by. Its octets are still yours: " \
        "mark them with §…§ to fuzz them raw")
    end

    # The declared names present ON THIS MESSAGE (not every name the type declares): a field the
    # capture does not carry has no occurrence to replace, so offering it would be a dead end.
    private def self.menu(type : Protobuf::Schema::MessageType, msg : Protobuf::Message) : String
      seen = [] of String
      msg.fields.each do |f|
        label = type.field?(f.number).try(&.name) || "#{f.number} (undeclared)"
        seen << label unless seen.includes?(label)
      end
      return "no fields at all" if seen.empty?
      shown = seen.first(MENU_MAX).join(", ")
      seen.size > MENU_MAX ? "#{shown}, … (#{seen.size} in all)" : shown
    end

    # --- the value vector (the `Template` shape `Generator` reads) --------------

    def position_count : Int32
      @positions.size
    end

    def default_payloads : Array(String)
      @positions.map(&.default)
    end

    def apply_chains(payloads : Array(String), registry : Decoder::Registry) : Array(String)
      apply_chains_reported(payloads, registry).map(&.[0])
    end

    # Through `Template`'s class-method form, so a `¦chain` behaves identically on a field
    # position and on a byte one and the failure sentence has a single author.
    def apply_chains_reported(payloads : Array(String),
                              registry : Decoder::Registry) : Array({String, String?})
      Template.apply_chains_reported(@positions, payloads, registry)
    end

    # BASE positions only. A field position is not a query string or a form body, and
    # percent-encoding a payload on its way into an `int32` would turn a number into text the
    # declaration cannot hold — refused, for a default nobody asked for. (`AutoEncode.build`
    # is handed the base `Template` in `Plan.build`, so this is belt and braces.)
    def urlencoded_positions : Array(Int32)
      @base.urlencoded_positions
    end

    # --- rendering one variation ----------------------------------------------

    # `{request bytes, this variation's payload spans, the first field that could not be
    # encoded from this variation's payload}`.
    #
    # The base template's spans need no shifting: every `§…§` position is in the head (`build`
    # refuses one in the body) and the head is written first, unchanged. The MESSAGE is one
    # further span, appended — see the note under `splice`'s call below.
    #
    # A field whose payload the declaration cannot hold leaves that field at whatever it
    # currently is — for the first failure, the CAPTURE's own octets — and returns the reason.
    # The same contract a failed `¦chain` has (`Template#apply_chains_reported`): the request
    # still goes out, it is a different request than the operator declared, and the reason
    # rides out with it so no surface reports it under `0 errors`. Plan-time preflight
    # (`refuse_unencodable`) is what keeps this path rare; it is not allowed to be silent.
    def render_spans(payloads : Array(String)) : {Bytes, Array({Int32, Int32}), String?}
      n = @base.position_count
      raw, spans = @base.render_spans(payloads[0, Math.min(n, payloads.size)])
      msg = @message
      error = nil.as(String?)
      @fields.each_with_index do |fp, k|
        text = payloads[n + k]? || fp.seed
        case encoded = Protobuf::Encoder.encode(@schema, fp.defn, text, packed: fp.packed?)
        in String
          error ||= "field #{fp.spec}: #{encoded}"
        in Bytes
          case replaced = Protobuf::Encoder.replace(msg, fp.path, encoded)
          in String then error ||= "field #{fp.spec}: #{replaced}"
          in Bytes  then msg = replaced
          end
        end
      end
      bytes, message = splice(raw, msg)
      # The whole gRPC message, marked as PAYLOAD provenance beside the head's own spans.
      #
      # `Job#payload_spans` is what keeps `Fuzz::Sender` from rewriting a payload at the send
      # seam: `Env.expand_bindings` scans the whole request by design, so without an exclusion a
      # payload of `$SESSION` goes out as the live session credential instead of as those eight
      # characters — a different test, silently. A typed field's payload has no span of its own
      # here (it is octets inside a re-encoded message, and `Encoder.replace` does not report
      # where it landed), so the exclusion is drawn around the message: with a field position in
      # play the body is capture bytes plus typed payloads and nothing else — `build` refuses a
      # `§…§` inside it — so there is no third population in there whose `$NAME` anyone authored.
      {bytes, spans + [message], error}
    end

    # `{the request, the framed message's `[start, end)` in it}`. The head as rendered, then the
    # message re-framed by `Proxy::H2::Grpc.frame` — the framer the Repeater's `␣F:FRAME` path
    # is built on, whose flag byte is `0x00` here because `build` refuses any other one.
    private def splice(raw : Bytes, msg : Bytes) : {Bytes, {Int32, Int32}}
      # The body is byte-constant in SIZE across variations of the BASE template (every `§…§` is
      # in the head), so the head is everything before the last `@body_size` bytes. Exact, and
      # immune to a header payload that itself carries a CRLFCRLF — which re-finding the
      # head/body boundary per render would not be.
      head_size = {raw.size - @body_size, 0}.max
      framed = Proxy::H2::Grpc.frame(false, msg)
      io = IO::Memory.new(head_size + framed.size)
      io.write(raw[0, head_size])
      io.write(framed)
      {io.to_slice, {head_size, head_size + framed.size}}
    end

    # --- plan-time preflight ---------------------------------------------------

    # Refuse a run whose payloads the declared type cannot hold, BEFORE the first dial.
    #
    # `Plan.refuse_unusable_chains` argues the general case one screen away and explains why it
    # does NOT dry-run a chain over a payload: a raise there cannot tell "this converter is
    # broken" from "this converter is fine and this value is not valid input for it". A typed
    # field has no such ambiguity — an `int32` declaration can never hold `abc`, whatever else
    # is true — so the dry run is exactly the right instrument, and running it here is what
    # turns ten thousand identical send-time failures into one sentence up front.
    #
    # `sets` is the generator's own set list and the mapping mirrors `Generator#set_for`, so
    # the payloads checked are the payloads that position will actually receive.
    def refuse_unencodable(sets : Array(PayloadSet), base_count : Int32,
                           registry : Decoder::Registry) : Nil
      return if sets.empty?
      @fields.each_with_index do |fp, k|
        set = sets[base_count + k]? || sets[0]
        checked = 0
        set.each do |raw|
          break if checked >= PREFLIGHT_MAX
          checked += 1
          value = fp.chain.empty? ? raw : Template.apply_chains_reported(
            [Template::Position.new(0, raw, fp.chain)], [raw], registry)[0][0]
          encoded = Protobuf::Encoder.encode(@schema, fp.defn, value, packed: fp.packed?)
          next unless encoded.is_a?(String)
          raise GrpcFieldError.new(
            "field #{fp.spec} is #{fp.defn.type_label} and cannot hold payload " \
            "#{raw.inspect}: #{encoded}. A sweep's refusals have to arrive before the first " \
            "dial, so the run stops here — narrow the payload set, or mark the field's octets " \
            "with §…§ to fuzz them raw")
        end
      end
    end
  end
end
