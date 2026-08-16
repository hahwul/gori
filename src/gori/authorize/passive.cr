require "../store/models"
require "./identity"

module Gori
  module Authorize
    # Which captured flows passive replay picks up, why it declines the rest, and how it keys
    # them. Passive puts real requests on a real target without anyone pressing a key, so what
    # it declines matters as much as what it takes — and every refusal is NAMED, because the
    # failure mode of an unattended feature is looking broken while working as designed.
    module Passive
      # Methods replayed without asking. A replayed POST/PUT/PATCH/DELETE runs the side effect
      # AGAIN, once per identity, and passive is unattended — the operator never gets to decide
      # that a second checkout, transfer or delete is acceptable. The manual queue takes any
      # method, because there a human chose the request.
      SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}

      # Why this flow will not be replayed, or nil when it will be.
      #
      # `:no_effect` is the interesting one, and it replaced a "does the request carry a Cookie
      # or Authorization header?" test. That heuristic asked the wrong question twice over: it
      # missed APIs authenticating through `X-Api-Key` and friends, and on a site the operator
      # was not logged into it skipped everything while saying nothing.
      #
      # The exact question is whether any identity would CHANGE this request. If none does,
      # every trial sends identical bytes, the responses match by construction, and the row
      # reads `⚠ same` — a finding manufactured out of nothing. That is worse than skipping:
      # a public site would light up red on every page. Asking it this way also fixes itself
      # the moment the operator adds an identity that sets a session.
      def self.skip_reason(detail : Store::FlowDetail,
                           identities : Array(Identity)) : Symbol?
        row = detail.row
        return :incomplete unless row.state.complete?
        return :short_circuited if row.short_circuited? # gori answered it; no origin behind it
        return :unsafe_method unless SAFE_METHODS.includes?(row.method.upcase)
        return :no_effect unless any_identity_changes?(detail, identities)
        nil
      end

      def self.replayable?(detail : Store::FlowDetail, identities : Array(Identity)) : Bool
        skip_reason(detail, identities).nil?
      end

      # Does at least one NON-baseline identity produce different bytes than the baseline does?
      # Compared against the baseline rather than against the raw capture, because the baseline
      # may itself carry an overlay — what a run compares is baseline-vs-other, so that is what
      # decides whether there is anything to compare.
      def self.any_identity_changes?(detail : Store::FlowDetail,
                                     identities : Array(Identity)) : Bool
        return false if identities.size < 2
        head = detail.request_head
        base_id = identities.find(&.baseline?) || identities.first
        base = Authorize.overlay_head(head, base_id)
        identities.any? do |id|
          next false if id.same?(base_id)
          Authorize.overlay_head(head, id) != base
        end
      end

      # A human sentence for a skip reason, for the readout the tab carries.
      def self.reason_label(reason : Symbol) : String
        case reason
        when :no_effect       then "no identity changes them"
        when :unsafe_method   then "not a safe method to repeat"
        when :incomplete      then "never completed"
        when :short_circuited then "answered by gori"
        when :out_of_scope    then "outside project scope"
        when :duplicate       then "already queued"
        else                       reason.to_s
        end
      end

      # The dedup key for passive seeding: METHOD + URL, not the flow id.
      #
      # The manual queue dedups by flow id because sending the same capture twice is a
      # re-marking accident. Passive sees a NEW flow every time the browser fetches the page,
      # so a flow-id key would add a row per page load and the queue would be a traffic log.
      # Keying on the endpoint means a session's tenth visit to `/orders` does not requeue it,
      # while `/orders?id=2` — a different resource — still gets its own row.
      def self.key(detail : Store::FlowDetail) : String
        "#{detail.row.method.upcase} #{detail.row.url}"
      end
    end
  end
end
