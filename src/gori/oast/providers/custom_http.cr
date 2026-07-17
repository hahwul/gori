require "base64"
require "json"
require "digest/sha256"
require "../crypto"

module Gori::Oast
  # "Bring your own OAST server": no registration, just GET an arbitrary JSON endpoint that
  # returns logged requests. Tolerant parsing so many self-hosted shapes work. Correlation
  # is by an `oid` nonce the user embeds in each payload (visible in the raw request).
  class CustomHttp < Provider
    def initialize(host : String, token : String? = nil)
      super(ProviderKind::CustomHttp, host, token)
    end

    def register(http : Http) : Session
      # No server-side state — the poll URL is the endpoint. Bind a session locally.
      Session.new(0_i64, ProviderKind::CustomHttp, base_url, Crypto.random_id(12), "",
        token: @token, registered: true)
    end

    def generate_payload(session : Session) : String
      sep = session.server_url.includes?('?') ? '&' : '?'
      "#{session.server_url}#{sep}oid=#{Crypto.random_id(10)}"
    end

    def poll(http : Http, session : Session) : Array(Interaction)
      resp = http.request("GET", session.server_url, custom_headers)
      return [] of Interaction unless resp.status == 200
      items_array(parse_json(resp.body)).compact_map { |it| to_interaction(it) }
    end

    private def custom_headers : Hash(String, String)
      h = {} of String => String
      if (t = @token) && !t.empty?
        h["Authorization"] = "Bearer #{t}"
      end
      h
    end

    private def to_interaction(it : JSON::Any) : Interaction?
      return nil unless it.as_h?
      raw = field(it, "rawRequest", "raw_request", "body") || it.to_json
      uid = field(it, "id", "uuid", "reqId", "_id") || Digest::SHA256.hexdigest(raw)[0, 40]
      proto = (field(it, "protocol") || "http").downcase
      full = field(it, "host", "destination") || uid
      Interaction.new(uid, proto, field(it, "method"),
        field(it, "ip", "source", "remote_address"), full, raw, nil,
        parse_time(it["timestamp"]? || it["created_at"]?))
    end
  end
end
