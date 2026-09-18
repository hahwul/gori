require "json"
require "./event"

module Gori::Agent::Claude
  # Claude Code's stream-json stdio protocol, both directions, as pure functions (#1093).
  # `claude -p --input-format stream-json --output-format stream-json` speaks one compact JSON
  # object per line on each pipe; this module turns an inbound line into `Event`s and builds
  # the outbound frames. No IO, no Process, no state — `Session` owns those, and a spec drives
  # this from the recorded lines under `spec/fixtures/agent/`.
  #
  # The contract that shapes every branch below: **an unknown `type` is ignored, never an
  # error.** That is Claude Code's stated forward-compatibility rule for this stream, and it is
  # why `parse` answers an Array (one `assistant` frame carries several content blocks, and
  # silence is `[]`) rather than raising on what it does not recognise. Version gating, where
  # gori needs it, reads `system/init`'s `capabilities` strings — never `claude --version`.
  #
  # Verified against CLI 2.1.276. Frames seen in a turn, in order: `system/hook_*` (optional),
  # `system/init` (EVERY turn — see `Event::TurnStarted`), `system/status`, `rate_limit_event`,
  # `system/thinking_tokens`, a run of `stream_event`s, an `assistant` per message, a `user`
  # per tool result, and one `result`. A `control_request` can land anywhere inside that run.
  module Protocol
    # How much of an unparseable line `Event::Raw` keeps. Enough to read what it was, not
    # enough for one bad line to become the transcript's largest row.
    RAW_KEEP = 4096

    # Inbound: one line → zero or more events. Never raises — a line this cannot read is an
    # `Event::Raw`, because the child is still running and the next line may be fine.
    def self.parse(line : String) : Array(Event::Any)
      json = JSON.parse(line)
      obj = json.as_h?
      return [raw(line)] of Event::Any unless obj
      case obj["type"]?.try(&.as_s?)
      when "system"          then parse_system(obj)
      when "stream_event"    then parse_stream_event(obj)
      when "assistant"       then parse_assistant(obj)
      when "user"            then parse_user(obj)
      when "result"          then parse_result(obj)
      when "control_request" then parse_control_request(obj, line)
      else
        # `rate_limit_event`, `control_response` (the echo of our own interrupt), and whatever
        # a newer CLI adds. Ignored by contract.
        [] of Event::Any
      end
    rescue JSON::ParseException | TypeCastError | KeyError
      [raw(line)] of Event::Any
    end

    # Outbound: a user turn.
    def self.user_turn(text : String) : String
      JSON.build do |j|
        j.object do
          j.field "type", "user"
          j.field "message" do
            j.object do
              j.field "role", "user"
              j.field "content" do
                j.array { j.object { j.field "type", "text"; j.field "text", text } }
              end
            end
          end
        end
      end
    end

    # Outbound: the answer to a `can_use_tool` request. `input_json` is echoed back as
    # `updatedInput` on allow (the CLI requires the field; a nil or unreadable input becomes
    # an empty object, which the CLI treats as "run it as proposed"). On deny, `message` is
    # what the model reads as the tool's error, so it should say who refused.
    def self.permission_response(request_id : String, allow : Bool, input_json : String?,
                                 message : String?) : String
      JSON.build do |j|
        j.object do
          j.field "type", "control_response"
          j.field "response" do
            j.object do
              j.field "subtype", "success"
              j.field "request_id", request_id
              j.field "response" do
                j.object do
                  if allow
                    j.field "behavior", "allow"
                    j.field "updatedInput" { j.raw(object_json(input_json)) }
                  else
                    j.field "behavior", "deny"
                    j.field "message", message.presence || "denied by the operator in gori"
                  end
                end
              end
            end
          end
        end
      end
    end

    # Outbound: cancel the running turn. The CLI answers with a `result` whose subtype is an
    # error — an ordinary `TurnDone` — but only on a build that advertises
    # `interrupt_receipt_v1`; the session gates on that and falls back to a stop otherwise.
    def self.interrupt(request_id : String) : String
      JSON.build do |j|
        j.object do
          j.field "type", "control_request"
          j.field "request_id", request_id
          j.field "request" { j.object { j.field "subtype", "interrupt" } }
        end
      end
    end

    private def self.raw(line : String) : Event::Raw
      truncated = line.bytesize > RAW_KEEP
      kept = truncated ? String.new(line.to_slice[0, RAW_KEEP]).scrub : line
      Event::Raw.new(kept, truncated)
    end

    # `updatedInput` must be an object. Anything else we were handed (nil, an array, garbage
    # from a `Raw` line) collapses to `{}` rather than into a frame the CLI would reject.
    private def self.object_json(input_json : String?) : String
      return "{}" unless input_json
      JSON.parse(input_json).as_h? ? input_json : "{}"
    rescue JSON::ParseException
      "{}"
    end

    private def self.parse_system(obj : Hash(String, JSON::Any)) : Array(Event::Any)
      return [] of Event::Any unless obj["subtype"]?.try(&.as_s?) == "init"
      caps = obj["capabilities"]?.try(&.as_a?).try(&.compact_map(&.as_s?)) || [] of String
      [Event::TurnStarted.new(str(obj, "session_id"), str(obj, "model"), caps)] of Event::Any
    end

    private def self.parse_stream_event(obj : Hash(String, JSON::Any)) : Array(Event::Any)
      # A sub-agent's stream (non-null `parent_tool_use_id`) is the child's own business; the
      # tab shows the top-level conversation and the tool call that spawned it.
      return [] of Event::Any if nested?(obj)
      ev = obj["event"]?.try(&.as_h?)
      return [] of Event::Any unless ev && ev["type"]?.try(&.as_s?) == "content_block_delta"
      delta = ev["delta"]?.try(&.as_h?)
      return [] of Event::Any unless delta
      case delta["type"]?.try(&.as_s?)
      when "text_delta"     then [Event::TextDelta.new(str(delta, "text"))] of Event::Any
      when "thinking_delta" then [Event::ThinkingDelta.new(str(delta, "thinking"))] of Event::Any
      else                       [] of Event::Any # input_json_delta, signature_delta
      end
    end

    private def self.parse_assistant(obj : Hash(String, JSON::Any)) : Array(Event::Any)
      evs = [] of Event::Any
      return evs if nested?(obj)
      each_block(obj) do |block|
        case block["type"]?.try(&.as_s?)
        when "text"
          evs << Event::AssistantText.new(str(block, "text"))
        when "tool_use"
          input = block["input"]?
          evs << Event::ToolUse.new(str(block, "id"), str(block, "name"),
            input ? input.to_json : "{}")
        end
        # `thinking` blocks carry an empty string plus a signature; nothing to show.
      end
      evs
    end

    private def self.parse_user(obj : Hash(String, JSON::Any)) : Array(Event::Any)
      evs = [] of Event::Any
      return evs if nested?(obj)
      each_block(obj) do |block|
        next unless block["type"]?.try(&.as_s?) == "tool_result"
        evs << Event::ToolResult.new(str(block, "tool_use_id"), result_text(block["content"]?),
          block["is_error"]?.try(&.as_bool?) || false)
      end
      # A `user` frame with plain text blocks is the echo of our own turn
      # (`--replay-user-messages`); the transcript already holds it.
      evs
    end

    private def self.parse_result(obj : Hash(String, JSON::Any)) : Array(Event::Any)
      denials = obj["permission_denials"]?.try(&.as_a?).try(&.size) || 0
      cost = obj["total_cost_usd"]?.try(&.as_f?) || obj["total_cost_usd"]?.try(&.as_i?).try(&.to_f64) || 0.0
      [Event::TurnDone.new(str(obj, "subtype"), str(obj, "result"), cost, denials,
        str(obj, "session_id"))] of Event::Any
    end

    private def self.parse_control_request(obj : Hash(String, JSON::Any), line : String) : Array(Event::Any)
      req = obj["request"]?.try(&.as_h?)
      # Any other subtype (`hook_callback`, `mcp_message`, …) is a question we cannot answer,
      # and the CLI will wait for one: surfaced as Raw so the gap has a name in the transcript.
      return [raw(line)] of Event::Any unless req && req["subtype"]?.try(&.as_s?) == "can_use_tool"
      tool = str(req, "tool_name")
      input = req["input"]?
      [Event::PermissionAsked.new(str(obj, "request_id"), tool,
        req["display_name"]?.try(&.as_s?).presence || tool,
        input ? input.to_json : "{}",
        str(req, "description"), str(req, "decision_reason"), str(req, "tool_use_id"))] of Event::Any
    end

    private def self.each_block(obj : Hash(String, JSON::Any), &)
      content = obj["message"]?.try(&.as_h?).try(&.["content"]?).try(&.as_a?)
      return unless content
      content.each { |b| (h = b.as_h?) && yield h }
    end

    # A `tool_result` content is a string on the wire today, and the Messages API also allows
    # an array of blocks; take the text parts of either.
    private def self.result_text(content : JSON::Any?) : String
      return "" unless content
      if s = content.as_s?
        s
      elsif arr = content.as_a?
        arr.compact_map { |b| b.as_h?.try { |h| h["text"]?.try(&.as_s?) } }.join
      else
        content.to_json
      end
    end

    private def self.nested?(obj : Hash(String, JSON::Any)) : Bool
      !obj["parent_tool_use_id"]?.try(&.raw).nil?
    end

    private def self.str(h : Hash(String, JSON::Any), key : String) : String
      h[key]?.try(&.as_s?) || ""
    end
  end
end
