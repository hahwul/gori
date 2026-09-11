require "digest/sha256"
require "./store"
require "./env"
require "./url"
require "./proxy/codec/http1"
require "./repeater/flow_request"

module Gori
  # Frozen issue evidence (#1038): the exact bytes that proved a finding at a point in time,
  # taken FROM a mutable workbench object and kept where nothing on the workbench can reach
  # them again.
  #
  # Tags and Collections say how a session is organised, entity links say what is RELATED to
  # an issue, a retest says how to run the check again — and none of those keeps the
  # material the same. A linked Repeater tab's next send replaces its response; a linked
  # History flow is one retention sweep from gone; a stale link keeps the reference and
  # loses the bytes. This module builds the copy (`Snapshot`) from either live source, and
  # `Store#freeze_evidence` writes it in one transaction with the link.
  #
  # The copy carries its own provenance — source kind and id, the moment it was taken, and
  # a SHA-256 of what was stored — so a report can say what it was handed even after the
  # source is gone. Nothing here resolves back through the source.
  module Evidence
    # Ceiling on what one project's frozen evidence may hold, summed over `bytes`. Bodies
    # are already capture-capped per flow, so this bounds the COUNT of large snapshots, not
    # any one of them; `Store#freeze_evidence` refuses past it rather than evicting — an
    # eviction would be a retention sweep over the one table that exists to be exempt.
    QUOTA_BYTES = 256_i64 * 1024 * 1024

    # Above this a freeze is CONFIRMED with its byte cost shown, below it the copy just
    # happens. Most exchanges are a few KiB and asking about each would train the operator
    # to answer without reading; a multi-MiB download is the case the question is for.
    LARGE_BYTES = 1_i64 * 1024 * 1024

    # What a freeze writes — every fact the row keeps, computed ONCE here so the store, the
    # confirm dialog ("this will cost 3.2MB") and the toast all describe the same copy.
    #
    # `request_head`/`response_head` are the heads AS THE SOURCE HOLDS THEM, bodies likewise
    # (still chunked/compressed, P7); the viewer decodes for display the way every other pane
    # does. For a captured flow that is the wire form. For a Repeater tab it is the tab's
    # SAVED request — `$KEY` bindings unexpanded, no Authorize-slot overlay, exactly what
    # `repeaters.request` holds, because the tab keeps no request-as-sent — beside the last
    # response the store holds for it. The hashes cover these stored bytes.
    record Snapshot,
      source_kind : Store::LinkRefKind,
      source_id : Int64,
      method : String,
      url : String,
      protocol : String?,
      status : Int32?,
      duration_us : Int64?,
      error : String?,
      request_head : Bytes,
      request_body : Bytes?,
      response_head : Bytes?,
      response_body : Bytes?,
      request_truncated : Bool = false,
      response_truncated : Bool = false do
      def request_truncated? : Bool
        @request_truncated
      end

      def response_truncated? : Bool
        @response_truncated
      end

      # SHA-256 over head + body, exactly the bytes the row stores. Computed on demand —
      # a snapshot built only to show its byte cost in a confirm never pays for it.
      def request_sha256 : String
        Evidence.sha256(@request_head, @request_body)
      end

      # nil when there is no response at all (a send that errored before one arrived, a
      # pending flow), so a reader can tell "hashed to nothing" from "nothing to hash".
      def response_sha256 : String?
        head = @response_head
        return nil if head.nil? && @response_body.nil?
        Evidence.sha256(head || Bytes.empty, @response_body)
      end

      # What the row costs against QUOTA_BYTES: the four blobs. Text columns are noise
      # beside them and are not counted.
      def bytes : Int64
        @request_head.size.to_i64 + (@request_body.try(&.size) || 0) +
          (@response_head.try(&.size) || 0) + (@response_body.try(&.size) || 0)
      end

      # Has the source ever produced a response? A request-only copy is refused at the
      # surface for a Repeater (see `from_repeater`), but a captured flow that errored is
      # still evidence of the error and freezes with `error` set.
      def response? : Bool
        !@response_head.nil? || !@response_body.nil?
      end
    end

    # Which link kinds a snapshot can be taken from. A fuzz or miner session has no single
    # exchange — it is a template plus a run — so those links stay live-only.
    def self.freezable?(kind : Store::LinkRefKind) : Bool
      kind.flow? || kind.repeater?
    end

    # A captured flow, as History holds it. The flow's OWN facts (status, timing, protocol,
    # error, truncation flags) travel with the bytes rather than being re-derived from the
    # head, so an h2 flow keeps `HTTP/2` and an errored flow keeps its error string.
    def self.from_flow(d : Store::FlowDetail) : Snapshot
      row = d.row
      Snapshot.new(
        source_kind: Store::LinkRefKind::Flow,
        source_id: row.id,
        method: row.method,
        url: row.url,
        protocol: d.http_version,
        status: row.status,
        duration_us: row.duration_us,
        error: d.error,
        request_head: d.request_head,
        request_body: d.request_body,
        response_head: d.response_head,
        response_body: d.response_body,
        request_truncated: d.request_body_truncated?,
        response_truncated: d.response_body_truncated?,
      )
    end

    # A Repeater tab's saved request and the last response the STORE holds for it. nil when
    # the tab has never been sent — there is no exchange to freeze, and a request-only row
    # labelled as evidence of a response that never happened is exactly the misleading
    # artefact this feature exists to prevent. The caller says so and leaves the tab alone.
    #
    # Two facts about that pairing, both consequences of the `repeaters` row's shape and
    # named in the docs: the TUI and CLI persist a response only for a SUCCESSFUL send, so
    # after a failed re-send the copy carries the last good response (the pane shows the
    # error, the row does not); and the request is the tab's CURRENT saved text, so a request
    # edited since that send freezes beside the response of the earlier one. Freeze right
    # after the send that proved the finding, which is when the two agree.
    #
    # The request is one wire blob (`repeaters.request`, head and body together); it is
    # split at the blank line the way MCP's `split_wire_request` splits it, tolerating a
    # bare-LF head, and the head KEEPS its terminator — the shape `flows.request_head`
    # has, so the viewer and the hash treat both sources alike. The start line is read
    # leniently for the same reason.
    def self.from_repeater(rec : Store::RepeaterRecord) : Snapshot?
      resp_head = rec.response_head
      return nil if resp_head.nil? && rec.response_error.nil?
      boundary = Env.head_body_boundary(rec.request)
      req_head = rec.request[0, boundary]
      body_size = rec.request.size - boundary
      req_body = body_size > 0 ? rec.request[boundary, body_size] : nil
      method, target, version = Proxy::Codec::Http1.authored_start_line(req_head)
      # MCP's save-as-repeater path persists an errored send as an EMPTY head, and an empty
      # head is "no response", not a response of zero bytes.
      resp_head = nil if resp_head && resp_head.empty?
      status = resp_head.try { |h| Proxy::Codec::Http1.parse_response_head(h).status }
      status = nil if status == 0
      Snapshot.new(
        source_kind: Store::LinkRefKind::Repeater,
        source_id: rec.id,
        method: method.empty? ? "?" : method,
        url: repeater_url(rec.target, target),
        protocol: rec.http2? ? "HTTP/2" : (version.empty? ? nil : version),
        status: status,
        duration_us: rec.response_duration_us,
        error: rec.response_error,
        request_head: req_head,
        request_body: req_body,
        response_head: resp_head,
        response_body: resp_head ? rec.response_body : nil,
      )
    end

    # The snapshot for a live ref, or the sentence that says why there is none — the shared
    # answer for the headless surfaces (`gori run evidence freeze`, MCP `freeze_evidence`),
    # which refuse by name where the TUI toasts. A String, not a raise: none of these is an
    # error in the program, each is a fact about the project.
    def self.snapshot_for(store : Store, kind : Store::LinkRefKind, id : Int64) : Snapshot | String
      case kind
      when .flow?
        d = store.get_flow(id)
        return "no flow with id #{id} — it may have been pruned" unless d
        # A Pending flow has no exchange yet: the response is still in flight and will land
        # on this same row a moment later, so a copy taken now would say "no response" about
        # a request that got one — the Repeater's never-sent refusal, one source over.
        if d.row.state.pending?
          return "flow ##{id} has no response yet — wait for it to complete, then freeze the exchange"
        end
        from_flow(d)
      when .repeater?
        rec = store.get_repeater_full(id)
        return "no repeater with id #{id}" unless rec
        from_repeater(rec) || "repeater ##{id} has never been sent — send it first, then freeze the exchange"
      else
        "only a flow or a repeater exchange can be frozen (#{kind.label} sessions have no single exchange)"
      end
    end

    # `https://a.test/login` from a tab's target and its request-line target. An
    # absolute-form request target already IS the URL; an origin-form one is appended to the
    # ORIGIN the tab dials — `{scheme, host, port}` as `FlowRequest.parse_target` reads them,
    # not the target string verbatim, because the sender ignores any path typed there and a
    # tab whose target reads `https://a.test/api` still sends `GET /login` to `/login`;
    # anything else (`*`, an authority-form CONNECT) is shown beside it rather than glued on.
    def self.repeater_url(target_field : String, target : String) : String
      return target if Url.absolute_form?(target)
      scheme, host, port = Repeater::FlowRequest.parse_target(target_field)
      origin = host.empty? ? target_field : Repeater::FlowRequest.build_target(scheme, host, port)
      return "#{origin}#{target}" if target.starts_with?('/')
      target.empty? ? origin : "#{origin} #{target}"
    end

    def self.sha256(head : Bytes, body : Bytes?) : String
      d = Digest::SHA256.new
      d.update(head)
      d.update(body) if body
      d.hexfinal
    end

    # `GET a.test/login` — the RELATED row's identity: the copy's url without its scheme.
    # Close to `Links.resolve_flow`'s `method host+target`, not identical: the url keeps a
    # non-default port (`a.test:8443/x`) where the live row's label never carries one, and
    # for a copy that is the right side to err on — a report reads the port off it.
    #
    # `.scrub`, because the url is display text built from captured wire bytes and the TUI
    # funnels display text through `Hotkeys.retag`, whose regex raises on non-UTF-8.
    def self.label(meta : Store::IssueEvidenceMeta) : String
      u = meta.url
      if Url.absolute_form?(u) && (i = u.index("://"))
        u = u[(i + 3)..]
      end
      "#{meta.method} #{u}".scrub
    end
  end
end
