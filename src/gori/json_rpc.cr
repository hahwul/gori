require "json"
require "./entity"
require "./sse"
require "./graphql"
require "./plural"
require "./raw_json"

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

    # One call the request made. `id` is the request's id as the compact JSON it was sent as
    # (`7`, `"a"`, `18446744073709551615`; nil for a notification); `reply` is the paired result
    # or error as pretty JSON, nil while unanswered in this flow.
    record Call, method : String, id : String?, label : String?, params : String?,
      reply : String?, error : Bool

    # A message the response carried that answers no call of this request: a server request or
    # notification inside the stream, or a reply whose id matched nothing (MCP's legacy HTTP+SSE
    # transport answers on a separate GET flow, so its replies land here, unpaired).
    record Message, method : String?, id : String?, body : String

    # One JSON-RPC message as RAW JSON text: the object, and its members' values (the last of
    # a duplicated key, as `JSON.parse` reads it). Everything this module shows is a value it
    # re-emits, so it never holds a `JSON::Any`: `JSON.parse` rejects a whole document over one
    # number past Int64 (a uint64 id), and a `RawJson.parse` tree would quote that number back
    # out — and pair the number 18446744073709551615 with the string "18446744073709551615".
    private record Msg, raw : String, m : Hash(String, String)

    record Exchange, calls : Array(Call), stream : Array(Message)

    # MCP's method namespaces. LSP and other JSON-RPC dialects spell theirs differently
    # (`textDocument/…`, `$/…`), so a hit names the flow MCP rather than generic JSON-RPC.
    MCP_PREFIXES = {"tools/", "resources/", "prompts/", "notifications/", "sampling/", "roots/",
                    "completion/", "logging/", "elicitation/"}

    def from_flow(req_head : Bytes?, req_body : Bytes?, resp_head : Bytes?, resp_body : Bytes?) : Exchange?
      calls = parse(Entity.bytes(req_head, req_body, MAX_BODY)).select { |m| str(m.m["method"]?) }
      sse = Sse.event_stream?(resp_head)
      # The response is read only for a JSON-RPC request, or for a bodiless one opening a stream
      # (a GET carrying server-to-client messages): an LLM or REST stream is not parsed twice.
      return nil if calls.empty? && !(sse && (req_body.nil? || req_body.empty?))
      resp =
        if sse
          sse_events(resp_head, resp_body).flat_map { |e| parse(e.data) }
        else
          parse(Entity.bytes(resp_head, resp_body, MAX_BODY))
        end
      exchange = pair(calls, resp)
      exchange.calls.empty? && exchange.stream.empty? ? nil : exchange
    end

    # Replies pair by id, whatever order a batch is answered in. Calls sharing an id (a client
    # bug, or a probe for one) take that id's replies in order; a reply left over is listed
    # with the stream. The key is the id's compact JSON text, so `1` and `"1"` stay apart — and
    # so do `1` and `1.0`, which are different spellings on the wire.
    private def pair(calls : Array(Msg), resp : Array(Msg)) : Exchange
      wanted = calls.compact_map(&.m["id"]?).tally
      replies = {} of String => Deque(Msg)
      stream = [] of Message
      resp.each do |m|
        key = m.m["id"]?
        if key && !m.m.has_key?("method") && (q = replies[key] ||= Deque(Msg).new).size < wanted.fetch(key, 0)
          q << m
        else
          stream << Message.new(str(m.m["method"]?), key, pretty(m.raw))
        end
      end
      list = calls.map do |c|
        id = c.m["id"]?
        r = id.try { |i| replies[i]?.try(&.shift?) }
        # `"error": null` beside a result is no error.
        err = r.try(&.m["error"]?).try { |e| e == "null" ? nil : e }
        reply = r.try { |x| (err || x.m["result"]?).try { |v| pretty(v) } || "null" }
        params = c.m["params"]?.try { |v| pretty(v) }
        Call.new(str(c.m["method"]?) || "", id, label(c), params, reply, !err.nil?)
      end
      Exchange.new(list, stream)
    end

    private def parse(bytes : Bytes?) : Array(Msg)
      return [] of Msg unless bytes && bytes.size <= MAX_BODY
      parse(String.new(bytes))
    end

    # JSON-RPC 2.0 objects only, single or batch; any other JSON (a scalar, an array of ids) is
    # not JSON-RPC and yields nothing. The needle runs first, so an ordinary body is never
    # scrubbed or parsed (P6); invalid UTF-8 is scrubbed for display (P7).
    private def parse(text : String) : Array(Msg)
      return [] of Msg unless text.includes?(%("jsonrpc"))
      # `members` skips `tolerant` (it re-emits for a JWT re-sign); this is display, so one
      # unpaired surrogate escape must not hide the message.
      json = RawJson.tolerant(text.scrub)
      items = batch?(json) ? RawJson.elements(json) || [] of String : [json]
      items.compact_map do |item|
        m = RawJson.members(item).try(&.to_h) || next
        Msg.new(item, m) if m["jsonrpc"]? == %("2.0")
      end
    rescue JSON::ParseException
      [] of Msg
    end

    # Whether the document's root is an array, read off its first byte: a single message is
    # then parsed once, not once more to learn it is not a batch.
    private def batch?(json : String) : Bool
      json.each_byte do |b|
        next if b === ' ' || b === '\n' || b === '\r' || b === '\t'
        return b === '['
      end
      false
    end

    # A raw JSON string member, decoded; nil for any other value (or none).
    private def str(raw : String?) : String?
      raw.try { |r| String.from_json(r) if r.starts_with?('"') }
    end

    # Raw JSON as pretty text: the indentation `to_pretty_json` gives, but every number as the
    # digits that were sent and every duplicated member kept.
    private def pretty(raw : String) : String
      RawJson.reformat(raw, "  ")
    end

    # A response's SSE events, under the same MAX_BODY a plain JSON reply is held to: a 32 KB
    # gzip of 100k events decoded to 500 MiB of pretty JSON on the History fiber. Shared with LlmCall.
    def sse_events(head : Bytes?, body : Bytes?) : Array(Sse::Event)
      return [] of Sse::Event unless Sse.event_stream?(head) && (bytes = Entity.bytes(head, body, MAX_BODY))
      bytes.size > MAX_BODY ? [] of Sse::Event : Sse.events(bytes)
    end

    # `text` as JSON, or nil when it is not or cannot hold `needle` — a byte check that keeps
    # an ordinary body from being parsed at all. Invalid UTF-8 is scrubbed for display (P7).
    # Shared with LlmCall. `RawJson.parse`, so one number past Int64 (a uint64 seed) or an
    # unpaired surrogate escape no longer makes the whole document "not JSON". For READING
    # only: such a number is carried as a String, so a subtree of this tree is never re-emitted
    # — a caller showing one takes its raw text (`JsonPath.raw_at`).
    def json?(text : String, needle : String) : JSON::Any?
      return nil unless text.includes?(needle)
      RawJson.parse(text.scrub)
    rescue JSON::ParseException
      nil
    end

    # What an MCP call is ABOUT: the tool, prompt or resource it names.
    private def label(c : Msg) : String?
      key = case str(c.m["method"]?)
            when "tools/call", "prompts/get"             then "name"
            when "resources/read", "resources/subscribe" then "uri"
            else                                              return nil
            end
      c.m["params"]?.try { |p| RawJson.member(p, key) }.try(&.as_s?)
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
          c.id.try { |i| io << " id=" << i }
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
          m.id.try { |i| io << " id=" << i }
          io << '\n' << m.body
        end
      end
    end
  end
end
