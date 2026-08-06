require "./issue"
require "../store"
require "../oast"

module Gori
  module Probe
    # The out-of-band half of the active scanner: the seam between a rule that plants an OAST
    # payload and the callback that proves the target used it.
    #
    # Every other active rule closes its own loop — it writes a request and reads the answer on
    # the same socket. A blind vulnerability has no answer on that socket by definition: the
    # evidence is a DNS/HTTP request the TARGET makes to a third-party interaction server,
    # arriving seconds to hours later through a channel gori is not a party to. So the check is
    # split in two, and neither half knows about the other except through this module:
    #
    #   * PLANT (`Minter`) — at plan time a rule asks for a payload. Minting is a LOCAL call
    #     (`Oast::Provider#generate_payload` is network-free by invariant), so a rule stays a
    #     pure function of (flow, opts) and the planning path keeps costing no sockets. The rule
    #     attaches a `Candidate` to its Plan saying what finding this payload would prove.
    #   * PROMOTE (`.sweep`) — later, a callback carrying that payload's token lands in
    #     `oast_callbacks` (written by whichever surface is polling: the TUI's OAST listener,
    #     `gori run oast`, the MCP tools). The sweep matches it to the stored probe and emits
    #     the Detection.
    #
    # Nothing is emitted on the plant alone. A payload going out is not a finding — the whole
    # value of an out-of-band check is that the target either called home or it didn't — so an
    # unmatched row stays unmatched and says nothing.
    #
    # Named OutOfBand rather than Oast because `Gori::Probe::Oast` would put an `Oast` constant
    # inside `Gori::Probe`, where every existing `Oast::` reference resolves lexically and would
    # silently start pointing at this module instead of the engine.
    module OutOfBand
      # Shortest token the sweep will trust to attribute a callback. Every provider's nonce is
      # at least 8 chars (postbin's is exactly 8); a shorter one is a mis-mint, not a real token.
      TOKEN_MIN = 6

      # What a rule attaches to its Plan: the payload it planted and the finding a callback for
      # that payload would prove. `token` is the provider-minted nonce (see
      # `Oast::Provider#payload_token`) and is the ONLY thing tying a later callback to this
      # request, so it is stored as the row's unique key.
      record Candidate,
        token : String,
        payload : String,
        session_id : Int64,
        code : String,
        title : String,
        severity : Store::Severity,
        evidence : String? = nil,
        category : String = Category::ACTIVE

      # Hands a rule a fresh payload. Abstract so a spec can drive an OAST rule with a
      # deterministic payload and no oast_sessions row at all.
      abstract class Minter
        # A fresh payload, or nil when this minter can no longer produce one. Never raises:
        # a rule calls it on the planning path, where an exception would take the rule out.
        abstract def mint : {String, String, Int64}?
      end

      # The real minter: mints from a registered `oast_sessions` row.
      #
      # It reads the session ONCE, at build time, and rebuilds its `Oast::Provider` from the
      # stored row — every provider persists its own normalized base URL as `server_url`, so the
      # session alone reconstructs a provider that mints the same payload shape the live
      # listener does. No provider CONFIG lookup, and so no dependence on the config still
      # existing: a session outlives the provider row it was registered through (the operator
      # can delete or re-scope the provider), and a probe minted against a live server should
      # not stop working because the bookkeeping around it moved.
      class StoreMinter < Minter
        getter session_id : Int64

        # nil when this project has no OAST session to mint from — the ordinary state, and the
        # reason every OAST rule plans nothing rather than erroring. The NEWEST session wins:
        # sessions accumulate across a project's life and only the most recent one is plausibly
        # still being polled, so an older row would mint payloads whose callbacks nobody reads.
        def self.build(store : Store) : StoreMinter?
          rec = store.oast_sessions.last?
          return nil unless rec
          kind = Oast::ProviderKind.parse?(rec.kind)
          return nil unless kind
          provider = Oast::Provider.build(kind, rec.server_url, rec.token)
          session = Oast::Session.new(rec.id, kind, rec.server_url, rec.correlation_id,
            rec.secret, private_key_pem: rec.private_key_pem, token: rec.token, registered: true)
          new(provider, session)
        rescue DB::Error | SQLite3::Exception
          nil
        end

        def initialize(@provider : Oast::Provider, @session : Oast::Session)
          @session_id = @session.id
        end

        def mint : {String, String, Int64}?
          payload = @provider.generate_payload(@session)
          token = @provider.payload_token(payload)
          return nil if token.empty?
          {payload, token, @session_id}
        rescue
          nil
        end
      end

      # Persist one outstanding probe. THE writer — the TUI analyzer and the headless scan both
      # come through here, so the two cannot drift on what a plant records (they are separate
      # send loops that look like one, which is exactly how the verbatim-marking defect this
      # module sits next to survived for months).
      #
      # `flow_id` is passed rather than read off `row`, because a Repeater-sourced detail has a
      # synthetic row id that is not a flow. Store failures are swallowed: an unrecordable probe
      # costs one missed finding, while raising would report the whole probe as errored.
      def self.record(store : Store, rule_id : String, c : Candidate, row : Store::FlowRow,
                      flow_id : Int64?) : Nil
        store.insert_probe_oast_probe(c.token, c.payload, c.session_id, rule_id, c.code,
          c.category, c.title, c.severity, row.host, row.url, c.evidence,
          (flow_id && flow_id > 0) ? flow_id : nil)
      rescue DB::Error | SQLite3::Exception
      end

      # Fold every OAST callback newer than `since_id` against this project's outstanding
      # probes, promoting each match to a Detection. Returns {detections, new watermark}.
      #
      # The watermark is the caller's, not the store's, and starting from 0 is correct on a cold
      # start: callbacks and probes both persist, so a payload planted in one run and answered
      # while gori was closed is matched on the next sweep. After that first full pass the
      # watermark makes each tick read only what arrived since.
      #
      # `mark_probe_oast_matched` is what makes a promotion happen exactly once — it is a
      # conditional UPDATE, so two surfaces sweeping the same project (the TUI's timer and a
      # headless `gori run probe`) cannot both emit the issue.
      def self.sweep(store : Store, since_id : Int64) : {Array(Detection), Int64}
        out = [] of Detection
        callbacks = store.oast_callbacks_since(since_id)
        return {out, since_id} if callbacks.empty?
        watermark = since_id
        callbacks.each { |cb| watermark = cb.id if cb.id > watermark }
        pending = store.probe_oast_pending
        return {out, watermark} if pending.empty?
        # Lower-case both sides once. The token is already lower-case (payload_token guarantees
        # it) and the haystack may not be: DNS 0x20 case randomization means the resolver echoes
        # the payload host back in mixed case, and a byte-exact comparison would miss the one
        # protocol an out-of-band check most often lands on.
        haystacks = callbacks.map { |cb| "#{cb.full_id}\n#{String.new(cb.raw_request)}".downcase }
        pending.each do |p|
          # A token is a unique-per-mint nonce, so the only callback that carries it is the one
          # this probe drew. Guard against a pathologically short token (a mis-minted or truncated
          # value) matching arbitrary callback bytes by coincidence: every real provider mints ≥ 8
          # chars, so anything shorter is not a token we should trust to attribute a finding.
          next if p.token.size < TOKEN_MIN
          idx = haystacks.index(&.includes?(p.token))
          next unless idx
          next unless store.mark_probe_oast_matched(p.id)
          out << detection_for(p, callbacks[idx])
        end
        {out, watermark}
      end

      # The promoted finding. Evidence names the protocol and the source the callback came
      # from, appended to whatever the rule recorded at plant time (the parameter it used), so
      # the issue reads as the full round trip rather than as either half of it.
      private def self.detection_for(p : Store::ProbeOastRecord,
                                     cb : Store::OastCallbackRecord) : Detection
        hit = "#{cb.protocol.upcase} callback from #{cb.source_ip || "an unknown source"}"
        evidence = (ev = p.evidence) ? "#{ev} → #{hit}" : hit
        Detection.new(p.code, p.category, p.host, p.url, p.title, p.severity,
          evidence: evidence, flow_id: p.flow_id)
      end
    end
  end
end
