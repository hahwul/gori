require "json"
require "./entity"
require "./sse"
require "./json_rpc"
require "./json_path"
require "./raw_json"
require "./plural"
require "./utf8"

module Gori
  # An LLM API call as a display-time projection of one flow (#1590): OpenAI chat completions,
  # OpenAI responses and Anthropic messages, recognised by the REQUEST's shape (`model` plus
  # `messages` or `input`), never by hostname — a self-hosted or proxied gateway serves the same
  # shapes from any host. A streamed reply's deltas are reassembled into the text and tool calls
  # the non-streamed reply would have carried. Pure and surface-free; bytes are never rewritten (P7).
  #
  # Every read goes through `obj`/`objs`/`str`/`index`: the bytes are the server's (or the
  # operator's), and `JSON::Any#[]?` RAISES on a value that is not an object.
  #
  # The tree is `RawJson.parse_typed`'s, so a number past Int64 — a uint64
  # `seed`, a usage counter — no longer hides the call; such a number is carried as a String,
  # so the subtrees this module SHOWS as JSON (a tool_use `input`, `usage`) are read as raw
  # text off the document (`raw_at`), never re-emitted from the tree.
  module LlmCall
    extend self

    MAX_BODY = JsonRpc::MAX_BODY

    CHAT      = "openai-chat"
    RESPONSES = "openai-responses"
    ANTHROPIC = "anthropic"

    alias Obj = JsonRpc::Obj
    alias Step = JsonPath::Step

    # `arguments` is pretty JSON when the model produced valid JSON, its raw text otherwise.
    record ToolCall, name : String, arguments : String

    # `roles` summarises the request's messages (`system, user ×2, assistant`); `tools` names the
    # tools it declared. The rest is the reply: nil/empty where the flow has none yet. `usage`
    # is the reply's usage object as compact JSON, numbers as sent.
    record Call, dialect : String, model : String?, roles : String, tools : Array(String),
      streamed : Bool, text : String, tool_calls : Array(ToolCall), stop : String?, usage : String?

    def from_flow(req_head : Bytes?, req_body : Bytes?, resp_head : Bytes?, resp_body : Bytes?) : Call?
      request(req_head, req_body).try { |(req, _)| call(req, resp_head, resp_body) }
    end

    # The request object and the text it was read from.
    private def request(req_head : Bytes?, req_body : Bytes?) : {Obj, String}?
      doc(Entity.bytes(req_head, req_body, MAX_BODY), %("model"))
    end

    private def call(req : Obj, resp_head : Bytes?, resp_body : Bytes?) : Call?
      model = str(req["model"]?) || return nil
      msgs = req["messages"]?.try(&.as_a?)
      input = req["input"]?
      return nil unless msgs || input
      # A guess from the request alone; the reply's own shape overrides it.
      dialect = msgs.nil? ? RESPONSES : (req.has_key?("system") ? ANTHROPIC : CHAT)
      acc = Acc.new(dialect, model)
      events = JsonRpc.sse_events(resp_head, resp_body)
      if events.empty?
        doc(Entity.bytes(resp_head, resp_body, MAX_BODY), "{").try { |(r, raw)| acc.feed(r, raw) }
      else
        events.each { |e| doc(e.data, "{").try { |(r, raw)| acc.feed(r, raw) } }
      end
      # `model` + `input` is also an embeddings or moderation request: only a Responses-shaped
      # reply (or none yet) makes it an LLM call.
      return nil if msgs.nil? && !acc.shaped? && resp_body.try(&.empty?) == false
      acc.call(roles(req, msgs, input), tools(req), !events.empty?)
    end

    # A STREAMED reply reassembled from the response alone, for a matcher: a word the model wrote
    # can be split across two deltas and never appear in the body (#1912). The text, then each
    # tool call's name and arguments on their own lines, all as the model wrote them — none of it
    # is gori's formatting. `decoded` is the content-decoded body the caller already holds. nil
    # for anything but an event stream carrying one of the three shapes.
    def stream_reply(resp_head : Bytes?, decoded : Bytes) : String?
      return nil unless Sse.event_stream?(resp_head) && decoded.size <= MAX_BODY
      acc = Acc.new(CHAT, nil)
      Sse.events(decoded).each { |e| doc(e.data, "{").try { |(r, raw)| acc.feed(r, raw) } }
      acc.raw_reply if acc.shaped?
    end

    # The call as a Markdown transcript for a report (#1912): each request message under its
    # role, then the reply. nil wherever `from_flow` is. Built for a copy menu or an export, so
    # the pane's `from_flow` carries no message text.
    def transcript(req_head : Bytes?, req_body : Bytes?, resp_head : Bytes?, resp_body : Bytes?) : String?
      req, raw = request(req_head, req_body) || return nil
      c = call(req, resp_head, resp_body) || return nil
      String.build do |io|
        io << "# LLM call: " << summary(c)
        messages(req, raw).each { |(role, text)| io << "\n\n## " << role << "\n\n" << text }
        io << "\n\n## assistant" unless c.text.empty? && c.tool_calls.empty?
        io << "\n\n" << c.text unless c.text.empty?
        c.tool_calls.each { |t| io << "\n\n### tool call: " << t.name << "\n\n```json\n" << t.arguments << "\n```" }
        io << '\n'
      end
    end

    # The request's messages as `{role, text}`, the system prompt first: Anthropic's top-level
    # `system`, or the Responses API's `instructions`. `raw` is the request text, for the
    # tool_use inputs shown as JSON.
    private def messages(req : Obj, raw : String) : Array({String, String})
      list = [] of {String, String}
      key = req.has_key?("messages") ? "messages" : "input"
      input = req[key]?
      items = str(input) ? nil : input.try(&.as_a?)
      wanted = Set(Int32).new
      items.try &.each_with_index { |m, i| wanted << i if tool_use_in?(obj(m).try(&.["content"]?)) }
      sys_inputs, msg_inputs = request_inputs(raw, key, tool_use_in?(req["system"]?), wanted, items.try(&.size) || 0)
      system = content(req["system"]?, sys_inputs)
      system = str(req["instructions"]?) || "" if system.empty?
      list << {"system", system} unless system.empty?
      if text = str(input)
        list << {"user", text}
      elsif items
        items.each_with_index { |m, i| obj(m).try { |o| list << message(o, msg_inputs[i]) } }
      end
      list
    end

    # :nodoc: — the tool_use inputs of one `content` array as raw JSON text (numbers as sent),
    # by the block's RAW index — `objs` compacts away a non-object block, which would put an
    # input on the wrong block — with a tool_result's own content nested under its index.
    class Inputs
      getter input = {} of Int32 => String
      getter nested = {} of Int32 => Inputs
    end

    # The `content` value the parser is on, read for its inputs (nil, skipped, when it is not
    # an array). A duplicated `input` or `content` member: the last wins, as in the tree.
    # Only ever run over a document that already parsed whole, so skipping cannot pass over
    # bad syntax.
    def read_inputs(pull : JSON::PullParser) : Inputs?
      unless pull.kind.begin_array?
        pull.skip
        return nil
      end
      node = Inputs.new
      j = 0
      pull.read_array do
        if pull.kind.begin_object?
          pull.read_object do |k|
            case k
            when "input" then node.input[j] = pull.read_raw
            when "content"
              if sub = read_inputs(pull)
                node.nested[j] = sub
              else
                node.nested.delete(j)
              end
            else pull.skip
            end
          end
        else
          pull.skip
        end
        j += 1
      end
      node
    end

    # The inputs of `system` and of each `wanted` message, in ONE pull pass over the request
    # that skips everything else. Looking each input up in the whole request made a long agent
    # transcript quadratic, and materialising each message as text cost ~3x the parse. The
    # LAST occurrence of a duplicated key wins, as in the tree.
    private def request_inputs(raw : String, key : String, want_system : Bool, wanted : Set(Int32),
                               size : Int32) : {Inputs?, Array(Inputs?)}
      system = nil.as(Inputs?)
      msgs = Array(Inputs?).new(size, nil)
      return {system, msgs} unless want_system || !wanted.empty?
      pull = JSON::PullParser.new(RawJson.tolerant(raw))
      return {system, msgs} unless pull.kind.begin_object?
      pull.read_object do |k|
        if k == "system" && want_system
          system = read_inputs(pull)
        elsif k == key && pull.kind.begin_array?
          read_messages(pull, wanted, size).try { |found| msgs = found }
        else
          pull.skip
        end
      end
      {system, msgs}
    rescue JSON::ParseException
      {nil, Array(Inputs?).new(size, nil)}
    end

    # The messages array the parser is on: each wanted message's content inputs, by raw index.
    # nil when the array is not the `size` the tree read (an earlier duplicated key).
    private def read_messages(pull : JSON::PullParser, wanted : Set(Int32), size : Int32) : Array(Inputs?)?
      found = Array(Inputs?).new(size, nil)
      i = 0
      pull.read_array do
        if i < size && wanted.includes?(i) && pull.kind.begin_object?
          pull.read_object { |mk| mk == "content" ? (found[i] = read_inputs(pull)) : pull.skip }
        else
          pull.skip
        end
        i += 1
      end
      i == size ? found : nil
    end

    # Whether a `content` holds a tool_use block, at the top or inside a tool_result.
    private def tool_use_in?(a : JSON::Any?) : Bool
      objs(a).any? { |b| (t = str(b["type"]?)) == "tool_use" || (t == "tool_result" && tool_use_in?(b["content"]?)) }
    end

    # `inputs` are this message's content inputs (nil when it carries no tool_use to show).
    private def message(m : Obj, inputs : Inputs?) : {String, String}
      parts = [content(m["content"]?, inputs)]
      objs(m["tool_calls"]?).each do |tc|
        obj(tc["function"]?).try { |f| parts << "[tool call #{str(f["name"]?)}] #{str(f["arguments"]?)}" }
      end
      # A Responses item that is a call or its output, not a message.
      parts << "[tool call #{str(m["name"]?)}] #{str(m["arguments"]?)}" if m["type"]? == "function_call"
      str(m["output"]?).try { |o| parts << o }
      {str(m["role"]?) || str(m["type"]?) || "?", parts.reject(&.empty?).join('\n')}
    end

    # A message's `content`: a string, or blocks. A block with no text (an image, a document)
    # is named by its type, not dropped. A tool_use input is shown as the JSON that was sent
    # (`inputs`, read off the request text).
    private def content(a : JSON::Any?, inputs : Inputs?) : String
      return "" if a.nil?
      str(a) || begin
        parts = [] of String
        a.as_a?.try &.each_with_index do |v, j|
          b = obj(v) || next
          parts << case type = str(b["type"]?)
          when "tool_use"    then "[tool call #{str(b["name"]?)}] #{inputs.try(&.input[j]?)}"
          when "tool_result" then "[tool result] #{content(b["content"]?, inputs.try(&.nested[j]?))}"
          else                    str(b["text"]?) || "[#{type || "?"}]"
          end
        end
        parts.join('\n')
      end
    end

    # The object `bytes` hold, and the (scrubbed) text it was read from.
    private def doc(bytes : Bytes?, needle : String) : {Obj, String}?
      return nil unless bytes && bytes.size <= MAX_BODY
      doc(String.new(bytes), needle)
    end

    private def doc(text : String, needle : String) : {Obj, String}?
      return nil unless text.includes?(needle)
      # Scrubbed only when it is invalid: the
      # stdlib `String#scrub` rebuilds even a valid string (`Utf8.subject`).
      text = Utf8.subject(text)
      obj(RawJson.parse_typed(text)).try { |o| {o, text} }
    rescue JSON::ParseException
      nil
    end

    # :nodoc: — the value at `steps` in `raw` as compact JSON TEXT, numbers as sent (see the
    # module header); nil when absent. `raw` already parsed once, so a raise here is not
    # expected — but a display lens never throws over one value.
    def raw_at(raw : String, steps : Array(Step)) : String?
      JsonPath.raw_at(raw, steps)
    rescue JSON::ParseException
      nil
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
      # Usage members as raw JSON values, numbers as sent (see the module header).
      @usage = {} of String => String
      # The text of the document being fed, for the subtrees shown as JSON.
      @raw = ""
      # Whether any reply carried one of the three shapes at all.
      getter? shaped = false

      def initialize(@dialect : String, @model : String?)
      end

      # See `LlmCall.stream_reply`.
      def raw_reply : String
        String.build do |io|
          io << @text.to_s
          @tools.to_a.sort_by!(&.[0]).each { |(_, (name, args))| io << '\n' << name << '\n' << args.to_s }
        end
      end

      def call(roles : String, tools : Array(String), streamed : Bool) : Call
        calls = @tools.to_a.sort_by!(&.[0]).map { |(_, (name, args))| ToolCall.new(name, pretty(args.to_s)) }
        Call.new(@dialect, @model, roles, tools, streamed, @text.to_s, calls, @stop,
          @usage.empty? ? nil : RawJson.object(@usage.to_a))
      end

      # `r` read from `raw`, the event's or body's text.
      def feed(r : Obj, raw : String) : Nil
        @raw = raw
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
          LlmCall.obj(r["response"]?).try { |x| responses(x, [key("response")]) }
        elsif type.starts_with?("response.")
          response_event(type, r)
        end
      end

      # Any Responses event shapes the reply, so a stream cut off mid-call still decodes. A
      # function call is keyed by `output_index`, the slot `response.completed` uses.
      private def response_event(type : String, r : Obj) : Nil
        @dialect = RESPONSES
        @shaped = true
        i = LlmCall.index(r["output_index"]?, 0)
        case type
        when "response.output_text.delta"
          @text << LlmCall.str(r["delta"]?)
        when "response.output_item.added"
          item = LlmCall.obj(r["item"]?) || return
          tool(i, LlmCall.str(item["name"]?), nil) if item["type"]? == "function_call"
        when "response.function_call_arguments.delta"
          tool(i, nil, LlmCall.str(r["delta"]?))
        end
      end

      # One completion or one chunk: the first choice's `message` or `delta`, the same fields
      # either way. Picked by `index`, since a chunk of an `n>1` stream carries another choice.
      private def chat(r : Obj) : Nil
        @dialect = CHAT
        @shaped = true
        usage(r["usage"]?, [key("usage")])
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
          # The RAW index: the slot, and the step to the block's text. `objs` compacts away a
          # non-object block, which would read the next block's `input` for this one.
          # Every input read in one pass over the body, not one `raw_at` per tool_use block.
          inputs = LlmCall.objs(r["content"]?).any? { |b| b["type"]? == "tool_use" } ? content_inputs : nil
          r["content"]?.try(&.as_a?).try &.each_with_index do |v, i|
            LlmCall.obj(v).try { |b| block(i, b) { inputs.try(&.input[i]?) } }
          end
          stop(r)
          usage(r["usage"]?, [key("usage")])
        when "message_start"
          msg = LlmCall.obj(r["message"]?) || return
          @model = LlmCall.str(msg["model"]?) || @model
          usage(msg["usage"]?, [key("message"), key("usage")])
        when "content_block_start"
          LlmCall.obj(r["content_block"]?).try do |b|
            block(LlmCall.index(r["index"]?, 0), b, streamed: true) { LlmCall.raw_at(@raw, [key("content_block"), key("input")]) }
          end
        when "content_block_delta"
          d = LlmCall.obj(r["delta"]?) || return
          @text << LlmCall.str(d["text"]?)
          LlmCall.str(d["partial_json"]?).try { |j| tool(LlmCall.index(r["index"]?, 0), nil, j) }
        when "message_delta"
          LlmCall.obj(r["delta"]?).try { |d| stop(d) }
          usage(r["usage"]?, [key("usage")])
        end
      end

      # The block yields its `input` as raw JSON text, read only for a tool_use that has one.
      private def block(i : Int32, b : Obj, streamed = false, &) : Nil
        case LlmCall.str(b["type"]?)
        when "text"
          @text << LlmCall.str(b["text"]?)
        when "tool_use"
          input = LlmCall.obj(b["input"]?)
          # A streamed block opens with `input: {}` and fills it from `input_json_delta`s; in a
          # whole message `{}` is the real (empty) input.
          args = input.nil? || (streamed && input.empty?) ? nil : yield
          tool(i, LlmCall.str(b["name"]?), args)
        end
      end

      private def stop(r : Obj) : Nil
        @stop = LlmCall.str(r["stop_reason"]?) || @stop
      end

      # `at` is where `r` sits in the document: the root, or the `response.completed` payload.
      private def responses(r : Obj, at = [] of Step) : Nil
        @dialect = RESPONSES
        @shaped = true
        @model = LlmCall.str(r["model"]?) || @model # also reached for the nested `response.completed` payload
        @stop = LlmCall.str(r["status"]?) || @stop
        usage(r["usage"]?, at + [key("usage")])
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
      # `message_start` reported early. Read as raw text at `at`, so a counter past Int64 is
      # shown as the number it is rather than quoted.
      private def usage(u : JSON::Any?, at : Array(Step)) : Nil
        return unless LlmCall.obj(u)
        raw = LlmCall.raw_at(@raw, at) || return
        RawJson.members(raw).try &.each { |(k, v)| @usage[k] = v }
      end

      # The body's top-level `content` (the last, if duplicated), read for its inputs.
      private def content_inputs : Inputs?
        pull = JSON::PullParser.new(RawJson.tolerant(@raw))
        return nil unless pull.kind.begin_object?
        inputs = nil.as(Inputs?)
        pull.read_object { |k| k == "content" ? (inputs = LlmCall.read_inputs(pull)) : pull.skip }
        inputs
      rescue JSON::ParseException
        nil
      end

      private def key(name : String) : Step
        Step.new(key: name)
      end

      # The model's arguments, pretty when they are JSON: numbers as it wrote them and a
      # duplicated key kept, since `{"a":1,"a":2}` is exactly what a parser-differential
      # payload looks like. `reformat` (not `reindent`) decodes escapes, so the non-ASCII
      # arguments OpenAI escapes stay readable.
      private def pretty(args : String) : String
        RawJson.reformat(RawJson.tolerant(args), "  ")
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
        c.usage.try { |u| io << "\n# usage: " << u }
        io << "\n\n" << c.text unless c.text.empty?
        c.tool_calls.each { |t| io << "\n\n# tool call " << t.name << '\n' << t.arguments }
      end
    end
  end
end
