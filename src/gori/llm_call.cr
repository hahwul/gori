require "json"
require "./entity"
require "./sse"
require "./json_rpc"
require "./plural"

module Gori
  # An LLM API call as a display-time projection of one flow (#1590): OpenAI chat completions,
  # OpenAI responses and Anthropic messages, recognised by the REQUEST's shape (`model` plus
  # `messages` or `input`), never by hostname — a self-hosted or proxied gateway serves the same
  # shapes from any host. A streamed reply's deltas are reassembled into the text and tool calls
  # the non-streamed reply would have carried. Pure and surface-free; bytes are never rewritten (P7).
  #
  # Every read goes through `obj`/`objs`/`str`/`index`: the bytes are the server's (or the
  # operator's), and `JSON::Any#[]?` RAISES on a value that is not an object.
  module LlmCall
    extend self

    MAX_BODY = JsonRpc::MAX_BODY

    CHAT      = "openai-chat"
    RESPONSES = "openai-responses"
    ANTHROPIC = "anthropic"

    alias Obj = JsonRpc::Obj

    # `arguments` is pretty JSON when the model produced valid JSON, its raw text otherwise.
    record ToolCall, name : String, arguments : String

    # `roles` summarises the request's messages (`system, user ×2, assistant`); `tools` names the
    # tools it declared. The rest is the reply: nil/empty where the flow has none yet.
    record Call, dialect : String, model : String?, roles : String, tools : Array(String),
      streamed : Bool, text : String, tool_calls : Array(ToolCall), stop : String?, usage : JSON::Any?

    def from_flow(req_head : Bytes?, req_body : Bytes?, resp_head : Bytes?, resp_body : Bytes?) : Call?
      req = obj(json(Entity.bytes(req_head, req_body, MAX_BODY), %("model"))) || return nil
      model = str(req["model"]?) || return nil
      msgs = req["messages"]?.try(&.as_a?)
      input = req["input"]?
      return nil unless msgs || input
      # A guess from the request alone; the reply's own shape overrides it.
      dialect = msgs.nil? ? RESPONSES : (req.has_key?("system") ? ANTHROPIC : CHAT)
      acc = Acc.new(dialect, model)
      events = Sse.from_response(resp_head, resp_body)
      if events.empty?
        obj(json(Entity.bytes(resp_head, resp_body, MAX_BODY), "{")).try { |r| acc.feed(r) }
      else
        events.each { |e| obj(JsonRpc.json?(e.data, "{")).try { |r| acc.feed(r) } }
      end
      # `model` + `input` is also an embeddings or moderation request: only a Responses-shaped
      # reply (or none yet) makes it an LLM call.
      return nil if msgs.nil? && !acc.shaped? && resp_body.try(&.empty?) == false
      acc.call(roles(req, msgs, input), tools(req), !events.empty?)
    end

    private def json(bytes : Bytes?, needle : String) : JSON::Any?
      return nil unless bytes && bytes.size <= MAX_BODY
      JsonRpc.json?(String.new(bytes), needle)
    end

    # :nodoc: — tolerant accessors over hostile JSON (see the module header).
    def obj(a : JSON::Any?) : Obj?
      a.try(&.as_h?)
    end

    # :nodoc:
    def objs(a : JSON::Any?) : Array(Obj)
      a.try(&.as_a?).try(&.compact_map(&.as_h?)) || [] of Obj
    end

    # :nodoc:
    def str(a : JSON::Any?) : String?
      a.try(&.as_s?)
    end

    # :nodoc: — a content/tool index; an absurd one (or a float) falls back rather than raising.
    def index(a : JSON::Any?, default : Int32) : Int32
      i = a.try(&.as_i64?)
      i && 0 <= i <= 10_000 ? i.to_i : default
    end

    # `system, user ×2, assistant`, in first-seen order. Anthropic's top-level `system` and a
    # responses-API string `input` count as one message each.
    private def roles(req : Obj, msgs : Array(JSON::Any)?, input : JSON::Any?) : String
      list = [] of String
      list << "system" if req.has_key?("system")
      if items = msgs || input.try(&.as_a?)
        items.each { |m| list << (obj(m).try { |o| str(o["role"]?) || str(o["type"]?) } || "?") }
      elsif input
        list << "user"
      end
      list.tally.map { |r, n| n > 1 ? "#{r} ×#{n}" : r }.join(", ")
    end

    # Declared tool names: `name` (Anthropic, responses) or `function.name` (chat).
    private def tools(req : Obj) : Array(String)
      objs(req["tools"]?).compact_map { |t| str(t["name"]?) || obj(t["function"]?).try { |f| str(f["name"]?) } }
    end

    # A reply as it accumulates: one non-streamed body, or each stream event in order.
    private class Acc
      @text = IO::Memory.new
      @tools = {} of Int32 => {String, IO::Memory}
      @stop : String? = nil
      @usage = {} of String => JSON::Any
      # Whether any reply carried one of the three shapes at all.
      getter? shaped = false

      def initialize(@dialect : String, @model : String?)
      end

      def call(roles : String, tools : Array(String), streamed : Bool) : Call
        calls = @tools.to_a.sort_by!(&.[0]).map { |(_, (name, args))| ToolCall.new(name, pretty(args.to_s)) }
        Call.new(@dialect, @model, roles, tools, streamed, @text.to_s, calls, @stop,
          @usage.empty? ? nil : JSON::Any.new(@usage))
      end

      def feed(r : Obj) : Nil
        type = LlmCall.str(r["type"]?) || ""
        @model = LlmCall.str(r["model"]?) || @model
        if r.has_key?("choices")
          chat(r)
        elsif type == "message" || type.starts_with?("message_") || type.starts_with?("content_block_")
          anthropic(type, r)
        elsif r["object"]? == "response"
          responses(r)
        elsif type.in?("response.completed", "response.incomplete", "response.failed")
          # The final event carries the whole response: it replaces the deltas read so far.
          @text.clear
          @tools.clear
          LlmCall.obj(r["response"]?).try { |x| responses(x) }
        elsif type == "response.output_text.delta"
          @shaped = true
          @text << LlmCall.str(r["delta"]?)
        end
      end

      # One completion or one chunk: the first choice's `message` or `delta`, the same fields
      # either way. Picked by `index`, since a chunk of an `n>1` stream carries another choice.
      private def chat(r : Obj) : Nil
        @dialect = CHAT
        @shaped = true
        usage(r["usage"]?)
        ch = LlmCall.objs(r["choices"]?).find { |c| LlmCall.index(c["index"]?, 0) == 0 } || return
        @stop = LlmCall.str(ch["finish_reason"]?) || @stop
        msg = LlmCall.obj(ch["message"]?) || LlmCall.obj(ch["delta"]?) || return
        @text << LlmCall.str(msg["content"]?)
        LlmCall.objs(msg["tool_calls"]?).each_with_index do |tc, i|
          fn = LlmCall.obj(tc["function"]?)
          tool(LlmCall.index(tc["index"]?, i), fn.try { |f| LlmCall.str(f["name"]?) }, fn.try { |f| LlmCall.str(f["arguments"]?) })
        end
      end

      private def anthropic(type : String, r : Obj) : Nil
        @dialect = ANTHROPIC
        @shaped = true
        case type
        when "message"
          LlmCall.objs(r["content"]?).each_with_index { |b, i| block(i, b) }
          stop(r)
          usage(r["usage"]?)
        when "message_start"
          msg = LlmCall.obj(r["message"]?) || return
          @model = LlmCall.str(msg["model"]?) || @model
          usage(msg["usage"]?)
        when "content_block_start"
          LlmCall.obj(r["content_block"]?).try { |b| block(LlmCall.index(r["index"]?, 0), b) }
        when "content_block_delta"
          d = LlmCall.obj(r["delta"]?) || return
          @text << LlmCall.str(d["text"]?)
          LlmCall.str(d["partial_json"]?).try { |j| tool(LlmCall.index(r["index"]?, 0), nil, j) }
        when "message_delta"
          LlmCall.obj(r["delta"]?).try { |d| stop(d) }
          usage(r["usage"]?)
        end
      end

      private def block(i : Int32, b : Obj) : Nil
        case LlmCall.str(b["type"]?)
        when "text"
          @text << LlmCall.str(b["text"]?)
        when "tool_use"
          input = LlmCall.obj(b["input"]?)
          # A streamed block opens with `input: {}` and fills it from `input_json_delta`s.
          tool(i, LlmCall.str(b["name"]?), input.nil? || input.empty? ? nil : input.to_json)
        end
      end

      private def stop(r : Obj) : Nil
        @stop = LlmCall.str(r["stop_reason"]?) || @stop
      end

      private def responses(r : Obj) : Nil
        @dialect = RESPONSES
        @shaped = true
        @model = LlmCall.str(r["model"]?) || @model # also reached for the nested `response.completed` payload
        @stop = LlmCall.str(r["status"]?) || @stop
        usage(r["usage"]?)
        LlmCall.objs(r["output"]?).each_with_index do |item, i|
          case LlmCall.str(item["type"]?)
          when "message"
            LlmCall.objs(item["content"]?).each { |c| @text << LlmCall.str(c["text"]?) }
          when "function_call"
            tool(i, LlmCall.str(item["name"]?), LlmCall.str(item["arguments"]?))
          end
        end
      end

      private def tool(i : Int32, name : String?, args : String?) : Nil
        entry = @tools[i] ||= {"", IO::Memory.new}
        @tools[i] = {name, entry[1]} if name && !name.empty?
        entry[1] << args
      end

      # Later usage fields win: Anthropic's `message_delta` updates `output_tokens` that
      # `message_start` reported early.
      private def usage(u : JSON::Any?) : Nil
        LlmCall.obj(u).try { |h| @usage.merge!(h) }
      end

      private def pretty(args : String) : String
        JSON.parse(args).to_pretty_json
      rescue JSON::ParseException
        args
      end
    end

    # A one-line summary for a pane header / CLI section title.
    def summary(c : Call) : String
      parts = [c.dialect]
      c.model.try { |m| parts << m }
      parts << "streamed" if c.streamed
      parts << Gori.plural(c.tool_calls.size, "tool call") unless c.tool_calls.empty?
      c.stop.try { |s| parts << s }
      parts.join(" · ")
    end

    # The pane text: what was asked, then what came back.
    def display(c : Call) : String
      String.build do |io|
        io << "# request: " << (c.roles.empty? ? "(no messages)" : c.roles)
        io << "\n# tools: " << c.tools.join(", ") unless c.tools.empty?
        c.usage.try { |u| io << "\n# usage: " << u.to_json }
        io << "\n\n" << c.text unless c.text.empty?
        c.tool_calls.each { |t| io << "\n\n# tool call " << t.name << '\n' << t.arguments }
      end
    end
  end
end
