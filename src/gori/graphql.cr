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
    def from_flow(target : String, req_head : Bytes?, req_body : Bytes?) : Op?
      if (b = req_body) && !b.empty? && b.size <= MAX_BODY
        if op = from_json(String.new(b))
          return op
        end
      end
      from_query(target)
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
    # the Replay DECODED pane; parse_display is its inverse.
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
      lines.each_with_index do |l, i|
        next unless l.strip == "# variables"
        trailing = lines[(i + 1)..].join('\n').strip
        vi = i if !trailing.empty? && json?(trailing)
      end
      vars = vi ? lines[(vi + 1)..].join('\n').strip : nil
      body = vi ? lines[0...vi] : lines
      op = nil.as(String?)
      if (first = body.index { |l| !l.strip.empty? }) && body[first].strip.starts_with?("# operationName:")
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
      base.try &.each { |k, v| obj[k] = v unless obj.has_key?(k) } # keep extensions etc.
      obj.to_json
    end

    # Re-encode the edited DECODED pane back into a GET request's query string, overlaying
    # query/operationName/variables onto the ORIGINAL params (any other params survive).
    # Variables are minified. The GET-binding sibling of recompose (which targets the body).
    def recompose_query(orig_query : String, decoded_text : String) : String
      op, query, vars_text = parse_display(decoded_text)
      managed = {"query", "operationName", "variables"}
      parts = orig_query.split('&').reject { |pair| pair.empty? || managed.includes?(pair.partition('=')[0]) }
      parts << "query=#{URI.encode_www_form(query)}"
      parts << "operationName=#{URI.encode_www_form(op)}" if op
      if vars_text
        mini = (JSON.parse(vars_text).to_json rescue vars_text)
        parts << "variables=#{URI.encode_www_form(mini)}"
      end
      parts.join('&')
    end

    # Where a flow carries its op: :body (a POST JSON body that parses as GraphQL) or
    # :query (a GET `?query=…`). Drives which side the Replay re-encode targets. Decided
    # solely by whether the request body is a GraphQL JSON document.
    def location(req_body : Bytes?) : Symbol
      if (b = req_body) && !b.empty? && b.size <= MAX_BODY && from_json(String.new(b))
        :body
      else
        :query
      end
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
