require "./rule"
require "./secrets"

module Gori
  module Probe
    module Passive
      # WebSocket text-frame secrets (category "infoleak"). Scans captured post-101
      # text messages (both directions) with the same high-confidence credential shapes
      # as BodyLeaks — evidence is the TYPE label only, never the matched value.
      class WsPayloads < Rule
        MSG_CAP = 64 * 1024 # per-message ceiling (mirrors Context::BODY_CAP)

        def check(ctx : Context, acc : Array(Detection)) : Nil
          return if ctx.ws_messages.empty?
          seen = Set(String).new # distinct type labels per flow (avoid ×N from echo/repeater)
          ctx.ws_messages.each do |msg|
            next unless msg.text?
            text = payload_text(msg.payload)
            next if text.nil? || text.empty?
            Secrets::PATTERNS.each do |(pat, label)|
              next if seen.includes?(label)
              next unless pat.matches?(text)
              seen << label
              acc << Detection.new("secret_in_ws", Category::INFOLEAK, ctx.host, ctx.url,
                "Credential/secret disclosed in WebSocket message", Store::Severity::High,
                label, ctx.fid)
            end
          end
        end

        private def payload_text(payload : Bytes) : String?
          return nil if payload.empty?
          String.new(payload[0, {payload.size, MSG_CAP}.min]).scrub
        end
      end
    end
  end
end
