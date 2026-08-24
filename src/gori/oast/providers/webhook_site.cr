require "json"
require "../crypto"

module Gori::Oast
  # webhook.site: POST /token to mint a uuid, then GET its requests. Auth (optional) is an
  # `Api-Key` header. Payload = https://webhook.site/{uuid}[/nonce].
  class WebhookSite < Provider
    def initialize(host : String, token : String? = nil)
      super(ProviderKind::WebhookSite, host, token)
    end

    def register(http : Http) : Session
      body = {
        default_status:       200,
        default_content:      "Hello world!",
        default_content_type: "text/html",
      }.to_json
      resp = http.request("POST", "#{base_url}/token", api_key_headers(json: true), body)
      raise Gori::Error.new("webhook.site register: HTTP #{resp.status} #{snippet(resp.body)}") unless {200, 201}.includes?(resp.status)
      uuid = parse_json(resp.body)["uuid"]?.try(&.as_s?)
      raise Gori::Error.new("webhook.site register: no uuid in response") unless uuid
      # correlation_id carries the token uuid (used to build both the payload and poll URLs).
      Session.new(0_i64, ProviderKind::WebhookSite, base_url, uuid, "",
        token: @token, registered: true)
    end

    def generate_payload(session : Session) : String
      "#{base_url}/#{session.correlation_id}/#{Crypto.random_id(10)}"
    end

    # `sorting=newest` is about PAGINATION, not about the order we hand back: the endpoint
    # pages at 50, so asking for the oldest first would bury a live token's recent hits on a
    # page this poll never fetches. The batch is then flipped to oldest-first, which is the
    # order `Provider#poll` promises and the only one that reads right — three of these
    # arriving between two polls used to land in the callbacks table upside down (and would
    # keep that order after a reload, since the rows go into the DB in poll order).
    #
    # A non-200 RAISES rather than reading as an empty poll. webhook.site answers 404 for a
    # token that expired (free tokens do, on a timer and on a request count) and 401 for a
    # rotated api key — the two ways this listener quietly stops being a listener, and the
    # operator has no other signal that the hits stopped because nobody is listening.
    def poll(http : Http, session : Session) : Array(Interaction)
      resp = http.request("GET",
        "#{base_url}/token/#{session.correlation_id}/requests?sorting=newest",
        api_key_headers)
      unless resp.status == 200
        raise Gori::Error.new("webhook.site poll: HTTP #{resp.status} #{snippet(resp.body)}")
      end
      array_field(parse_json(resp.body), "data").compact_map { |it| to_interaction(it) }.reverse
    end

    private def api_key_headers(json : Bool = false) : Hash(String, String)
      h = {} of String => String
      h["Content-Type"] = "application/json" if json
      if (t = @token) && !t.empty?
        h["Api-Key"] = t
      end
      h
    end

    private def to_interaction(it : JSON::Any) : Interaction?
      return nil unless it.as_h?
      uid = field(it, "uuid") || Crypto.random_id(16)
      # The hit URL carries the per-payload nonce `generate_payload` minted
      # (`…/{uuid}/{nonce}`). `full_id` is "the destination sub-id shown in the table",
      # so prefer the URL over the request uuid. An empty-body GET — the canonical blind
      # SSRF callback — arrives with `content: ""`; `field` returns that empty string
      # (only JSON null is skipped), so `|| it.to_json` never fired and both raw_request
      # and full_id lost the nonce. Fall back to the URL (then the item JSON) when the
      # body is absent or blank so attribution survives.
      hit_url = field(it, "url")
      content = field(it, "content")
      raw = if content.nil? || content.empty?
              hit_url.presence || it.to_json
            else
              content
            end
      full_id = hit_url.presence || uid
      Interaction.new(uid, "http", field(it, "method"), field(it, "ip"), full_id, raw, nil,
        parse_time(it["created_at"]?))
    end
  end
end
