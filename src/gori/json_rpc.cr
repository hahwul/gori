require "json"
require "./entity"
require "./sse"
require "./graphql"
require "./plural"

module Gori
  # JSON-RPC 2.0 — and so MCP's Streamable HTTP transport — as a display-time projection of one
  # flow (#1590): the request entity's call or batch, paired by `id` with the replies the
  # response carries, either as one JSON body or as the `data` of each SSE event. Pure and
  # surface-free; the stored bytes are never rewritten (P7). A body that is not JSON-RPC 2.0
  # (no `"jsonrpc":"2.0"`) yields nil, so a plain REST call offers no pane.
  module JsonRpc
    extend self

    # Parse ceiling per entity: a body above it is not decoded at all.
    MAX_BODY = Graphql::MAX_BODY

    alias Obj = Hash(String, JSON::Any)

    # One call the request made. `id` is the request's id (nil for a notification); `reply` is
    # the paired result or error as pretty JSON, nil while unanswered in this flow.
    record Call, method : String, id : JSON::Any?, label : String?, params : String?,
      reply : String?, error : Bool

    # A message the response carried that answers no call of this request: a server request or
    # notification inside the stream, or a reply whose id matched nothing (MCP's legacy HTTP+SSE
    # transport answers on a separate GET flow, so its replies land here, unpaired).
    record Message, method : String?, id : JSON::Any?, body : String

    record Exchange, calls : Array(Call), stream : Array(Message)

    # MCP's method namespaces. LSP and other JSON-RPC dialects spell theirs differently
    # (`textDocument/…`, `$/…`), so a hit names the flow MCP rather than generic JSON-RPC.
    MCP_PREFIXES = {"tools/", "resources/", "prompts/", "notifications/", "sampling/", "roots/",
                    "completion/", "logging/", "elicitation/"}

    def from_flow(req_head : Bytes?, req_body : Bytes?, resp_head : Bytes?, resp_body : Bytes?) : Exchange?
      calls = parse(Entity.bytes(req_head, req_body, MAX_BODY)).select { |m| m["method"]?.try(&.as_s?) }
      sse = Sse.event_stream?(resp_head)
      # The response is read only for a JSON-RPC request, or for a bodiless one opening a stream
      # (a GET carrying server-to-client messages): an LLM or REST stream is not parsed twice.
      return nil if calls.empty? && !(sse && (req_body.nil? || req_body.empty?))
      resp =
        if sse
          Sse.from_response(resp_head, resp_body).flat_map { |e| parse(e.data) }
        else
          parse(Entity.bytes(resp_head, resp_body, MAX_BODY))
        end
      exchange = pair(calls, resp)
      exchange.calls.empty? && exchange.stream.empty? ? nil : exchange
    end

    # Replies pair by id, whatever order a batch is answered in; the first reply to an id wins
    # and any other is listed with the stream.
    private def pair(calls : Array(Obj), resp : Array(Obj)) : Exchange
      ids = calls.compact_map { |c| c["id"]?.try(&.to_json) }.to_set
      replies = {} of String => Obj
      stream = [] of Message
      resp.each do |m|
        key = m["id"]?.try(&.to_json)
        if key && !m.has_key?("method") && ids.includes?(key) && !replies.has_key?(key)
          replies[key] = m
        else
          stream << Message.new(m["method"]?.try(&.as_s?), m["id"]?, m.to_pretty_json)
        end
      end
      list = calls.map do |c|
        id = c["id"]?
        r = id.try { |i| replies[i.to_json]? }
        # `"error": null` beside a result is no error.
        err = r.try(&.["error"]?).try { |e| e.raw.nil? ? nil : e }
        reply = r.try { |x| (err || x["result"]?).try(&.to_pretty_json) || "null" }
        Call.new(c["method"].as_s, id, label(c), c["params"]?.try(&.to_pretty_json), reply, !err.nil?)
      end
      Exchange.new(list, stream)
    end

    private def parse(bytes : Bytes?) : Array(Obj)
      return [] of Obj unless bytes && bytes.size <= MAX_BODY
      parse(String.new(bytes))
    end

    # JSON-RPC 2.0 objects only, single or batch; any other JSON (a scalar, an array of ids) is
    # not JSON-RPC and yields nothing.
    private def parse(text : String) : Array(Obj)
      any = json?(text, %("jsonrpc")) || return [] of Obj
      (any.as_a? || [any]).compact_map(&.as_h?).select! { |m| m["jsonrpc"]? == "2.0" }
    end

    # `text` as JSON, or nil when it is not or cannot hold `needle` — a byte check that keeps
    # an ordinary body from being parsed at all. Invalid UTF-8 is scrubbed for display (P7).
    # Shared with LlmCall.
    def json?(text : String, needle : String) : JSON::Any?
      return nil unless text.includes?(needle)
      JSON.parse(text.scrub)
    rescue JSON::ParseException
      nil
    end

    # What an MCP call is ABOUT: the tool, prompt or resource it names.
    private def label(c : Obj) : String?
      key = case c["method"].as_s
            when "tools/call", "prompts/get"             then "name"
            when "resources/read", "resources/subscribe" then "uri"
            else                                              return nil
            end
      c["params"]?.try(&.as_h?).try(&.[key]?).try(&.as_s?)
    end

    def mcp?(ex : Exchange) : Bool
      methods = ex.calls.map(&.method) + ex.stream.compact_map(&.method)
      methods.any? { |m| m == "initialize" || MCP_PREFIXES.any? { |p| m.starts_with?(p) } }
    end

    # A one-line summary for a pane header / CLI section title.
    def summary(ex : Exchange) : String
      parts = [mcp?(ex) ? "MCP" : "JSON-RPC", Gori.plural(ex.calls.size, "call")]
      open = ex.calls.count { |c| c.id && c.reply.nil? }
      parts << "#{open} unanswered" if open > 0
      parts << Gori.plural(ex.stream.size, "stream message") unless ex.stream.empty?
      names = ex.calls.map { |c| c.label ? "#{c.method} #{c.label}" : c.method }.uniq!
      parts << "#{names.first(3).join(", ")}#{names.size > 3 ? ", …" : ""}" unless names.empty?
      parts.join(" · ")
    end

    # The pane text: each call with its reply under it, then the unpaired stream messages.
    def display(ex : Exchange) : String
      String.build do |io|
        ex.calls.each do |c|
          io << "\n\n" if io.bytesize > 0
          io << "# → " << c.method
          c.id.try { |i| io << " id=" << i.to_json }
          c.label.try { |l| io << " · " << l }
          io << '\n' << (c.params || "(no params)")
          if r = c.reply
            io << "\n# ← " << (c.error ? "error" : "result") << '\n' << r
          else
            io << "\n# ← " << (c.id ? "no reply in this flow" : "notification, no reply expected")
          end
        end
        ex.stream.each do |m|
          io << "\n\n" if io.bytesize > 0
          io << "# ⇠ stream " << (m.method || "reply")
          m.id.try { |i| io << " id=" << i.to_json }
          io << '\n' << m.body
        end
      end
    end
  end
end
