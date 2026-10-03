module Gori
  module Repeater
    # The status · size · time of ONE exchange, and the A→B delta between two of them.
    #
    # A comparison's first answer is usually not in the body at all: a 403 against a 200, a
    # response that grew by sixteen bytes, one that took ten times as long. Reading it used
    # to mean going back to History for each side and doing the subtraction by hand.
    #
    # Core rather than TUI because all three surfaces state it — the Comparer's header and
    # divider, `gori run compare`, MCP `compare_flows` — and a byte count that rounds one way
    # in the terminal and another in JSON is two different facts about one response.
    struct ExchangeMeta
      getter status : Int32?      # nil when there is none (errored, or request-only)
      getter status_text : String # "200" | "ERR" | "ABT" | "···" | "—"
      getter size : Int64?        # response bytes on the wire (nil = unknown)
      getter duration_us : Int64? # request→response latency (nil = unmeasured)

      def initialize(@status, @status_text, @size, @duration_us)
      end

      # From a captured flow row. `state` decides the label before `status` does: an errored
      # flow carries status 0, which would print as a cryptic "0".
      def self.of(row : Store::FlowRow) : ExchangeMeta
        text = if row.state.error?
                 "ERR"
               elsif row.state.aborted?
                 "ABT"
               else
                 row.status.try(&.to_s) || "···"
               end
        new(row.status, text, row.response_size, row.duration_us)
      end

      # From a live send that was never captured — a Repeater send, a fuzz result.
      def self.of(status : Int32?, size : Int64?, duration_us : Int64?, error : String?) : ExchangeMeta
        text = error && !error.empty? ? "ERR" : (status.try(&.to_s) || "—")
        new(status, text, size, duration_us)
      end

      def errored? : Bool
        @status_text == "ERR" || @status_text == "ABT"
      end

      # The one-line readout. Fields this source cannot name are dropped, not zeroed: "0 B"
      # is a claim about the origin that nothing observed.
      def line : String
        parts = [@status_text]
        if s = @size
          parts << Format.bytes(s)
        end
        if d = @duration_us
          parts << Format.duration_us(d)
        end
        parts.join(" · ")
      end

      # What CHANGED from `a` to `b`, or nil when neither side can name a single field.
      # A status that did NOT change is still stated — "status 200" is the context the size
      # and time deltas are read against.
      def self.delta(a : ExchangeMeta, b : ExchangeMeta) : String?
        parts = [] of String
        if a.status_text != b.status_text
          parts << "status #{a.status_text} → #{b.status_text}"
        elsif a.status
          parts << "status #{a.status_text}"
        end
        if (sa = a.size) && (sb = b.size)
          d = sb - sa
          parts << (d == 0 ? "size same" : "size #{signed(d) { |n| Format.bytes(n) }}")
        end
        if (da = a.duration_us) && (db = b.duration_us)
          d = db - da
          parts << (d == 0 ? "time same" : "time #{signed(d) { |n| Format.duration_us(n) }}")
        end
        parts.empty? ? nil : "Δ #{parts.join(" · ")}"
      end

      private def self.signed(d : Int64, &fmt : Int64 -> String) : String
        "#{d > 0 ? "+" : "-"}#{fmt.call(d.abs)}"
      end

      # Byte and duration formatting for the readout. Short forms on purpose: this rides a
      # half-width column header.
      module Format
        extend self

        def bytes(n : Int64) : String
          return "#{n} B" if n < 1024
          kb = n / 1024.0
          return "#{fmt(kb)} KB" if kb < 1024
          "#{fmt(kb / 1024.0)} MB"
        end

        def duration_us(us : Int64) : String
          return "#{us} µs" if us < 1000
          ms = us / 1000.0
          return "#{fmt(ms)} ms" if ms < 1000
          "#{fmt(ms / 1000.0)} s"
        end

        # One decimal below 10, none above — "9.4 KB" but "312 KB", so the readout keeps a
        # steady width instead of swinging between "1023.7 KB" and "8 KB".
        private def fmt(v : Float64) : String
          v < 10 ? sprintf("%.1f", v) : v.round.to_i64.to_s
        end
      end
    end
  end
end
