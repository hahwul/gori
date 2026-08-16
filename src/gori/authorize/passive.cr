require "../store/models"
require "../proxy/codec/http1"

module Gori
  module Authorize
    # Which captured flows passive replay will pick up, and how they are keyed.
    #
    # Passive replay puts real requests on a real target without anyone pressing anything, so
    # what it declines to replay matters as much as what it replays.
    module Passive
      # The headers that make a request worth testing. A request carrying NO session is
      # already the anonymous case — replaying it under an anonymous identity compares a
      # thing to itself, and the queue fills with rows that can only ever read `same`.
      AUTH_HEADERS = {"Cookie", "Authorization"}

      # Methods replayed without asking. A replayed POST/PUT/PATCH/DELETE runs the side effect
      # AGAIN, once per identity — passive replay is unattended, so the operator never gets to
      # decide that a second checkout, transfer or delete is acceptable. The manual queue takes
      # any method, because there a human chose the request.
      SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}

      # Whether this flow is one passive replay should test.
      def self.replayable?(detail : Store::FlowDetail) : Bool
        row = detail.row
        return false unless row.state.complete?
        return false if row.short_circuited? # gori answered it; there is no origin behind it
        return false unless SAFE_METHODS.includes?(row.method.upcase)
        carries_auth?(detail.request_head)
      end

      # Does the request head carry a session? Parsed through the codec rather than scanned as
      # text: a `Cookie` fold, odd casing and a body that happens to contain the word are all
      # things a substring search gets wrong, and `HeaderList#has?` is already case-insensitive.
      def self.carries_auth?(head : Bytes) : Bool
        req = Proxy::Codec::Http1.parse_request_head(head)
        AUTH_HEADERS.any? { |name| req.headers.has?(name) }
      rescue
        false # an unparseable head is not a request we can reason about
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
