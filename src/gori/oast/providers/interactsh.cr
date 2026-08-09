require "base64"
require "json"
require "digest/sha256"
require "../crypto"
require "../rsa"

module Gori::Oast
  # The interactsh provider (projectdiscovery). RSA-2048 keypair registered with the
  # server; each poll returns interactions AES-encrypted under a per-poll key that is
  # itself RSA-OAEP-encrypted to our public key. This is the default/flagship provider.
  class Interactsh < Provider
    def initialize(host : String, token : String? = nil)
      super(ProviderKind::Interactsh, host, token)
    end

    def register(http : Http) : Session
      rsa = RsaKeyPair.generate_2048
      corr = Crypto.random_id(20)
      secret = Crypto.random_id(13)
      resp = http.request("POST", "#{base_url}/register", json_headers,
        register_body(rsa, corr, secret))
      unless register_ok?(resp)
        raise Gori::Error.new("interactsh register failed: HTTP #{resp.status} #{snippet(resp.body)}")
      end
      Session.new(0_i64, ProviderKind::Interactsh, base_url, corr, secret,
        private_key_pem: rsa.private_pem, token: @token, registered: true, rsa: rsa)
    end

    # Re-POST /register with the SAME correlation id, secret and public key. The server
    # either still holds the session (409 / "correlation-id … exists", which `register_ok?`
    # already accepts) or rebuilds it from what we send — so a payload minted days ago
    # resolves again and its buffered interactions come back on the next poll.
    #
    # `session.server_url` rather than `base_url`: the session records the host it was
    # registered against, and that is the only host holding its state. A provider whose host
    # was edited since must not silently re-register this correlation id somewhere else.
    def resume(http : Http, session : Session) : Nil
      rsa = session.rsa
      raise Gori::Error.new("interactsh resume: session has no private key") unless rsa
      resp = http.request("POST", "#{session.server_url}/register", json_headers,
        register_body(rsa, session.correlation_id, session.secret))
      unless register_ok?(resp)
        raise Gori::Error.new("interactsh resume failed: HTTP #{resp.status} #{snippet(resp.body)}")
      end
    end

    # LOCAL: 20-char correlation id + a fresh 13-char nonce + "." + server host (33-char
    # DNS label). All payloads in a session share the correlation-id the poll keys on.
    def generate_payload(session : Session) : String
      "#{session.correlation_id}#{Crypto.random_id(13)}.#{session.host}"
    end

    def poll(http : Http, session : Session) : Array(Interaction)
      resp = http.request("GET",
        "#{session.server_url}/poll?id=#{session.correlation_id}&secret=#{session.secret}",
        auth_headers)
      return [] of Interaction if resp.status == 204
      raise Gori::Error.new("interactsh poll: HTTP #{resp.status}") unless resp.status == 200

      json = parse_json(resp.body)
      data = json["data"]?.try(&.as_a?)
      return [] of Interaction unless data && !data.empty?
      aes_key_b64 = json["aes_key"]?.try(&.as_s?)
      raise Gori::Error.new("interactsh poll: missing aes_key") unless aes_key_b64
      rsa = session.rsa
      raise Gori::Error.new("interactsh poll: session has no private key") unless rsa
      aes_key = rsa.oaep_sha256_decrypt(Base64.decode(aes_key_b64))

      out = [] of Interaction
      data.each do |item|
        b64 = item.as_s?
        next unless b64
        # One malformed item must not sink the batch: interactsh delivers a whole poll at once and
        # marks it consumed server-side, so a raise out of Base64.decode / parse_json here would
        # drop the siblings that decoded fine. Skip the bad item; keep the good ones.
        begin
          plaintext = decrypt_interaction(session, aes_key, Base64.decode(b64))
          next unless plaintext
          out << to_interaction(parse_json(plaintext))
        rescue
          next
        end
      end
      out
    end

    def deregister(http : Http, session : Session) : Nil
      body = {"correlation-id" => session.correlation_id, "secret-key" => session.secret}.to_json
      http.request("POST", "#{session.server_url}/deregister", json_headers, body)
    rescue
      # best-effort
    end

    # ---- internals ----

    # The /register payload. ONE builder for both callers: register mints the triple, resume
    # replays the persisted one, and the server cannot tell (nor should it) which is which.
    private def register_body(rsa : RsaKeyPair, corr : String, secret : String) : String
      {
        "public-key"     => Base64.strict_encode(rsa.public_spki_pem),
        "secret-key"     => secret,
        "correlation-id" => corr,
      }.to_json
    end

    # 200/201/204 succeed; a "correlation-id … exists" 400 or a 409 means an already-known
    # id (resume) — also fine.
    private def register_ok?(resp : Http::Response) : Bool
      return true if {200, 201, 204, 409}.includes?(resp.status)
      resp.status == 400 && resp.body.includes?("correlation-id") && resp.body.includes?("exists")
    end

    # Try the sticky mode first, then the other; the mode that yields valid interaction JSON
    # wins and sticks for the session. Server encrypts with CFB; CTR is the fallback.
    private def decrypt_interaction(session : Session, aes_key : Bytes, data : Bytes) : String?
      modes = session.aes_mode_cfb? ? {"aes-256-cfb", "aes-256-ctr"} : {"aes-256-ctr", "aes-256-cfb"}
      modes.each do |mode|
        begin
          text = String.new(Crypto.aes256_decrypt(data, aes_key, mode))
          if looks_like_interaction?(text)
            session.aes_mode_cfb = (mode == "aes-256-cfb")
            return text
          end
        rescue
          # try the other mode
        end
      end
      nil
    end

    private def looks_like_interaction?(text : String) : Bool
      text.valid_encoding? && text.lstrip.starts_with?('{') && text.includes?("protocol")
    end

    private def to_interaction(j : JSON::Any) : Interaction
      proto = (j["protocol"]?.try(&.as_s?) || "unknown").downcase
      full_id = j["full-id"]?.try(&.as_s?) || j["unique-id"]?.try(&.as_s?) || ""
      source = j["remote-address"]?.try(&.as_s?)
      raw = j["raw-request"]?.try(&.as_s?) || ""
      resp = j["raw-response"]?.try(&.as_s?)
      ts_raw = j["timestamp"]?.try(&.as_s?) || ""
      meth = if proto == "http"
               (raw.split(' ', 2).first? unless raw.empty?)
             else
               j["q-type"]?.try(&.as_s?)
             end
      # interactsh gives no per-event id (unique-id repeats per hostname), so synthesize a
      # dedup key from content+time — distinct callbacks stay distinct, exact replays fold.
      uid = Digest::SHA256.hexdigest("#{ts_raw}|#{source}|#{raw}")[0, 40]
      Interaction.new(uid, proto, meth, source, full_id, raw, resp, parse_time(j["timestamp"]?))
    end
  end
end
