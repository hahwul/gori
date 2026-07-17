require "json"
require "uri"
require "../crypto"

module Gori::Oast
  # BOAST (go-boast). Registration and polling hit the SAME events URL with
  # `Authorization: Secret <token>`; register returns {id, canary, events}. Payload =
  # {nonce}.{id}.{boast-host}. Requires a token (the BOAST secret).
  class Boast < Provider
    def initialize(host : String, token : String? = nil)
      super(ProviderKind::Boast, host, token)
    end

    def register(http : Http) : Session
      secret = @token
      raise Gori::Error.new("BOAST requires a secret token") unless secret && !secret.empty?
      resp = http.request("GET", base_url, secret_headers)
      raise Gori::Error.new("BOAST register: HTTP #{resp.status} #{snippet(resp.body)}") unless resp.status == 200
      json = parse_json(resp.body)
      id = json["id"]?.try(&.as_s?)
      raise Gori::Error.new("BOAST register: no id in response") unless id
      Session.new(0_i64, ProviderKind::Boast, base_url, id, secret, token: secret, registered: true)
    end

    # Correlation is the registered id; a fresh nonce sub-label distinguishes payloads.
    def generate_payload(session : Session) : String
      "#{Crypto.random_id(10)}.#{session.correlation_id}.#{payload_host}"
    end

    def poll(http : Http, session : Session) : Array(Interaction)
      resp = http.request("GET", session.server_url, secret_headers)
      return [] of Interaction unless resp.status == 200
      events = parse_json(resp.body)["events"]?.try(&.as_a?) || [] of JSON::Any
      events.compact_map { |ev| to_interaction(ev) }
    end

    private def secret_headers : Hash(String, String)
      {"Authorization" => "Secret #{@token}"}
    end

    private def payload_host : String
      URI.parse(base_url).host || base_url
    end

    private def to_interaction(ev : JSON::Any) : Interaction?
      return nil unless ev.as_h?
      uid = field(ev, "id") || Crypto.random_id(16)
      Interaction.new(uid,
        (field(ev, "receiver") || "unknown").downcase,
        field(ev, "QueryType", "queryType"),
        field(ev, "remoteAddress", "remote_address"),
        uid,
        field(ev, "dump") || ev.to_json,
        nil,
        parse_time(ev["time"]? || ev["timestamp"]?))
    end
  end
end
