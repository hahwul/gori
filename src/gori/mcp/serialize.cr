require "json"
require "base64"
require "../store"
require "../replay/engine"
require "../proxy/codec/content_decode"

module Gori
  module MCP
    # Pure functions that render gori's store/replay structs into the JSON the MCP
    # tools return. The codebase builds JSON by hand (no JSON::Serializable), so we
    # follow suit with JSON.build. Bodies are decoded for display (de-chunk +
    # gzip/deflate/br/zstd via ContentDecode) and SUMMARISED — text when valid
    # UTF-8 (capped), base64 otherwise (capped). Byte-exact bodies are gori's own
    # replay/export job; MCP trades fidelity for a token budget the model can read.
    module Serialize
      MAX_TEXT = 64 * 1024 # cap on inlined decoded text
      MAX_B64  = 64 * 1024 # cap on raw bytes base64-encoded for binary bodies

      # --- list projection (History) ------------------------------------------
      def self.flow_row(j : JSON::Builder, row : Store::FlowRow) : Nil
        j.object do
          j.field "id", row.id
          j.field "created_at", row.created_at
          j.field "scheme", row.scheme
          j.field "method", row.method
          j.field "host", row.host
          j.field "port", row.port
          j.field "target", row.target
          j.field "status", row.status
          j.field "state", row.state.to_s.downcase
          j.field "size", row.size
          j.field "response_size", row.response_size
          j.field "duration_us", row.duration_us
          j.field "content_type", row.content_type
        end
      end

      # --- full detail incl. heads + decoded bodies ---------------------------
      def self.flow_detail_json(detail : Store::FlowDetail) : String
        JSON.build { |j| flow_detail(j, detail) }
      end

      def self.flow_detail(j : JSON::Builder, detail : Store::FlowDetail) : Nil
        row = detail.row
        j.object do
          j.field "id", row.id
          j.field "created_at", row.created_at
          j.field "scheme", row.scheme
          j.field "method", row.method
          j.field "host", row.host
          j.field "port", row.port
          j.field "target", row.target
          j.field "http_version", detail.http_version
          j.field "status", row.status
          j.field "state", row.state.to_s.downcase
          j.field "duration_us", row.duration_us
          j.field "content_type", row.content_type
          j.field "error", detail.error
          j.field "request_head", head_text(detail.request_head)
          emit_body(j, "request_body", detail.request_head, detail.request_body, detail.request_body_truncated?)
          j.field "response_head", head_text(detail.response_head)
          emit_body(j, "response_body", detail.response_head, detail.response_body, detail.response_body_truncated?)
        end
      end

      # --- findings -----------------------------------------------------------
      def self.finding(j : JSON::Builder, f : Store::Finding) : Nil
        j.object do
          j.field "id", f.id
          j.field "created_at", f.created_at
          j.field "updated_at", f.updated_at
          j.field "title", f.title
          j.field "severity", f.severity.label
          j.field "status", f.status.label
          j.field "host", f.host
          j.field "flow_id", f.flow_id
          j.field "notes", f.notes
        end
      end

      # --- replay / send_request response -------------------------------------
      def self.replay_result_json(r : Replay::Result) : String
        JSON.build do |j|
          j.object do
            if resp = r.response
              j.field "status", resp.status
              j.field "reason", resp.reason
              j.field "http_version", resp.version
              j.field "headers" do
                j.array do
                  resp.headers.each do |h|
                    j.object { j.field "name", h.name; j.field "value", h.value }
                  end
                end
              end
            end
            j.field "duration_us", r.duration_us
            emit_body(j, "body", r.head, r.body, false)
          end
        end
      end

      # Heads are short and ASCII-ish; render as (lossy-on-display) text. nil head
      # (e.g. a Pending flow's response) becomes JSON null. `scrub` guards a
      # malformed/binary head from emitting invalid UTF-8 that would corrupt the
      # JSON-RPC line.
      def self.head_text(head : Bytes?) : String?
        head ? String.new(head).scrub : nil
      end

      # Emits a `field_name` field carrying a decoded-body summary. nil/empty body
      # → JSON null. Otherwise an object: {encoding, size, truncated, text|base64,
      # note?}. `wire_truncated` reflects gori's capture cap on the stored bytes.
      def self.emit_body(j : JSON::Builder, field_name : String, head : Bytes?, body : Bytes?, wire_truncated : Bool) : Nil
        if body.nil? || body.empty?
          j.field field_name, nil
          return
        end
        decoded, note = Proxy::Codec::ContentDecode.decode(head, body)
        bytes = decoded || body
        s = String.new(bytes)
        j.field field_name do
          j.object do
            if s.valid_encoding?
              cut = bytes.size > MAX_TEXT
              j.field "encoding", "text"
              j.field "size", bytes.size
              j.field "truncated", cut || wire_truncated
              # byte_slice can sever a multi-byte codepoint at the cap → scrub the
              # partial tail so the JSON line stays valid UTF-8.
              j.field "text", cut ? s.byte_slice(0, MAX_TEXT).scrub : s
            else
              cut = bytes.size > MAX_B64
              slice = cut ? bytes[0, MAX_B64] : bytes
              j.field "encoding", "base64"
              j.field "binary", true
              j.field "size", bytes.size
              j.field "truncated", cut || wire_truncated
              j.field "base64", Base64.strict_encode(slice)
            end
            j.field "note", note if note
          end
        end
      end
    end
  end
end
