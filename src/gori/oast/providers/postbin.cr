require "json"
require "../crypto"

module Gori::Oast
  # PostBin (postb.in). POST /api/bin mints a bin; polling destructively shifts requests off
  # it until empty. Payload = {base}/{binId}[/nonce]. Bins expire ~30 min server-side.
  class Postbin < Provider
    SHIFT_CAP = 100 # per poll cycle

    def initialize(host : String, token : String? = nil)
      super(ProviderKind::Postbin, host, token)
    end

    def register(http : Http) : Session
      resp = http.request("POST", "#{base_url}/api/bin", json_headers)
      raise Gori::Error.new("postbin register: HTTP #{resp.status} #{snippet(resp.body)}") unless {200, 201}.includes?(resp.status)
      bin = parse_json(resp.body)["binId"]?.try(&.as_s?)
      raise Gori::Error.new("postbin register: no binId in response") unless bin
      Session.new(0_i64, ProviderKind::Postbin, base_url, bin, "", token: bin, registered: true)
    end

    def generate_payload(session : Session) : String
      "#{base_url}/#{session.correlation_id}/#{Crypto.random_id(8)}"
    end

    def poll(http : Http, session : Session) : Array(Interaction)
      out = [] of Interaction
      SHIFT_CAP.times do
        resp = http.request("GET", "#{base_url}/api/bin/#{session.correlation_id}/req/shift")
        break if resp.status == 404 # bin drained
        break unless resp.status == 200
        it = to_interaction(parse_json(resp.body))
        out << it if it
      end
      out
    end

    private def to_interaction(req : JSON::Any) : Interaction?
      return nil unless req.as_h?
      uid = field(req, "reqId", "id") || Crypto.random_id(16)
      raw = {
        "method"  => req["method"]?,
        "path"    => req["path"]?,
        "headers" => req["headers"]?,
        "query"   => req["query"]?,
        "body"    => req["body"]?,
      }.to_json
      Interaction.new(uid, "http", field(req, "method"), field(req, "ip"), uid, raw, nil,
        parse_time(req["inserted"]? || req["timestamp"]?))
    end
  end
end
