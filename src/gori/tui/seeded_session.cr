module Gori::Tui
  # The request-side accessors of a seeded tool session: MinerView and SequencerView each hold
  # one seed request (`@target`, `@request`, `@http2`, `@sni`) behind no editor, and read it
  # back the same way, and seeds, restores and peer-syncs it the same way. Each view keeps its
  # own `summary` and `target_origin`, because the Sequencer's manual paste answers both
  # without a request, and its own `apply_config_json` for its own config type.
  module SeededSession
    property name : String?
    property job_id : Int32
    # PROVENANCE: `@request` is a CAPTURED FLOW's stored bytes (a History/Sitemap/Issues
    # seed), not something the operator drafted. Neither view has an editor at all —
    # `@request` is only ever assigned from a seed or from the store — so the flag is
    # decided once, at load, and there is no draft interpretation to fall back to.
    # See `Miner::PlanOptions#evidence?` / `Sequencer::PlanOptions#evidence?`.
    getter? evidence : Bool

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

    # Seed a fresh session from the config overlay (`config` is the view's own Config type).
    # `evidence` is the seed's `flow_id` having been non-nil (a History/Sitemap/Issues flow);
    # a Repeater-sourced or current-session seed is editor text the operator authored and
    # stays a draft.
    def load(target : String, request : Bytes, http2 : Bool, sni : String?,
             config, evidence : Bool = false) : Nil
      @target = target
      @request = request
      @http2 = http2
      @sni = sni || ""
      @config = config
      @evidence = evidence
      @dirty = true
    end

    # `rec` is the view's own `Store::MinerSessionRecord` / `Store::SequencerSessionRecord`.
    def restore(rec) : Nil
      @target = rec.target
      @request = rec.request
      @http2 = rec.http2?
      @sni = rec.sni || ""
      # Provenance survives a restart: `flow_id` is what `insert_*_session` already stored
      # for a flow-seeded session and nothing else sets it.
      @evidence = !rec.flow_id.nil?
      @name = rec.name
      apply_config_json(rec.config)
      @last_synced_config = rec.config
      @dirty = false
    end

    # Live cross-session request-side sync. Updates seed request/config WITHOUT
    # wiping focus, in-memory results, scroll/selection, or a running job.
    def apply_peer_session(rec) : Nil
      restore(rec) # the request-side fields only — focus, results and a running job are untouched
    end

    def session_side_matches?(rec) : Bool
      @target == rec.target &&
        @request == rec.request &&
        @http2 == rec.http2? &&
        (sni_override || "") == (rec.sni || "") &&
        (@name || "") == (rec.name || "") &&
        @last_synced_config == rec.config
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
