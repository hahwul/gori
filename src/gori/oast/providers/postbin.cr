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
        # The REQUEST is guarded for the same reason the parse below is, and the guard cannot be
        # a bare rescue. A transport failure mid-drain — a reset connection, a TLS error, the
        # MAX_BODY refusal `HttpClient` raises on an over-large body — would otherwise unwind out
        # of this loop and take `out` with it, discarding interactions the bin has ALREADY handed
        # over and no longer holds. But swallowing it outright is the other half of the same bug:
        # the poller would read an empty batch as "nothing arrived" and the operator would never
        # learn the provider is unreachable.
        #
        # So: re-raise when there is nothing to protect, break when there is. A cycle that
        # collected something returns it and reports the failure on the NEXT cycle (the condition
        # that caused it does not heal inside this loop), and a cycle that collected nothing
        # surfaces the error immediately, exactly as it did before.
        resp = begin
          http.request("GET", "#{base_url}/api/bin/#{session.correlation_id}/req/shift")
        rescue ex
          raise ex if out.empty?
          break
        end
        break if resp.status == 404 # bin drained
        unless resp.status == 200
          # The SAME split the transport rescue above makes, for the same reason. A 429 (postb.in
          # rate-limits a tight drain) or a 5xx used to read as "the bin is empty", so a listener
          # that could not reach its bin at all looked exactly like one watching a quiet target.
          # Re-raise when there is nothing to protect; keep what this cycle already shifted
          # otherwise and report the failure on the next one.
          raise Gori::Error.new("postbin poll: HTTP #{resp.status} #{snippet(resp.body)}") if out.empty?
          break
        end
        # Each shift has ALREADY removed this request from the bin server-side, so a raise on a
        # malformed body (a proxy error page or a rate-limit HTML served with a 200) would discard
        # every interaction shifted so far THIS cycle — unrecoverably, since the bin no longer
        # holds them. Keep what parsed and stop; the poller drains the remainder next cycle.
        # (parse_time already guards the timestamp field for the same reason; this guards the body
        # parse sitting above it.)
        it = begin
          to_interaction(parse_json(resp.body))
        rescue
          break
        end
        out << it if it
      end
      out
    end

    def deregisters? : Bool
      true
    end

    # `DELETE /api/bin/{binId}` — the bin IS the listener, so deleting it is what makes the
    # payloads minted from this session stop resolving. Bins expire on their own in ~30
    # minutes, which is why the missing teardown was easy to miss and is still not a reason to
    # skip it: `release` is what an operator runs when the engagement ends, and until the
    # expiry the bin is a public URL collecting the target's traffic.
    #
    # `session.server_url` for the same reason `Interactsh#resume` uses it: the bin lives on the
    # host that minted it. 404/410 are success (already gone); anything else raises so
    # `Sessions.release` reports a failure rather than a teardown.
    def deregister(http : Http, session : Session) : Nil
      resp = http.request("DELETE", "#{session.server_url}/api/bin/#{session.correlation_id}",
        json_headers)
      return if {200, 201, 202, 204, 404, 410}.includes?(resp.status)
      raise Gori::Error.new("postbin deregister failed: HTTP #{resp.status} #{snippet(resp.body)}")
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
