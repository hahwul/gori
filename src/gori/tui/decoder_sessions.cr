require "json"

module Gori::Tui
  # The wire form of the Decoder tab's open sub-tabs, stored per project under
  # `Store::DECODER_SESSIONS_KEY`. Kept out of DecoderController so the codec is testable
  # without a live Host/Session, and tolerant on read for the same reason the settings.json
  # parser is: the value is a plain row in the project db that a person can hand-edit.
  #
  # Shape: `[{"input": "...", "chain": "...", "name": "..."}]`.
  module DecoderSessions
    alias Tuple3 = {String, String, String}

    # Malformed JSON, a non-array, or a non-object entry yields nothing rather than raising:
    # a corrupt row must cost the operator their restored sub-tabs, never the whole tab.
    # Missing fields default to "" (a blank session is valid — an empty sub-tab).
    def self.parse(raw : String) : Array(Tuple3)
      # NOT named `out` — that is a Crystal keyword, and `return out unless …` is a parse
      # error (the settings.json parser gets away with it only by never using `return`).
      sessions = [] of Tuple3
      arr = begin
        JSON.parse(raw).as_a?
      rescue JSON::ParseException
        nil
      end
      return sessions unless arr
      arr.each do |e|
        next unless o = e.as_h?
        input = o["input"]?.try(&.as_s?) || ""
        chain = o["chain"]?.try(&.as_s?) || ""
        name = o["name"]?.try(&.as_s?) || ""
        sessions << {input, chain, name}
      end
      sessions
    end

    # `name` is omitted when unset, mirroring the legacy serializer.
    def self.to_json(sessions : Array(Tuple3)) : String
      JSON.build do |j|
        j.array do
          sessions.each do |(input, chain, name)|
            j.object do
              j.field "input", input
              j.field "chain", chain
              j.field "name", name unless name.empty?
            end
          end
        end
      end
    end
  end
end
