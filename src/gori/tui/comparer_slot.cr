require "./url"
require "./theme"
require "../store/models"
require "../repeater/message_lines"
require "../repeater/exchange_meta"

module Gori::Tui
  # ONE side of a Comparer comparison.
  #
  # A slot used to BE a `Store::FlowDetail`, which is why the tab could only ever diff two
  # CAPTURED flows: the flow picker and History's handoff are the only two things in the tree
  # that hand one over. A Repeater send, a Fuzz result and a Sitemap endpoint all hold the
  # same two messages and no flow row to wrap them in, so none of them could reach the
  # Comparer at all — the operator had to find the capture the send happened to leave behind
  # (and a Repeater/WS/gRPC tab leaves none: those are session-only, `db_id` nil).
  #
  # So a slot is the BYTES plus whatever labelling the source can supply, and `from_flow` is
  # one constructor among several. The meta readout (status · size · time) rides here too:
  # it is per-side data, and every source that can name its bytes can name those as well.
  class ComparerSlot
    getter label : String  # short chip text: "GET /path", or what the source called these bytes
    getter method : String # sub-tab filter subject (`method:`)
    getter target : String # full URL when known — the sub-tab filter's `host:` subject
    getter host : String   # authority alone, for the header summary
    getter path : String   # origin-form path, for the header summary
    # Where these bytes came from, when it is not the capture history: "repeater", "fuzz", …
    # Shown as a header prefix so an A/B pair of a captured flow against a live re-send says
    # which side is which — the two otherwise render identically.
    getter source : String?
    # status · size · time — the shared value every surface states (see `Repeater::ExchangeMeta`).
    getter meta : Repeater::ExchangeMeta
    getter flow_id : Int64? # the capture this came from, when it came from one
    # The SOURCE named these bytes itself, rather than `label` being the method + path
    # rebuilt. It matters to `summary`: a source whose rows share one target — a fuzz run,
    # where every row is "GET /api" — cannot be told apart by the derived name, so the name
    # it DID supply has to ride the A/B header too and not just the sub-tab chip.
    getter named : Bool

    def initialize(@label, @method, @target, @host, @path, @meta, *,
                   @source = nil, @flow_id = nil, @named = false,
                   @request_head : Bytes? = nil, @request_body : Bytes? = nil,
                   @response_head : Bytes? = nil, @response_body : Bytes? = nil,
                   @error : String? = nil, @text : Array(String)? = nil)
      @req_lines = nil.as(Array(String)?)
      @resp_lines = nil.as(Array(String)?)
    end

    # A captured flow — the original (and still the most common) slot source.
    def self.from_flow(d : Store::FlowDetail) : ComparerSlot
      row = d.row
      new(
        "#{row.method} #{Url.origin_path(row.target)}",
        row.method, row.url, row.host, Url.origin_path(row.target),
        Repeater::ExchangeMeta.of(row), flow_id: row.id,
        request_head: d.request_head, request_body: d.request_body,
        response_head: d.response_head, response_body: d.response_body, error: d.error)
    end

    # A live exchange that was never captured as a flow: a Repeater send, a Fuzz result.
    # `status`/`duration_us` come from the sender, which measured them; the size is the
    # response body it actually holds.
    def self.from_exchange(source : String, method : String, url : String,
                           request_head : Bytes?, request_body : Bytes?,
                           response_head : Bytes?, response_body : Bytes?, *,
                           status : Int32? = nil, duration_us : Int64? = nil,
                           error : String? = nil, flow_id : Int64? = nil,
                           size : Int64? = nil, label : String? = nil) : ComparerSlot
      host, path = split_url(url)
      # `label` overrides the method+path chip for a source whose rows are not told apart by
      # their target — every row of a fuzz run shares one, and the payload is what names it.
      # `size` likewise overrides the held body's length: a sender that measured the response
      # knows how long it was even when it kept no bytes (a fuzz run without `keep bodies`),
      # and 0 B would be a claim about the origin that nothing observed.
      meta = Repeater::ExchangeMeta.of(status, size || response_body.try(&.size.to_i64), duration_us, error)
      new(label || "#{method} #{path}", method, url, host, path, meta,
        source: source, flow_id: flow_id, named: !label.nil?,
        request_head: request_head, request_body: request_body,
        response_head: response_head, response_body: response_body, error: error)
    end

    # Raw text with no HTTP shape at all — a paste, a decoder output. It has no request
    # half and no response half, so the SAME lines answer for both: a text slot is a
    # constant under the REQ ⇄ RES toggle rather than going blank on one of them.
    def self.from_text(label : String, text : String) : ComparerSlot
      lines = text.split('\n').map(&.rstrip('\r'))
      new(label, "", "", "", label,
        Repeater::ExchangeMeta.of(nil, nil, nil, nil),
        source: "text", text: lines)
    end

    # The display lines of the requested half. Memoized per half: a rebuild (rows +
    # syntax overlay) and a theme reshade must not re-decode/-scrub/-split the same body.
    def lines(pane : Symbol) : Array(String)
      if t = @text
        return t
      end
      if pane == :request
        @req_lines ||= Repeater::MessageLines.of(@request_head, @request_body, decode: false)
      else
        @resp_lines ||= Repeater::MessageLines.of(@response_head, @response_body, decode: true, error: @error)
      end
    end

    # Live, so a theme switch reshades a slot that was built under the old one.
    def status_color : Color
      return Theme.red if @meta.errored?
      Theme.status_color(@meta.status)
    end

    # Header line, left of the meta readout. The source prefix only appears when the bytes
    # did NOT come from the capture history.
    #
    # A source-supplied name leads, because it is the half that TELLS THE TWO SIDES APART and
    # the half a narrow column truncates away last: two rows of one fuzz run rendered as the
    # same "[fuzz] GET api.test/search" on both sides of a diff whose whole point was which
    # payload produced which response.
    def summary : String
      base = "#{@method} #{@host}#{@path}".strip
      base = @label if base.empty?
      base = "#{@label} · #{base}" if @named && @label != base
      (s = @source) ? "[#{s}] #{base}" : base
    end

    # The method of a raw request: the first token of its request line, "?" when there is
    # nothing that looks like one. Byte-level and bounded — the bytes are whatever an
    # operator or a fuzz payload put on the wire, so they need not be valid UTF-8 and need
    # not contain a newline at all.
    def self.method_of(request : Bytes?) : String
      return "?" if request.nil? || request.empty?
      n = {request.size, 64}.min
      i = 0
      while i < n
        b = request[i]
        break if b == 0x20u8 || b == 0x0du8 || b == 0x0au8
        i += 1
      end
      return "?" if i == 0 || i == n
      String.new(request[0, i]).scrub
    end

    # Authority + origin-form path of a URL, for the header summary. Falls back to the
    # whole string when it does not parse — an operator-supplied target need not be a URI,
    # and refusing to label it would be worse than labelling it verbatim.
    private def self.split_url(url : String) : {String, String}
      uri = URI.parse(url)
      h = uri.host
      return {"", url} if h.nil? || h.empty?
      auth = uri.port ? "#{h}:#{uri.port}" : h
      p = uri.path.empty? ? "/" : uri.path
      p = "#{p}?#{uri.query}" if uri.query
      {auth, p}
    rescue
      {"", url}
    end

    # The A→B delta line — see `Repeater::ExchangeMeta.delta`. Here as a two-slot shorthand
    # so the view does not have to reach through both slots to reach their meta.
    def self.delta(a : ComparerSlot, b : ComparerSlot) : String?
      Repeater::ExchangeMeta.delta(a.meta, b.meta)
    end
  end
end
