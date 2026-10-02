module Gori::Tui
  # The request-side accessors of a seeded tool session: MinerView and SequencerView each hold
  # one seed request (`@target`, `@request`, `@http2`, `@sni`) behind no editor, and read it
  # back the same way. Each view keeps its own `summary` and `target_origin`, because the
  # Sequencer's manual paste answers both without a request.
  module SeededSession
    # "METHOD path" from the request's first line, or "request" when it has neither. Unclipped:
    # a seed's summary is the whole of it, and a view's `summary` clips it to a chip.
    def self.request_summary(bytes : Bytes) : String
      parts = request_line(bytes).strip.split(' ')
      s = "#{parts[0]?} #{parts[1]?}".strip
      s.empty? ? "request" : s
    end

    def self.request_line(bytes : Bytes) : String
      String.new(bytes[0, {bytes.size, 256}.min]).each_line.first? || ""
    end

    def self.clip(s : String, max : Int32) : String
      s.size > max ? "#{s[0, max - 1]}…" : s
    end

    # --- persistence accessors ---
    def request_bytes : Bytes
      @request
    end

    def http2? : Bool
      @http2
    end

    def sni_override : String?
      s = @sni.strip
      s.empty? ? nil : s
    end

    def dirty? : Bool
      @dirty
    end

    def clear_dirty : Nil
      @dirty = false
    end

    def mark_config_synced(config : String) : Nil
      @last_synced_config = config
    end

    def request_line : String
      SeededSession.request_line(@request)
    end

    # HTTP method from the request line — feeds the sub-tab filter's `method:`.
    def request_method : String
      request_line.strip.split(' ').first? || ""
    end

    def label(max : Int32 = 18) : String
      if (n = @name) && !(t = n.strip).empty?
        return SeededSession.clip(t, max)
      end
      summary(max)
    end

    # The session target as stored (scheme://host[:port]) — feeds Repeater seeds.
    def target : String
      @target
    end
  end
end
