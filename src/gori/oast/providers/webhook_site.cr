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

    def poll(http : Http, session : Session) : Array(Interaction)
      resp = http.request("GET",
        "#{base_url}/token/#{session.correlation_id}/requests?sorting=newest",
        api_key_headers)
      return [] of Interaction unless resp.status == 200
      data = parse_json(resp.body)["data"]?.try(&.as_a?) || [] of JSON::Any
      data.compact_map { |it| to_interaction(it) }
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
      raw = field(it, "content") || it.to_json
      Interaction.new(uid, "http", field(it, "method"), field(it, "ip"), uid, raw, nil,
        parse_time(it["created_at"]?))
    end
  end
end
