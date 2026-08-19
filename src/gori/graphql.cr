require "json"
require "uri"
require "./media_type"
require "./entity"

module Gori
  # Parses the GraphQL operation a flow carries — a POST JSON body
  # (`{query, operationName?, variables?}`) or a GET `?query=…` — into its operation
  # name, the un-escaped query document, and pretty-printed variables. A DISPLAY-time
  # projection (no table), the request-shaped sibling of `Gori::Sse`. (Pretty already
  # reflows a GraphQL POST body under the `p` toggle; this drives an always-on pane
  # and additionally handles the GET binding Pretty can't see.)
  module Graphql
    extend self

    MAX_BODY = 4 * 1024 * 1024

    # Which of the shapes a real GraphQL API exposes this request is in. Only two of them
    # were ever recognised — a POST JSON object with a `query`, and a GET `?query=` — so a
    # batched array, a persisted query, a multipart upload mutation and a raw
    # `application/graphql` document got NO decoded pane, no variables pretty-print and no
    # projection anywhere, which is precisely the set of shapes that carry the interesting
    # attacks (batching abuse / rate-limit bypass, persisted-query allowlist bypass, upload
    # mutations, content-type confusion).
    #
    # `Urlencoded` joined them late for the same reason: a `query=…&variables=…` body is what
    # express-graphql and Yoga accept alongside JSON, and it is the first thing reached for
    # when a JSON content-type is filtered — so the shape most likely to be a bypass attempt
    # was the shape gori showed as an ordinary form POST.
    #
    # The distinction is not cosmetic: it decides whether the Repeater may RE-ENCODE the
    # request from the edited pane, and each shape needs its OWN inverse. Json, Query and
    # Urlencoded round-trip an operationName + query + variables triple through three named
    # slots. Batch round-trips that same triple per indexed element back into the JSON array.
    # Document needs no inverse at all — the pane IS the body. Persisted has no document to
    # write back, so its pane is the JSON ENVELOPE itself and the inverse just re-minifies it,
    # which is how the extensions/persistedQuery block becomes editable without gori inventing
    # a `query` the client never sent.
    #
    # Multipart is the one parsed shape left display-only: the pane shows the `operations`
    # part of a body whose other parts (`map`, the file blobs, the boundaries) are not in it,
    # so writing the pane back would have to reconstruct bytes it never saw. See `editable?`.
    enum Form
      Json       # POST {"query": …}
      Query      # GET ?query=…
      Urlencoded # POST application/x-www-form-urlencoded: query=…&variables=…
      Batch      # POST [{"query": …}, …]
      Persisted  # POST {"extensions":{"persistedQuery":{…}}} — no document on the wire
      Multipart  # multipart/form-data upload mutation (GraphQL multipart request spec)
      Document   # Content-Type: application/graphql — the body IS the document
      Invalid    # GraphQL-carrying by Content-Type / body shape, but it did not parse
    end

    record Op,
      operation : String?, # operationName
      query : String,      # the GraphQL document (de-escaped)
      variables : String?, # pretty-printed JSON variables, or nil when absent
      form : Form = Form::Json,
      # Why this projection is not the operation (Form::Invalid only). A request that is
      # obviously GraphQL and did not parse must SAY so rather than vanish — reporting it as
      # "not GraphQL" is byte-identical to the answer for an ordinary REST call, and the
      # request most worth looking at is the malformed one. Same treatment gRPC got for a
      # framing failure.
      note : String? = nil,
      # The op was read out of a DECODED entity — the stored body was chunked or content-
      # encoded (`Gori::Entity`). The pane is then a projection of bytes the request does not
      # literally carry, so it is display-only however invertible its shape is: recomposing
      # plain JSON into an envelope whose head still declares `Content-Encoding: gzip` sends a
      # request the origin cannot read.
      projected : Bool = false,
      # A Batch whose display cannot be parsed back into what the array sent: at least one
      # element was a persisted query, so it renders as its own JSON envelope while its
      # siblings render as the query triple, and one pane cannot be read back as both. A
      # re-encode would have to drop or invent a document, so the whole batch stays read-only.
      # An all-documents batch — the shape a batching-abuse test actually builds — is
      # unaffected.
      lossy : Bool = false do
      # Whether `display(op)` → edit → the shape's `recompose*` can put the operator's edit
      # back into the exact request it came from. Every shape that HAS an inverse says yes,
      # but only when the bytes shown are the bytes sent (see `projected`) and the display can
      # be read back as everything that was sent (see `lossy`).
      #
      # Two shapes stay no. `Multipart` renders one part of a body whose other parts are not
      # on screen. `Invalid` has no parse to invert — its pane is the REASON the parse failed,
      # and writing that back would put an error message on the wire. Sending a request the
      # operator did not write is worse than a read-only pane, so for those two the projection
      # exists and the re-encode does not.
      def editable? : Bool
        return false if projected || lossy
        form.json? || form.query? || form.urlencoded? ||
          form.batch? || form.document? || form.persisted?
      end
    end

    # Parse the operation, or nil if the flow isn't GraphQL. Tries the POST JSON body
    # first, then the GET query string.
    #
    # The query-string fallback is NOT reached for a request that actually sent a body under a
    # method that reads one: there, the body IS the payload the server reads, so falling
    # through made any `POST /upload?query=%7Bx%7D` with an unrelated (even binary) body
    # report as GraphQL. That is not merely a wrong pane — `location` then answers `:query`,
    # so sending it from the Repeater re-encodes the whole query string, rewriting the
    # operator's request on the strength of a misdetection. A GET carrying a stray body still falls through, which is
    # what the fallback was written for.
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?) : Op?
      ct = MediaType.of(req_head)
      # The ENTITY, not the wire body: a gzip'd or chunked GraphQL POST is still a GraphQL
      # POST, and reading the wire form found neither an envelope nor a reason — the pane
      # simply was not offered, which is the answer an ordinary REST call gets. `projected`
      # then keeps the re-encode off bytes the envelope still holds compressed.
      entity, projected = Entity.of(req_head, req_body, MAX_BODY)
      if (b = entity) && !b.empty?
        if b.size <= MAX_BODY
          if op = from_body(b, ct)
            return projected ? op.copy_with(projected: true) : op
          end
        end
        # It did not parse. If the request is GraphQL-CARRYING by its Content-Type or by the
        # shape of its body, report the failure instead of deleting the view.
        if reason = unparsed_reason(b, ct)
          return Op.new(nil, "", nil, Form::Invalid, reason, projected)
        end
      end
      return nil if (b = entity) && !b.empty? && body_is_payload?(req_head)
      from_query(target)
    end

    # A body that opens as a GraphQL envelope: `{"query":` / `{"operationName":`, or a batch's
    # `[{"query":`, with the whitespace either side that a pretty-printed client emits.
    # Anchored, and only the first bytes are examined, so an ordinary JSON body that merely
    # CONTAINS the word never matches.
    #
    # `operationName` is in here because it is what the dominant client actually puts first:
    # Apollo Client serialises `{"operationName":…,"variables":…,"query":…}`, so a
    # `"query"`-only anchor recognised the envelope of every client EXCEPT the one most
    # requests come from — and the anchor is only ever consulted for a body that failed to
    # parse, i.e. a truncated or mangled envelope, which is the request most worth reporting.
    # `variables`/`extensions` are deliberately NOT accepted alone: neither is GraphQL-specific
    # enough to claim an unparseable REST body.
    ENVELOPE_RE = /\A\s*\[?\s*\{\s*"(?:query|operationName)"\s*:/

    # Whether the body's first bytes open as that envelope. Public because it is also the
    # cheap gate a caller needs BEFORE deciding to parse: `Pretty` sniffs bodies whose
    # content-type says nothing (`text/plain`, absent — the two a JSON-content-type filter is
    # bypassed with) and must not pay a megabyte-sized JSON parse for every one of them.
    def envelope_head?(body : Bytes?) : Bool
      b = body || return false
      return false if b.empty?
      head = String.new(b[0, {b.size, 256}.min]).scrub
      ENVELOPE_RE.matches?(head.lchop('\u{FEFF}'))
    end

    # Why a GraphQL-carrying request did not parse, or nil when it is not GraphQL-carrying at
    # all (an ordinary REST body, which must keep getting no GraphQL section).
    #
    # Deliberately narrow: a Content-Type the GraphQL-over-HTTP spec defines, or a body that
    # opens as the envelope. A `multipart/form-data` POST is NOT enough on its own — that is
    # every ordinary file upload — so it qualifies only once its `operations` part is present.
    private def unparsed_reason(body : Bytes, content_type : String?) : String?
      over = body.size > MAX_BODY
      if declared = declared_reason(body, content_type, over)
        return declared
      end
      return nil unless envelope_head?(body)
      return too_big if over
      # It opens as an envelope — but "opens like one" is not "is one". A body that PARSES as
      # JSON and was still rejected is an ordinary REST call carrying a string `query` field
      # (`{"query":"shoes","page":2}`), which must keep getting no GraphQL section at all;
      # only a body that does not parse is the truncated/mangled envelope worth reporting.
      return nil if json?(String.new(body))
      "the body opens as a GraphQL envelope but is not valid JSON"
    end

    # The half of `unparsed_reason` the CONTENT-TYPE decides: a request that declared itself
    # GraphQL and did not parse. nil means "the header did not claim it" — the caller then
    # falls back to the body's own shape. (Falling through is safe for the multipart branch
    # too: a multipart body opens with its boundary, never with a JSON envelope.)
    private def declared_reason(body : Bytes, content_type : String?, over : Bool) : String?
      case essence = MediaType.essence(content_type)
      when "application/graphql"
        over ? too_big : "Content-Type is application/graphql but the body carries no selection set"
      when "application/graphql+json", "application/graphql-response+json"
        # A content-type whose ONLY meaning is "this is GraphQL". Nothing else needs to hold:
        # whatever the body turned out to be, the request says it is a GraphQL envelope and
        # failed, and saying so is the point.
        over ? too_big : "Content-Type is #{essence} but the body is not a valid GraphQL envelope"
      else
        return nil unless MediaType.multipart?(content_type)
        boundary = MediaType.boundary(content_type) || return nil
        return nil unless multipart_part(body, boundary, "operations")
        over ? too_big : "the multipart `operations` part is not a valid GraphQL envelope"
      end
    end

    private def too_big : String
      "the body is larger than the #{MAX_BODY // (1024 * 1024)} MiB decode ceiling — " \
      "it may also have been cut at the capture cap"
    end

    # The request BODY's GraphQL projection, dispatched on Content-Type. The body used to be
    # JSON-parsed unconditionally, which is why `application/graphql` (a raw document, the
    # GraphQL-over-HTTP spec's other request form) and a multipart upload mutation could
    # never be GraphQL: neither body is JSON.
    def from_body(body : Bytes, content_type : String?) : Op?
      # Dispatch on the ESSENCE (media type, folded, parameters dropped), never on a prefix
      # of the raw value. `application/graphql` is a prefix of `application/graphql+json` and
      # of `application/graphql-response+json` — the two types a spec-conformant client sends
      # a perfectly ordinary JSON ENVELOPE under — so a `starts_with?` test fed those bodies
      # to the raw-document parser, which dutifully reported the whole JSON blob as the
      # "query" in a form nothing can re-encode. The request was GraphQL, the Repeater opened
      # it as a plain raw tab, and the pane showed an unparsed envelope.
      #
      # The multipart branch still gets the ORIGINAL spelling: a `boundary` parameter's value
      # is case-sensitive even though its media type is not.
      case MediaType.essence(content_type)
      when "application/graphql"
        from_document(String.new(body))
      when "application/x-www-form-urlencoded"
        from_urlencoded(String.new(body))
      else
        return from_multipart(body, content_type || "") if MediaType.multipart?(content_type)
        from_json(String.new(body))
      end
    end

    # `Content-Type: application/graphql` — the body IS the document, no JSON envelope
    # (GraphQL-over-HTTP). The `{` test is the same selection-set check the JSON path uses.
    #
    # The JSON envelope is tried FIRST, because clients mislabel this one constantly (it is
    # the type people reach for when they mean "GraphQL", and servers accept the envelope
    # under it): a body that parses as an envelope is an envelope whatever the header claims,
    # and reporting it as a raw document would cost the operator the editable pane. A genuine
    # GraphQL document is never valid JSON — its field names are unquoted — so this cannot
    # steal a real `application/graphql` body.
    private def from_document(body : String) : Op?
      if op = from_json(body)
        return op
      end
      doc = strip(body)
      return nil unless doc.includes?('{')
      Op.new(nil, doc, nil, Form::Document)
    end

    # `Content-Type: application/x-www-form-urlencoded` — `query=…&variables=…&operationName=…`,
    # the form body express-graphql / graphql-yoga accept alongside JSON. Same three named
    # slots as the GET binding, so `from_query`'s parser is reused verbatim and the shape
    # round-trips (see `recompose_form`).
    private def from_urlencoded(body : String) : Op?
      # Cheap gate before decoding every param: `Pretty` runs this on EVERY urlencoded body it
      # renders, and an ordinary login form should not pay a full percent-decode of its fields
      # to be told it is not GraphQL. A param merely ENDING in `query` also passes here — this
      # only decides whether to look, `from_params` decides the answer.
      return nil unless body.includes?("query=")
      op = from_params(www_form(strip(body))) || return nil
      Op.new(op.operation, op.query, op.variables, Form::Urlencoded)
    end

    # A GraphQL multipart request (the `operations`/`map`/`0…` upload convention): the
    # `operations` part carries the ordinary JSON envelope, so parse that and keep the form
    # so nothing tries to re-encode the multipart body from the pane.
    private def from_multipart(body : Bytes, content_type : String) : Op?
      boundary = MediaType.boundary(content_type) || return nil
      ops = multipart_part(body, boundary, "operations") || return nil
      op = from_json(ops) || return nil
      Op.new(op.operation, op.query, op.variables, Form::Multipart)
    end

    # The body of the multipart part named `name`, as text. Deliberately minimal: only the
    # `operations` part is read, and only to hand its JSON to the ordinary parser.
    private def multipart_part(body : Bytes, boundary : String, name : String) : String?
      text = String.new(body)
      needle = "name=\"#{name}\""
      text.split("--#{boundary}") do |part|
        next unless part.includes?(needle)
        sep = part.index("\r\n\r\n") || part.index("\n\n") || next
        skip = part[sep, 2] == "\r\n" ? 4 : 2
        return part[(sep + skip)..].rstrip("\r\n")
      end
      nil
    end

    # Whether a body this request carried is the payload the origin reads — so the `?query=`
    # fallback has nothing to fall back to. Read off the head, which `from_flow` has always
    # been handed and never looked at.
    #
    # A DENYLIST, not an allowlist of POST/PUT/PATCH: the two methods whose GraphQL binding is
    # the query string are GET and HEAD, and every other method that sent a body sent it to be
    # read. An allowlist left `QUERY` — the method GraphQL-over-HTTP defines for exactly this
    # request, and already in `InterceptFilter::METHOD_VAL` — plus `SEARCH`, a body-carrying
    # `DELETE` and every extension method answering `:query`, which splices the `Form::Invalid`
    # pane's parse-failure sentence into the request LINE (`unparsed_reason` has no method gate,
    # so those all reach it).
    #
    # nil (no head, as in a unit call) and a request line with no space at all keep the
    # permissive fallback: with no method to judge, the GET binding is still the only offer.
    private def body_is_payload?(req_head : Bytes?) : Bool
      head = req_head || return false
      line = String.new(head[0, {head.size, 64}.min])
      sp = line.index(' ') || return false
      case line[0, sp].upcase
      when "GET", "HEAD" then false
      else                    true
      end
    end

    # A POST JSON body. A GraphQL document always has a selection set, so requiring a
    # `{` in the query string avoids hijacking an ordinary REST body that happens to
    # carry a string `query` field (e.g. `{"query":"shoes"}`).
    #
    # A top-level ARRAY is a batched request — the shape a batching-abuse / rate-limit-bypass
    # test uses — and an object with no `query` but an `extensions.persistedQuery` is a
    # persisted query, which by definition sends no document at all. `json.as_h?` used to
    # reject the first and the `query` requirement the second, so neither was ever GraphQL.
    def from_json(body : String) : Op?
      from_json_any(JSON.parse(strip(body)))
    rescue
      nil
    end

    # The same sniff over an ALREADY-PARSED body. Exists so `Pretty` — which parses the JSON
    # once and pretty-prints it when it is not GraphQL — can ask THIS module the question
    # instead of carrying its own answer. It carried one, and the two drifted: Pretty knew
    # only the single `{"query":…}` object, so a batched or persisted-query body was
    # recognised by the decoded pane and pretty-printed as anonymous JSON right next to it.
    def from_json_any(json : JSON::Any) : Op?
      if arr = json.as_a?
        return from_batch(arr)
      end
      h = json.as_h? || return nil
      single_op(h)
    end

    # One JSON envelope object → its op. Returns nil for an object that is neither a
    # document-bearing request nor a persisted query.
    private def single_op(h : Hash(String, JSON::Any)) : Op?
      vars = h["variables"]?
      vars_text = (vars && !vars.raw.nil?) ? vars.to_pretty_json : nil
      name = h["operationName"]?.try(&.as_s?)
      if (q = h["query"]?.try(&.as_s?)) && q.includes?('{')
        return Op.new(name, q.strip, vars_text)
      end
      # No document. A `persistedQuery` extension says so explicitly — the server resolves
      # the hash to a stored document — and nothing else in the wild carries that key, so it
      # is a safe positive where a bare `{"variables":…}` would not be.
      return nil unless h["extensions"]?.try(&.as_h?).try(&.["persistedQuery"]?).try(&.as_h?)
      # The WHOLE envelope, not just the extension: the pane is the request now, not a
      # rendering of one, so what it holds is every field the server will read.
      Op.new(name, persisted_text(h), vars_text, Form::Persisted)
    end

    # The pane for a persisted query. There is no document to show and none to edit — the
    # server resolves a hash to a stored document — so the pane is the JSON ENVELOPE itself,
    # pretty-printed: the hash, its version, the operationName and the variables, which is
    # exactly the set of fields an allowlist-bypass test changes. `recompose_persisted`
    # re-minifies whatever comes back, so the operator edits the request rather than a
    # rendering of it and gori never has to invent a `query` the client did not send.
    #
    # The leading `#` line is not JSON; `recompose_persisted` drops the leading comment lines
    # before parsing. It earns the special case: a bare envelope under the GraphQL heading
    # reads as "gori failed to decode this", which is the answer this module exists to avoid.
    private def persisted_text(h : Hash(String, JSON::Any)) : String
      "# persisted query — no document was sent; this is the envelope, edit it directly\n" +
        h.to_pretty_json
    end

    # A batched request. Every element must be an object that is itself an op — one stray
    # element and this is not a GraphQL batch, and guessing would hijack an ordinary JSON
    # array body.
    private def from_batch(arr : Array(JSON::Any)) : Op?
      return nil if arr.empty?
      ops = [] of Op
      lossy = false
      arr.each do |item|
        h = item.as_h? || return nil
        op = single_op(h) || return nil
        lossy = true unless op.form.json? # a persisted element — see `Op#lossy`
        ops << op
      end
      Op.new(nil, batch_text(ops), nil, Form::Batch, lossy: lossy)
    end

    # The rendering of a batch: each operation in order, under its index, so the operator can
    # see how many calls one request carries and what each of them asks for. `# --- [i] ---`
    # is the sentinel `recompose_batch` splits the edited pane on, and it is always written
    # after a BLANK line — that is what tells it apart from a GraphQL comment that happens to
    # be spelled the same way, the disambiguation `# variables` and `# operationName:` get.
    private def batch_text(ops : Array(Op)) : String
      String.build do |io|
        io << "# batch of " << ops.size << " operation" << (ops.size == 1 ? "" : "s")
        ops.each_with_index do |op, i|
          io << "\n\n# --- [" << i << "] ---\n" << display(op)
        end
      end
    end

    # A GET `?query=…&operationName=…&variables=…` request.
    def from_query(target : String) : Op?
      idx = target.index('?') || return nil
      from_params(www_form(target[(idx + 1)..]))
    rescue
      nil
    end

    # `k=v&k=v` → a decoded map. ONE parser for the two bindings that use this grammar — a
    # GET query string and an `x-www-form-urlencoded` body are the same syntax, and a second
    # copy is a second set of edge cases (a valueless key, a `%`-sequence that will not
    # decode) for the two to disagree about.
    private def www_form(s : String) : Hash(String, String)
      params = {} of String => String
      s.split('&').each do |pair|
        k, sep, v = pair.partition('=')
        params[k] = (URI.decode_www_form(v) rescue v) unless sep.empty?
      end
      params
    end

    # The op carried by a decoded `{query, operationName, variables}` param map, in the
    # `Form::Query` shape; `from_urlencoded` re-stamps the form. Same selection-set guard as
    # the JSON path, so `?query=shoes` stays an ordinary search request.
    private def from_params(params : Hash(String, String)) : Op?
      q = params["query"]? || return nil
      return nil unless q.includes?('{')
      vars = params["variables"]?.try { |v| (JSON.parse(v).to_pretty_json rescue v) }
      Op.new(params["operationName"]?, q.strip, vars, Form::Query)
    end

    # The display text for a parsed op: an operationName header, the query, and the
    # variables block (each present only when set). This is the editable form shown in
    # the Repeater DECODED pane; parse_display is its inverse.
    def display(op : Op) : String
      # A failed parse has no document to show, so the pane shows WHY. Rendered here rather
      # than at each of the five call sites (History detail, the Fuzzer pane, `gori run show`,
      # `get_flow`, the Repeater's read-only view) so none of them can render an empty box.
      return "# GraphQL parse failed: #{op.note}" if op.form.invalid?
      # A persisted query's `query` slot already holds the WHOLE envelope (`persisted_text`),
      # operationName and variables included, so the triple layout below would render both of
      # them twice — once as a header/footer and once inside the JSON the pane edits. The Op
      # keeps the two fields set anyway because `decoded_view` reports them separately.
      return op.query if op.form.persisted?
      String.build do |io|
        if name = op.operation
          io << "# operationName: " << name << "\n\n"
        end
        io << op.query
        if v = op.variables
          io << "\n\n# variables\n" << v
        end
      end
    end

    # Parse the editable DECODED-pane text back into {operationName?, query, variables?}.
    # The variables block is whatever follows the LAST *genuine* `# variables` line; an
    # optional leading `# operationName:` header is lifted off; the rest is the query.
    #
    # `# variables` is ALSO a valid GraphQL source comment, so a comment line inside the
    # query could masquerade as the sentinel and truncate the query. Disambiguate on the
    # trailing block: the real sentinel is always followed by the variables JSON, whereas a
    # query comment is followed by more GraphQL — so only accept a `# variables` whose
    # remainder parses as JSON. This keeps an in-query `# variables` comment in the query.
    def parse_display(text : String) : {String?, String, String?}
      lines = text.split('\n')
      vi = nil.as(Int32?)
      # Scan BACKWARD for the last "# variables" whose remainder parses as JSON, breaking on the
      # first (from-end) match, and only attempt the parse when the trailing plausibly starts
      # with '{'/'[' — a forward re-join+parse per candidate is O(n²) on a query full of literal
      # "# variables" comment lines. `rev` holds the trailing lines in reverse (cheap push).
      rev = [] of String
      tail_first = nil.as(Char?) # first non-blank char of the accumulated trailing
      (lines.size - 1).downto(0) do |i|
        line = lines[i]
        if line.strip == "# variables" && (tail_first == '{' || tail_first == '[')
          trailing = rev.reverse.join('\n').strip
          if !trailing.empty? && json?(trailing)
            vi = i
            break
          end
        end
        rev << line
        if fnb = line.each_char.find { |c| !c.whitespace? }
          tail_first = fnb # a non-blank line becomes the new first-non-blank of the trailing
        end
      end
      vars = vi ? lines[(vi + 1)..].join('\n').strip : nil
      body = vi ? lines[0...vi] : lines
      op = nil.as(String?)
      first = body.index { |l| !l.strip.empty? }
      if first && body[first].strip.starts_with?("# operationName:") && blank_after?(body, first)
        op = body[first].strip.lchop("# operationName:").strip
        body = body[0...first] + body[(first + 1)..]
      end
      {op.try { |o| o.empty? ? nil : o }, body.join('\n').strip, (vars && !vars.empty?) ? vars : nil}
    end

    # Re-encode the edited DECODED pane back into a JSON request body, overlaying the
    # operationName/query/variables onto the ORIGINAL body so any other fields (e.g. a
    # persisted-query `extensions`) survive. Invalid edited variables fall back to the
    # original. Returns minified JSON (wire form).
    def recompose(envelope_body : String, decoded_text : String) : String
      base = (JSON.parse(strip(envelope_body)).as_h? rescue nil)
      overlay(base, *parse_display(decoded_text)).to_json
    end

    # One edited {operationName?, query, variables?} triple laid over the JSON object it came
    # out of. Extracted so the single envelope and each element of a BATCH cannot drift on the
    # two rules below — a batch is N of these, and re-deriving them per element is exactly how
    # "the deleted header means unset" would have come back only on the single-envelope path.
    private def overlay(base : Hash(String, JSON::Any)?, op : String?, query : String,
                        vars_text : String?) : Hash(String, JSON::Any)
      obj = {} of String => JSON::Any
      obj["operationName"] = JSON::Any.new(op) if op
      obj["query"] = JSON::Any.new(query)
      base_vars = base.try(&.["variables"]?)
      if vars_text
        obj["variables"] = (JSON.parse(vars_text) rescue base_vars || JSON::Any.new(vars_text))
      elsif base_vars
        obj["variables"] = base_vars
      end
      # Keep extensions etc. — but NOT `operationName`: the pane always renders it when it is
      # set, so an operator who deleted the header meant to unset it, and overlaying the base
      # back silently ignored the deletion. Absence here is a decision, not "unchanged".
      base.try &.each { |k, v| obj[k] = v unless obj.has_key?(k) || k == "operationName" }
      obj
    end

    # Re-encode the edited DECODED pane of a BATCH back into the JSON array. Each
    # `# --- [i] ---` block is one element, parsed by the same `parse_display` the single
    # envelope uses and laid over the ORIGINAL element at that index, so an element's other
    # fields survive exactly as they do for a lone envelope. Returns minified JSON.
    #
    # The index comes off the MARKER, not from the block's position, because the operator
    # edits the pane freely: deleting `[0]` leaves `[1]` sitting first, and overlaying the
    # original element 0 under it would graft element 0's `extensions` onto element 1's query.
    # A block whose marker names an index the original array does not have simply gets no base
    # — a batch the operator grew is a batch of exactly what they wrote.
    #
    # An edit that removed every marker is read as ONE operation rather than refused: the
    # blocks are the only structure the pane has, and a pane with none is a single document.
    # A pane that is empty after that keeps the original body — there is no request in it.
    def recompose_batch(orig_body : String, decoded_text : String) : String
      base = (JSON.parse(strip(orig_body)).as_a? rescue nil)
      segments = batch_segments(decoded_text)
      return orig_body if segments.empty? # verbatim: a fallback must not even re-trim (P7)
      elements = segments.map do |(idx, text)|
        el = idx.try { |i| base.try(&.[i]?).try(&.as_h?) }
        overlay(el, *parse_display(text))
      end
      elements.to_json
    end

    # `# --- [i] ---`, the batch element marker `batch_text` writes. Anchored and strict: a
    # GraphQL comment has to be spelled exactly this way, and be preceded by a blank line
    # (checked by the caller), before it is allowed to cut a document in half.
    BATCH_MARK_RE = /\A#\s*---\s*\[(\d+)\]\s*---\z/

    # The edited batch pane split into {declared index, block text} pairs. Anything before the
    # first marker is the `# batch of N operations` preamble and is dropped; blocks that are
    # blank after an edit carry no operation and are dropped too.
    private def batch_segments(text : String) : Array({Int32?, String})
      lines = text.split('\n')
      segs = [] of {Int32?, String}
      cur = nil.as(Array(String)?)
      idx = nil.as(Int32?)
      lines.each_with_index do |line, i|
        if (m = BATCH_MARK_RE.match(line.strip)) && (i == 0 || lines[i - 1].strip.empty?)
          if c = cur
            segs << {idx, c.join('\n')}
          end
          cur = [] of String
          idx = m[1].to_i?
          next
        end
        cur.try &.<< line
      end
      if c = cur
        segs << {idx, c.join('\n')}
      end
      segs.reject!(&.[1].strip.empty?)
      return segs unless segs.empty?
      rest = drop_batch_preamble(text)
      rest.strip.empty? ? segs : [{nil.as(Int32?), rest}]
    end

    # Drop the `# batch of N operations` header line, which is a count gori wrote and not
    # something the operator can mean — only reached when no marker survived the edit.
    private def drop_batch_preamble(text : String) : String
      lines = text.split('\n')
      lines.shift if lines.first?.try(&.strip.starts_with?("# batch of"))
      lines.join('\n')
    end

    # Re-encode the edited DECODED pane of a PERSISTED query. The pane is the JSON envelope
    # itself (`persisted_text`), so the inverse is: drop the leading `#` banner and minify
    # what is left. Nothing is added — if the operator wants to turn a hash-only request into
    # a document one (the allowlist bypass), they type the `query` field and gori sends it;
    # if they do not, gori does not invent one.
    #
    # An edit that does not parse as JSON keeps the ORIGINAL body, the same fallback invalid
    # variables get in `overlay`: a half-typed envelope must not go on the wire as a body the
    # server reads as something else.
    def recompose_persisted(orig_body : String, decoded_text : String) : String
      lines = strip(decoded_text).split('\n')
      while lines.first?.try(&.lstrip.starts_with?('#'))
        lines.shift
      end
      (JSON.parse(lines.join('\n')).to_json rescue orig_body) # verbatim on a bad edit (P7)
    end

    # Re-encode the edited DECODED pane of an `application/graphql` request: the body IS the
    # document, so the pane holds the request's own bytes and the inverse is the identity.
    # It exists as a named method anyway — the splice reads which inverse a form gets from one
    # place, and a reader looking for Document's finds it here instead of concluding it has
    # none. Nothing is stripped: leading whitespace in a document is the operator's bytes (P7).
    def recompose_document(decoded_text : String) : String
      decoded_text
    end

    # Re-encode the edited DECODED pane back into a GET request's query string, overlaying
    # query/operationName/variables onto the ORIGINAL params (any other params survive).
    # Variables are minified. The GET-binding sibling of recompose (which targets the body).
    def recompose_query(orig_query : String, decoded_text : String) : String
      op, query, vars_text = parse_display(decoded_text)
      mini = vars_text.try { |v| (JSON.parse(v).to_json rescue v) }
      replacement = {
        "query"         => "query=#{URI.encode_www_form(query)}",
        "operationName" => op.try { |o| "operationName=#{URI.encode_www_form(o)}" },
        "variables"     => mini.try { |m| "variables=#{URI.encode_www_form(m)}" },
      }
      # Replace the managed params IN PLACE rather than dropping them and appending. Rejecting
      # and re-adding moved them to the end, so `page=2&query=…&sig=abc` came back as
      # `page=2&sig=abc&query=…` — a request the operator did not write, and one that breaks any
      # signature or cache key computed over the canonical query string. Unmanaged params keep
      # their positions and their exact spelling either way.
      seen = Set(String).new
      parts = [] of String
      orig_query.split('&').each do |pair|
        next if pair.empty?
        key = pair.partition('=')[0]
        unless replacement.has_key?(key)
          parts << pair
          next
        end
        next unless seen.add?(key)              # a repeated managed param collapses into the first
        replacement[key].try { |r| parts << r } # nil = the edit removed it
      end
      replacement.each { |k, r| parts << r if r && seen.add?(k) } # not in the original: append
      parts.join('&')
    end

    # Re-encode the edited DECODED pane back into an `x-www-form-urlencoded` BODY.
    #
    # Delegates rather than duplicates: a form body and a query string are the same grammar
    # (`k=v&k=v`, `application/x-www-form-urlencoded` values), so the in-place replacement
    # `recompose_query` already performs — managed params rewritten where they stand, every
    # other param keeping its position and its exact spelling — is the correct write on both
    # sides. A second copy would be a second place for the escaping rules to drift, on the two
    # bindings whose only difference is which half of the request they live in.
    def recompose_form(orig_body : String, decoded_text : String) : String
      recompose_query(orig_body, decoded_text)
    end

    # Where a flow carries its op AND in which grammar the edit is written back: `:body` (a
    # POST JSON envelope), `:form_body` (an `x-www-form-urlencoded` body), `:batch_body` (the
    # JSON array), `:persisted_body` (the hash-only envelope), `:document_body` (an
    # `application/graphql` body, which IS the document), `:query` (a GET `?query=…`), or
    # `:none`. One answer per inverse in this module, because that is what the Repeater
    # splice dispatches on.
    #
    # Each is its own answer rather than a flavour of `:body` because none of them is the same
    # WRITE: `:body` recomposes a JSON object, `:form_body` rewrites `k=v` pairs, `:batch_body`
    # rebuilds an array, `:document_body` writes the pane verbatim. Answering `:body` for a
    # form-encoded request would replace the operator's form body with JSON while the
    # Content-Type still said urlencoded — a request they never wrote — and answering it for a
    # batch would collapse the array into one object.
    #
    # `:none` is the answer for every shape `display` renders but nothing can invert (multipart,
    # a parse failure, a decoded entity, a batch carrying a persisted element). It follows
    # `Op#editable?` exactly rather than re-deriving the list: a second copy of that decision
    # is a second place for it to get a shape wrong, and getting it wrong means re-encoding
    # from a projection.
    def location(req_body : Bytes?, req_head : Bytes? = nil) : Symbol
      entity, projected = Entity.of(req_head, req_body, MAX_BODY)
      op = ((b = entity) && !b.empty? && b.size <= MAX_BODY) ? from_body(b, MediaType.of(req_head)) : nil
      unless op
        # The same rule `from_flow` carries (see its comment): a request that actually sent a
        # body under a method that reads one has no GET binding to fall back to — the body IS
        # what the origin reads, so a failed parse (or a body past MAX_BODY) leaves nothing to
        # write an edit back into. Without this the `Invalid` pane, whose text is the REASON the
        # parse failed, was answered `:query` and spliced into the request LINE.
        return :none if (b = entity) && !b.empty? && body_is_payload?(req_head)
        return :query # a GET carrying a stray body still falls through — the `?query=` binding
      end
      # A decoded entity is a projection (see `Op#projected`): the envelope holds the wire
      # bytes, so there is no side to write an edit back into. `from_body` cannot know that —
      # it is handed the already-decoded bytes — so `projected` is applied here, and then the
      # ONE gate, because `refresh_decoded` can move a tab onto a projection mid-edit.
      return :none if projected || !op.editable?
      case op.form
      when .json?       then :body
      when .urlencoded? then :form_body
      when .batch?      then :batch_body
      when .persisted?  then :persisted_body
      when .document?   then :document_body
      else                   :none
      end
    end

    # `# operationName:` is ALSO a valid GraphQL source comment, so the same disambiguation the
    # `# variables` sentinel already gets is owed to this one — without it a document whose
    # FIRST line is a comment starting with those characters had that line deleted from the
    # query and its text promoted into a real `operationName` field, changing which operation
    # the server runs. `display` always writes the header as `"# operationName: NAME\n\n"`
    # (`display` above), so the genuine sentinel is followed by a BLANK line; a comment that
    # opens a document is followed by more GraphQL.
    private def blank_after?(lines : Array(String), i : Int32) : Bool
      nxt = lines[i + 1]?
      nxt.nil? || nxt.strip.empty?
    end

    private def json?(s : String) : Bool
      JSON.parse(s)
      true
    rescue
      false
    end

    private def strip(s : String) : String
      s.lchop('\u{FEFF}').strip
    end
  end
end
