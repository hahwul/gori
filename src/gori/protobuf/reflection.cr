require "../outbound"
require "../proxy/h2/grpc"
require "../repeater/h2_engine"
require "./encoder"
require "./schema"

module Gori::Protobuf
  # gRPC **server reflection** as a schema source (#827): ask the target what it serves,
  # and hand the descriptors it returns to the same `Schema` a `protoc --descriptor_set_out`
  # file feeds (#823). The operator no longer has to produce a descriptor set by hand.
  #
  # ## What it is NOT allowed to be
  #
  # An outbound request gori makes on its own. Two rules hold this file:
  #
  #   * **P4 — the human decides.** Nothing here runs on capture, on opening a flow, or on
  #     project open. `fetch` is called from a verb, a `gori run grpc reflect` invocation, or
  #     an MCP `grpc_reflect` call, and from nowhere else. The CACHE is what a later flow
  #     reads; the network is touched only when someone asked.
  #   * **The outbound scope chokepoint.** `Outbound` is a required constructor argument
  #     (`Client.new`), exactly as it is on `Fuzz::Sender` / `Repeater::Sender`, and BOTH its
  #     layers run before the dialer is reached — Layer 1 (`check_request`, the surface's
  #     allowlist policy) and Layer 2 (`send_block`, Sandbox). A refused target produces a
  #     `refused?` Outcome and no socket.
  #
  # And P7 is unchanged by any of it: what comes back is a lens over captured bytes. An
  # undeclared field number still renders raw, and a wire/schema disagreement is still shown
  # as a disagreement — `Lens` decides that, and reflection changes nothing about how.
  #
  # ## Why not `Repeater::Sender`
  #
  # That class is documented as "the dial seam for a single HAND-AUTHORED send", and two of
  # the things it does at that seam are wrong for a request gori composed itself: it expands
  # `$NAME` bindings and overlays the active session slot into bytes no operator wrote, and
  # it offers the response to the binding table's extract rules (`Sender#extract`) — which
  # would let a descriptor blob rebind the operator's `$SESSION`. The GATE is the part that
  # must be shared, and it is: the same `Outbound`, the same two layers, asked about the
  # `:path` this fetch will actually route on. `Sender` derives that path from a synthesized
  # request line (`H2Engine.field_scope_line`) because its caller hands it opaque fields;
  # here gori WROTE the path, so it is passed straight in.
  #
  # ## The call shape
  #
  # `ServerReflectionInfo` is bidirectional streaming. gori writes every request of a round
  # into one stream, half-closes, and reads the replies in order — the request-then-close
  # shape every reflection client uses, and the only one `H2Engine`'s one-shot exchange can
  # express. Discovery therefore costs one stream per ROUND, not per symbol:
  #
  #   round 1  list_services
  #   round 2  file_containing_symbol × every service listed
  #   round 3+ file_by_filename × every `dependency` not yet held, until the import graph
  #            closes or `MAX_ROUNDS` stops it
  module Reflection
    extend self

    # The two service names, in the order they are tried. `v1` was standardized in 2023 and
    # `v1alpha` is still what most deployed servers expose — grpcurl and Postman try both for
    # the same reason. A server answering neither says so (see `Outcome#error`); it does not
    # fail silently.
    SERVICE_V1      = "grpc.reflection.v1.ServerReflection"
    SERVICE_V1ALPHA = "grpc.reflection.v1alpha.ServerReflection"

    def self.path(service : String) : String
      "/#{service}/ServerReflectionInfo"
    end

    # Every request-target a fetch may put on the wire — what the scope gate is asked about.
    def self.scope_paths : Array(String)
      [path(SERVICE_V1), path(SERVICE_V1ALPHA)]
    end

    # gRPC status 12. A server without the v1 service answers UNIMPLEMENTED (or, behind a
    # gateway that never routed the stream, a 404/501) — that, and only that, is what makes
    # gori try `v1alpha`. An UNAUTHENTICATED or PERMISSION_DENIED is a real answer from a
    # real reflection service and is reported, not retried under another name.
    UNIMPLEMENTED = 12

    # Dependency-closure rounds after `list_services`. `google/protobuf/*.proto` plus a
    # normal internal API closes in two or three; past this the graph is either cyclic in a
    # way the server is not resolving or deliberately unbounded.
    MAX_ROUNDS = 8

    # Descriptor files absorbed in total. Every `.proto` of a large monorepo's API surface
    # reachable through `--include_imports` is in the low hundreds.
    MAX_FILES = 512

    # Services asked about. A server listing more than this is not one an operator is
    # reading field names off; the cap is named in the outcome rather than silently applied.
    MAX_SERVICES = 256

    # Total descriptor bytes accepted. Mirrors `Schemas::MAX_FILE_BYTES`, and for the same
    # reason: past this it is not a descriptor set, and a hostile server should not be able
    # to make gori hold an unbounded blob (which would then be WRITTEN to the project DB).
    MAX_BYTES = 32 * 1024 * 1024

    # Symbols asked for per stream. One round's requests all go out before the half-close,
    # so this bounds the request body as well as the reply the server may produce.
    MAX_PER_ROUND = 256

    # What one `fetch` produced. `schema` is nil whenever `error` is set, and `error` is nil
    # on success — but `services`/`files` are filled in either way, because a fetch that got
    # three of four services and then failed has told the operator something.
    #
    # `descriptor_set` is the FileDescriptorSet gori SYNTHESIZED from the returned
    # FileDescriptorProtos — the bytes that get cached, byte-identical to what a
    # `protoc --descriptor_set_out` of the same files would produce modulo file order. It is
    # what makes "fetched descriptors resolve exactly as a file-loaded set does" true by
    # construction rather than by a parallel code path.
    record Outcome,
      schema : Schema? = nil,
      descriptor_set : Bytes? = nil,
      service : String = "",
      services : Array(String) = [] of String,
      files : Int32 = 0,
      notes : Array(String) = [] of String,
      error : String? = nil,
      refused : Bool = false,
      transport : Bool = false do
      # The failure was the CONNECTION, not the reflection service's answer — so the same
      # call may succeed later. What an agent surface turns into `retryable`, and the reason
      # `FailureKind` is a kind rather than a sentence prefix.
      def transport? : Bool
        transport
      end

      def ok? : Bool
        error.nil? && !schema.nil?
      end

      # The scope gate said no. Distinguished from every other failure because it is the one
      # a surface answers with `SCOPE_BLOCKED` and a remedy, not with a retry.
      def refused? : Bool
        refused
      end

      # The `v1` / `v1alpha` label for the settings row and the cache, or "" when neither
      # answered.
      def version : String
        return "" if service.empty?
        service == SERVICE_V1 ? "v1" : "v1alpha"
      end
    end

    # The descriptor files gathered so far, plus the import edges they declare.
    #
    # Every file is parsed exactly ONCE, when it arrives: `name` and `dependency` are read
    # off it there and kept. Re-deriving the missing set by re-decoding every held file each
    # round would parse the whole graph `MAX_ROUNDS` times — on a 32 MiB `--include_imports`
    # surface that is the difference between a fetch and a stall, and neither answer changes
    # between rounds.
    class Collected
      # name → octets, in first-seen order (Crystal Hash keeps insertion order), which is the
      # order they are written into the synthesized FileDescriptorSet.
      getter files = {} of String => Bytes
      # Every `dependency` any held file declares, first-seen order, deduplicated.
      getter deps = [] of String
      getter bytes : Int64 = 0_i64

      def size : Int32
        @files.size
      end

      def empty? : Bool
        @files.empty?
      end

      # Take one FileDescriptorProto. Returns false when it was already held (a file every
      # service imports comes back once per service) or when the byte ceiling stops it.
      def add(blob : Bytes) : Bool
        return false if @bytes + blob.size > MAX_BYTES
        m = Protobuf.decode(blob, max_depth: Schema::MAX_DEPTH)
        # A file whose name will not parse is kept under a synthetic key rather than dropped:
        # its message declarations are real, and the only thing lost is dependency matching.
        name = Schema.text(m, FILE_NAME) || "<unnamed ##{@files.size + 1}>"
        return false if @files.has_key?(name)
        @files[name] = blob
        @bytes += blob.size
        Schema.strings(m, FILE_DEPENDENCY).each do |d|
          @deps << d unless d.empty? || @deps.includes?(d)
        end
        true
      end

      # The imports no held file satisfies — the frontier the next round asks for.
      def missing : Array(String)
        @deps.reject { |d| @files.has_key?(d) }
      end

      def over_bytes?(blob : Bytes) : Bool
        @bytes + blob.size > MAX_BYTES
      end
    end

    # The reflection client for ONE target. `Outbound` first and positional, the shape every
    # active sender in this tree uses, so a caller cannot construct one without a scope
    # decision in hand.
    class Client
      getter scheme : String
      getter host : String
      getter port : Int32
      getter? verify : Bool
      getter sni : String?
      getter timeout : Time::Span?
      getter overrides : Gori::HostOverrides?

      def initialize(@outbound : Gori::Outbound, *, @scheme : String, @host : String,
                     @port : Int32, @verify : Bool = true, @sni : String? = nil,
                     @timeout : Time::Span? = nil, @overrides : Gori::HostOverrides? = nil)
      end

      # `host:port` as the cache keys it and as every surface prints it. The scheme rides
      # along because http (h2c) and https are different targets.
      def authority : String
        Repeater::H2Engine.authority(@host, @port, @scheme)
      end

      # The cache key: scheme + authority, so `https://api.test` and `http://api.test` are
      # two entries. A descriptor set is the server's word about ITSELF, and the plaintext
      # port of a host is not necessarily the same server as its TLS port.
      def target : String
        "#{@scheme}://#{authority}"
      end

      # Fetch this target's descriptors, or say why not. NEVER raises: a reflection failure
      # is a sentence on a status line, and the whole point of asking is that the answer may
      # be "this server does not do reflection".
      def fetch : Outcome
        if reason = refusal
          return Outcome.new(error: reason, refused: true)
        end
        run
      rescue ex
        Outcome.new(error: ex.message || "reflection failed")
      end

      # Why this target may not be reflected against, or nil to proceed. BOTH scope layers,
      # in the order `Outbound` defines them: Layer 1 is the surface's up-front policy
      # (MCP allowlists, `gori run` refuses a configured-but-unmatched target, the TUI waives
      # because the operator picked the row), Layer 2 is Sandbox and holds on every surface.
      #
      # Public so a caller can report the block in its own idiom BEFORE printing anything —
      # the same contract `Repeater::Sender#refusal` has. `fetch` re-checks regardless, so a
      # caller that forgets still cannot put a byte on the wire.
      def refusal : String?
        if verdict = blocked_verdict
          return "#{@scheme}://#{authority} is #{verdict.decision} — " \
                 "#{Gori::Outbound.remedy(verdict, nil)}"
        end
        # Layer 2, over BOTH paths for the reason `blocked_verdict` states.
        Reflection.scope_paths.each do |target_path|
          if reason = @outbound.send_block(@scheme, @host, target_path)
            return reason
          end
        end
        nil
      end

      # The Layer-1 verdict that refuses this fetch, or nil when Layer 1 allows it. Separate
      # from `refusal` so a surface with its own vocabulary for an up-front scope refusal
      # (MCP's `SCOPE_BLOCKED` + `allow_unscoped:true` remedy) can tell it apart from a
      # Layer-2 Sandbox stop, whose remedy is a different sentence entirely.
      #
      # BOTH reflection paths are asked, because the fallback may send either: an include rule
      # covering only `/grpc.reflection.v1/…` is not permission for the v1alpha stream, and
      # asking about only the path tried first would let the second walk past the rule.
      # Fail-closed — the stricter of the two answers wins.
      def blocked_verdict : Gori::Outbound::Verdict?
        Reflection.scope_paths.each do |target_path|
          verdict = @outbound.check_request(@scheme, @host, target_path)
          return verdict if verdict.blocked?
        end
        nil
      end

      # --- the discovery walk -------------------------------------------------

      private def run : Outcome
        notes = [] of String
        listed, service, failure = list_services(notes)
        if failure
          # `service` names WHICH reflection service produced this answer — the field MCP puts
          # in its error details, and the difference between "v1alpha said NOT_FOUND" and
          # "nothing answered at all".
          return Outcome.new(service: service, error: failure.message, notes: notes,
            transport: failure.transport?)
        end
        if listed.empty?
          return Outcome.new(service: service, notes: notes,
            error: "#{service} answered, but listed no services")
        end
        if listed.size > MAX_SERVICES
          notes << "#{listed.size} services listed — asked about the first #{MAX_SERVICES}"
          listed = listed.first(MAX_SERVICES)
        end

        held = Collected.new
        # `asked` names, in request order, what each reply answers — so an ErrorResponse can
        # be reported against the symbol/filename it refused rather than as a bare code. The
        # server replies in order on one stream, which is what makes the index meaningful.
        asked = listed.first(MAX_PER_ROUND)
        wanted = asked.map { |s| Request.symbol(s) }
        round = 0
        while !wanted.empty? && round < MAX_ROUNDS
          round += 1
          replies, failure = Reflection.exchange(self, service, wanted)
          # A round that fails after files are already in hand is reported as a note and the
          # walk stops: a partial import graph still resolves the methods whose files DID
          # arrive, and refusing to show them because the fourth round timed out is the
          # worse half of the trade.
          if failure
            if held.empty?
              return Outcome.new(service: service, services: listed, notes: notes,
                error: failure.message, transport: failure.transport?)
            end
            notes << "stopped after #{held.size} file#{held.size == 1 ? "" : "s"}: #{failure.message}"
            break
          end
          # A round that produced nothing NEW ends the walk: asking the same question again
          # gets the same answer, and this is the loop's only real termination guarantee
          # (a server may answer `file_by_filename: a.proto` with a file whose own `name` is
          # something else, which leaves `a.proto` missing forever).
          break unless absorb(replies, asked, held, notes)
          missing = held.missing
          break if missing.empty?
          if held.size >= MAX_FILES
            notes << "stopped at the #{MAX_FILES}-file limit with #{missing.size} import#{missing.size == 1 ? "" : "s"} unresolved"
            break
          end
          # Past MAX_PER_ROUND the remainder is not dropped — it is still missing next round,
          # and the round budget is what bounds the walk.
          asked = missing.first(MAX_PER_ROUND)
          wanted = asked.map { |n| Request.filename(n) }
        end
        if round >= MAX_ROUNDS && !held.missing.empty?
          notes << "stopped after #{MAX_ROUNDS} rounds with imports still unresolved"
        end

        if held.empty?
          return Outcome.new(service: service, services: listed, notes: notes,
            error: "#{service} listed #{listed.size} service#{listed.size == 1 ? "" : "s"} but returned no descriptors")
        end

        set = Reflection.descriptor_set(held.files.values)
        case parsed = Schema.parse(set)
        in String
          Outcome.new(service: service, services: listed, files: held.size, notes: notes,
            error: "the descriptors returned did not parse: #{parsed}")
        in Schema
          Outcome.new(schema: parsed, descriptor_set: set, service: service, services: listed,
            files: held.size, notes: notes)
        end
      end

      # Round 1, and the v1 → v1alpha fallback. Returns the service names, the reflection
      # service that answered, and the reason neither did.
      private def list_services(notes : Array(String)) : {Array(String), String, Failure?}
        none = [] of String
        first_failure = nil.as(Failure?)
        {SERVICE_V1, SERVICE_V1ALPHA}.each do |service|
          replies, failure = Reflection.exchange(self, service, [Request.list_services])
          if failure
            # Only "this server does not implement THIS version" falls through to the next
            # name. A connect failure, a timeout or a PERMISSION_DENIED is the answer.
            return {none, service, failure} unless failure.unimplemented?
            first_failure ||= failure
            notes << "#{service} is not implemented here — trying #{SERVICE_V1ALPHA}" if service == SERVICE_V1
            next
          end
          names = [] of String
          reply_error = nil.as(String?)
          replies.each do |m|
            if e = Reflection.error_response(m)
              reply_error ||= e
              next
            end
            Schema.submessages(m, LIST_SERVICES_RESPONSE).each do |lsr|
              Schema.submessages(lsr, SERVICE_RESPONSE).each do |svc|
                (n = Schema.text(svc, SERVICE_NAME)) && (names << n)
              end
            end
          end
          # A reflection service that answered with an ErrorResponse and nothing else is a
          # real answer and must not be retried under the other name.
          if names.empty? && reply_error
            return {none, service, Failure.new(reply_error, FailureKind::Answered)}
          end
          return {names.uniq, service, nil}
        end
        reason = first_failure ||
                 Failure.new("neither #{SERVICE_V1} nor #{SERVICE_V1ALPHA} answered on this target",
                   FailureKind::Answered)
        return {none, SERVICE_V1ALPHA, reason}
      end

      # Fold one round's replies into `held`. Returns false when the round produced no new
      # file at all — the loop must stop rather than ask the same question again.
      private def absorb(replies : Array(Protobuf::Message), asked : Array(String),
                         held : Collected, notes : Array(String)) : Bool
        added = 0
        replies.each_with_index do |m, i|
          if e = Reflection.error_response(m)
            # Named against the symbol/filename this reply answers, which is its position in
            # the request list — the server replies in order on one stream.
            notes << "#{asked[i]? || "?"}: #{e}"
            next
          end
          Schema.submessages(m, FILE_DESCRIPTOR_RESPONSE).each do |fdr|
            Schema.blobs(fdr, FILE_DESCRIPTOR_PROTO).each do |blob|
              break if held.size >= MAX_FILES
              if held.over_bytes?(blob)
                notes << "stopped at the #{MAX_BYTES // (1024 * 1024)} MiB descriptor limit"
                return added > 0
              end
              added += 1 if held.add(blob)
            end
          end
        end
        added > 0
      end
    end

    # --- one stream ------------------------------------------------------------

    # Why one stream ended without messages. A KIND alongside the sentence, not a prefix
    # inside it: two callers ask different questions of the same failure — the v1→v1alpha
    # fallback wants "is this server missing THIS service", and MCP wants "is this worth
    # retrying" — and a string test for either is a sentence-wording dependency waiting to
    # break the gate that reads it.
    enum FailureKind
      # The connection, the TLS handshake, the h2 exchange, a timeout. Nothing was learned
      # about the reflection service, and the same call may well succeed later.
      Transport
      # This server does not implement THIS reflection service (grpc-status 12, or a gateway's
      # 404/501). The ONLY thing that makes gori try the other service name.
      Unimplemented
      # The reflection service answered, and its answer was a refusal or an error — a real,
      # stable answer about this target.
      Answered
    end

    record Failure, message : String, kind : FailureKind do
      def transport? : Bool
        kind.transport?
      end

      def unimplemented? : Bool
        kind.unimplemented?
      end
    end

    # ServerReflectionResponse field numbers.
    FILE_DESCRIPTOR_RESPONSE = 4
    LIST_SERVICES_RESPONSE   = 6
    ERROR_RESPONSE           = 7
    # FileDescriptorResponse.file_descriptor_proto, ListServiceResponse.service,
    # ServiceResponse.name, ErrorResponse.error_code / error_message.
    FILE_DESCRIPTOR_PROTO = 1
    SERVICE_RESPONSE      = 1
    SERVICE_NAME          = 1
    ERROR_CODE            = 1
    ERROR_MESSAGE         = 2
    # FileDescriptorProto.name / .dependency.
    FILE_NAME       = 1
    FILE_DEPENDENCY = 3

    # Response messages read off one stream, or the sentence that ended it. Every request
    # of a round is written before the half-close, so the replies come back in request
    # order and the caller can name which symbol a reply answers.
    def exchange(client : Client, service : String,
                 requests : Array(Bytes)) : {Array(Protobuf::Message), Failure?}
      none = [] of Protobuf::Message
      body = IO::Memory.new
      requests.each { |r| body.write(Proxy::H2::Grpc.frame(false, r)) }
      result = Repeater::H2Engine.send_fields(fields(client, service), body.to_slice,
        scheme: client.scheme, host: client.host, port: client.port,
        verify_upstream: client.verify?, sni: client.sni,
        timeout: client.timeout, overrides: client.overrides)
      if err = result.error
        return {none, Failure.new(err, FailureKind::Transport)}
      end
      resp = result.response
      unless resp
        return {none, Failure.new("no response from #{client.authority}", FailureKind::Transport)}
      end
      # A gateway that never routed the stream answers in HTTP, not in gRPC. Reported as the
      # HTTP status, and counted as Unimplemented for the two codes that mean exactly "this
      # path is not served here" — a reverse proxy in front of a v1alpha-only server is the
      # ordinary shape of that.
      unless resp.status == 200
        kind = (resp.status == 404 || resp.status == 501) ? FailureKind::Unimplemented : FailureKind::Answered
        return {none, Failure.new("#{service} answered HTTP #{resp.status}", kind)}
      end
      if (code = grpc_status(resp)) && code != 0
        name = Proxy::H2::Grpc.status_name(code)
        message = resp.headers.get?("grpc-message")
        text = message && !message.empty? ? "#{name}: #{message}" : name
        kind = code == UNIMPLEMENTED ? FailureKind::Unimplemented : FailureKind::Answered
        return {none, Failure.new("#{service}: #{text}", kind)}
      end
      messages, residual = Proxy::H2::Grpc.scan_body(resp.headers.get?("content-type"), result.body || Bytes.new(0))
      if messages.empty?
        text = residual > 0 ? "#{service} answered with #{residual} bytes that are not gRPC frames" : "#{service} answered with no message"
        return {none, Failure.new(text, FailureKind::Answered)}
      end
      out = [] of Protobuf::Message
      messages.each do |msg|
        # gori advertises `grpc-accept-encoding: identity` and sends no `grpc-encoding`, so
        # a compressed reply is the server ignoring both. Said out loud rather than decoded
        # as protobuf, which would produce a tree of nonsense fields.
        if msg.compressed
          return {none, Failure.new(
            "#{service} returned a COMPRESSED message; gori asked for identity encoding and cannot inflate it",
            FailureKind::Answered)}
        end
        next if msg.trailer # grpc-web carries its trailers in-band; not a response message
        out << Protobuf.decode(msg.data, max_depth: Schema::MAX_DEPTH)
      end
      {out, nil}
    end

    # The HPACK field list for one ServerReflectionInfo stream. Written out in full rather
    # than derived from an h1 head: `send_fields` takes the fields verbatim, which is why
    # `:authority` is here explicitly (see `H2Engine.authority`).
    private def fields(client : Client, service : String) : Array({String, String})
      [
        {":method", "POST"},
        {":scheme", client.scheme},
        {":authority", client.authority},
        {":path", path(service)},
        {"content-type", "application/grpc+proto"},
        {"te", "trailers"},
        # gori has no gRPC decompressor on this path, so it must not advertise one.
        {"grpc-accept-encoding", "identity"},
        {"user-agent", "gori/#{Gori::VERSION} grpc-reflection"},
      ]
    end

    # `grpc-status` off the response head. h2 trailers are merged into the synthesized head
    # by `HeadCodec.synth_response`, so a normal trailers response and a Trailers-Only one
    # (grpc-status in the initial HEADERS — what an UNIMPLEMENTED method produces) are read
    # the same way here. nil when the server sent none, which is itself legal for a stream
    # gori cut short, and is then judged by whether messages arrived.
    private def grpc_status(resp : Proxy::Codec::RawResponse) : Int32?
      resp.headers.get?("grpc-status").try(&.strip.to_i?)
    end

    # ErrorResponse (field 7) as a sentence, or nil when this reply is not one.
    def error_response(m : Protobuf::Message) : String?
      Schema.submessages(m, ERROR_RESPONSE).each do |e|
        code = Schema.int32(e, ERROR_CODE) || 2_i64
        message = Schema.text(e, ERROR_MESSAGE)
        name = Proxy::H2::Grpc.status_name(code.to_i32)
        return message && !message.empty? ? "#{name}: #{message}" : name
      end
      nil
    end

    # --- descriptor bookkeeping -------------------------------------------------

    # `FileDescriptorProto.name` off raw octets — the key files are held under, and what a
    # spec asserts a returned blob actually is.
    def file_name(blob : Bytes) : String?
      Schema.text(Protobuf.decode(blob, max_depth: Schema::MAX_DEPTH), FILE_NAME)
    end

    # The FileDescriptorSet gori caches and parses: each FileDescriptorProto as field 1,
    # concatenated. That IS a FileDescriptorSet — `descriptor.proto` declares exactly one
    # repeated field there — so the bytes are indistinguishable from a `protoc
    # --descriptor_set_out` of the same files, and `Schema.parse` reads them by the one
    # code path #823 already validated.
    def descriptor_set(blobs : Array(Bytes)) : Bytes
      io = IO::Memory.new
      blobs.each { |b| io.write(Encoder.length_delimited(1_u32, b)) }
      io.to_slice
    end

    # --- ServerReflectionRequest -----------------------------------------------

    # The three request shapes gori sends. `host` (field 1) is deliberately LEFT EMPTY: it
    # is documented as the virtual host being asked about, every server ignores it, and
    # filling it in with the dial authority made servers behind a vhost router answer
    # NOT_FOUND for a service they serve.
    module Request
      extend self

      LIST_SERVICES          = 7
      FILE_CONTAINING_SYMBOL = 4
      FILE_BY_FILENAME       = 3

      # `list_services` is a string field whose value is ignored; the empty string is what
      # grpcurl sends and what the reference implementation tests against.
      def list_services : Bytes
        Encoder.length_delimited(LIST_SERVICES.to_u32, Bytes.new(0))
      end

      def symbol(name : String) : Bytes
        Encoder.length_delimited(FILE_CONTAINING_SYMBOL.to_u32, name.to_slice)
      end

      def filename(name : String) : Bytes
        Encoder.length_delimited(FILE_BY_FILENAME.to_u32, name.to_slice)
      end
    end
  end
end
