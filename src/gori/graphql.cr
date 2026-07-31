require "json"
require "uri"

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

    record Op,
      operation : String?, # operationName
      query : String,      # the GraphQL document (de-escaped)
      variables : String?  # pretty-printed JSON variables, or nil when absent

    # Parse the operation, or nil if the flow isn't GraphQL. Tries the POST JSON body
    # first, then the GET query string.
    #
    # The query-string fallback is NOT reached for a body-bearing method that actually sent a
    # body: there, the body IS the payload the server reads, so falling through made any
    # `POST /upload?query=%7Bx%7D` with an unrelated (even binary) body report as GraphQL. That
    # is not merely a wrong pane — `location` then answers `:query`, so sending it from the
    # Repeater re-encodes the whole query string, rewriting the operator's request on the
    # strength of a misdetection. A GET carrying a stray body still falls through, which is
    # what the fallback was written for.
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?) : Op?
      if (b = req_body) && !b.empty? && b.size <= MAX_BODY
        if op = from_json(String.new(b))
          return op
        end
      end
      return nil if (b = req_body) && !b.empty? && body_bearing?(req_head)
      from_query(target)
    end

    # Whether the request line names a method whose BODY carries the payload. Read off the
    # head, which `from_flow` has always been handed and never looked at. nil (no head, as in
    # a unit call) keeps the permissive fallback.
    private def body_bearing?(req_head : Bytes?) : Bool
      head = req_head || return false
      line = String.new(head[0, {head.size, 64}.min])
      sp = line.index(' ') || return false
      case line[0, sp].upcase
      when "POST", "PUT", "PATCH" then true
      else                             false
      end
    end

    # A POST JSON body. A GraphQL document always has a selection set, so requiring a
    # `{` in the query string avoids hijacking an ordinary REST body that happens to
    # carry a string `query` field (e.g. `{"query":"shoes"}`).
    def from_json(body : String) : Op?
      json = JSON.parse(strip(body))
      h = json.as_h? || return nil
      q = h["query"]?.try(&.as_s?) || return nil
      return nil unless q.includes?('{')
      vars = h["variables"]?
      Op.new(h["operationName"]?.try(&.as_s?), q.strip,
        (vars && !vars.raw.nil?) ? vars.to_pretty_json : nil)
    rescue
      nil
    end

    # A GET `?query=…&operationName=…&variables=…` request.
    def from_query(target : String) : Op?
      idx = target.index('?') || return nil
      params = {} of String => String
      target[(idx + 1)..].split('&').each do |pair|
        k, sep, v = pair.partition('=')
        params[k] = (URI.decode_www_form(v) rescue v) unless sep.empty?
      end
      q = params["query"]? || return nil
      return nil unless q.includes?('{')
      vars = params["variables"]?.try { |v| (JSON.parse(v).to_pretty_json rescue v) }
      Op.new(params["operationName"]?, q.strip, vars)
    rescue
      nil
    end

    # The display text for a parsed op: an operationName header, the query, and the
    # variables block (each present only when set). This is the editable form shown in
    # the Repeater DECODED pane; parse_display is its inverse.
    def display(op : Op) : String
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
      op, query, vars_text = parse_display(decoded_text)
      base = (JSON.parse(strip(envelope_body)).as_h? rescue nil)
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
      obj.to_json
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

    # Where a flow carries its op: :body (a POST JSON body that parses as GraphQL) or
    # :query (a GET `?query=…`). Drives which side the Repeater re-encode targets. Decided
    # solely by whether the request body is a GraphQL JSON document.
    def location(req_body : Bytes?) : Symbol
      if (b = req_body) && !b.empty? && b.size <= MAX_BODY && from_json(String.new(b))
        :body
      else
        :query
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
