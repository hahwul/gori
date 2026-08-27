require "openssl"

module Gori::Proxy::Tls
  # The knobs that SHAPE gori's outbound ClientHello — the offer an anti-bot stack fingerprints
  # (JA3/JA4) — applied to an `OpenSSL::SSL::Context::Client`, plus the save-time validator for
  # each of them.
  #
  # Apply and validate live in ONE file on purpose. The only honest way to know whether
  # `X25519:P-256` or `ecdsa_secp256r1_sha256` is a legal string is to hand it to the OpenSSL
  # that will consume it — a grammar re-implemented in the settings layer would accept names
  # this build does not have and reject ones it does, and would drift the first time the linked
  # library changed. So `Settings.outbound_tls_error` calls in here rather than pattern-matching
  # in there, and the validator uses the SAME call the dial will make.
  #
  # Nothing here reads `Settings`: every function takes primitives. That keeps the dependency
  # one-way (settings → tls → openssl) and lets the suite drive each knob without a context
  # cache, a rule table or a socket.
  #
  # No new `lib` declarations were needed (so nothing landed in `ffi.cr`): every OpenSSL entry
  # point below is already bound by Crystal's stdlib. What was missing is not the symbols but
  # the COMMAND NUMBERS — `SSL_CTX_set1_groups_list` and friends are C macros over
  # `SSL_CTX_ctrl`, so there is no symbol to link and the constants below are the binding.
  module ClientShape
    # ALPN protocols gori may offer an origin. NOT an arbitrary list, and the restriction is
    # load-bearing rather than conservative: whatever the origin SELECTS is what gori then has
    # to speak on that socket. Offering `spdy/3.1` to an origin that accepts it would leave the
    # forwarder writing HTTP/1.1 into a connection that agreed to something else — a silent
    # corruption with no error anywhere. Browsers offer exactly `h2, http/1.1`, so the list
    # costs nothing an operator wanted.
    ALPN_SUPPORTED = ["h2", "http/1.1"]

    # ALPN identifiers gori can serve on a leg it will speak HTTP/1.x on (see `alpn_offer`).
    private ALPN_HTTP1 = ["http/1.1"]

    # SSL_CTX_set1_groups_list / SSL_CTX_set1_sigalgs_list are MACROS over SSL_CTX_ctrl in
    # OpenSSL's headers, so there is no symbol to bind — the command numbers are the API.
    # Both return 1 on success and 0 on a name this build does not know.
    SSL_CTRL_SET_GROUPS_LIST  = 92
    SSL_CTRL_SET_SIGALGS_LIST = 98

    # SSL_CTX_set_tlsext_status_type, likewise a macro (tls1.h). `TLSEXT_STATUSTYPE_ocsp` is 1;
    # setting it is what puts `status_request` (extension 5) in the hello, which every browser
    # sends and stock OpenSSL does not.
    SSL_CTRL_SET_TLSEXT_STATUS_REQ_TYPE = 65
    TLSEXT_STATUSTYPE_OCSP              =  1

    # ── apply ──────────────────────────────────────────────────────────────────────────────
    #
    # Each setter RAISES on refusal, deliberately, matching `Upstream.apply_outbound_tls`'s
    # contract: a shape gori could not apply must not degrade into a different handshake that
    # then fails at the origin, because the operator would read that as the origin's verdict on
    # the fingerprint they thought they were sending. The save-time validators below are what
    # keep a raise here to a hand-edited file.

    def self.set_groups(ctx : OpenSSL::SSL::Context::Client, list : String) : Nil
      return if list.empty?
      raise OpenSSL::Error.new("SSL_CTX_set1_groups_list") unless ctrl_string(ctx, SSL_CTRL_SET_GROUPS_LIST, list)
    end

    def self.set_sigalgs(ctx : OpenSSL::SSL::Context::Client, list : String) : Nil
      return if list.empty?
      raise OpenSSL::Error.new("SSL_CTX_set1_sigalgs_list") unless ctrl_string(ctx, SSL_CTRL_SET_SIGALGS_LIST, list)
    end

    # TLS 1.3 suites. A separate OpenSSL API from `ctx.ciphers=` (which governs TLS 1.2 and
    # below ONLY — see the note on `OutboundTlsRule#ciphers`), so the two fields are not
    # alternatives: a browser-shaped offer needs both.
    def self.set_ciphersuites(ctx : OpenSSL::SSL::Context::Client, list : String) : Nil
      return if list.empty?
      ctx.cipher_suites = list
    end

    # Offer `protocols` in this order. Crystal's `Context#alpn_protocol=` can only express ONE
    # protocol, which is the whole gap: a browser offers `h2` AND `http/1.1`, and an origin that
    # sees a single-entry list has already been told something no browser would say.
    def self.set_alpn(ctx : OpenSSL::SSL::Context::Client, protocols : Array(String)) : Nil
      return if protocols.empty?
      wire = alpn_wire(protocols)
      # SSL_CTX_set_alpn_protos returns 0 on SUCCESS (it is one of OpenSSL's inverted ones).
      raise OpenSSL::Error.new("SSL_CTX_set_alpn_protos") unless LibSSL.ssl_ctx_set_alpn_protos(ctx, wire, wire.size) == 0
    end

    # Ask the origin to staple an OCSP response, adding `status_request` to the hello.
    def self.request_ocsp_stapling(ctx : OpenSSL::SSL::Context::Client) : Nil
      ok = LibSSL.ssl_ctx_ctrl(ctx, SSL_CTRL_SET_TLSEXT_STATUS_REQ_TYPE,
        LibC::ULong.new(TLSEXT_STATUSTYPE_OCSP), Pointer(Void).null) == 1
      raise OpenSSL::Error.new("SSL_CTX_set_tlsext_status_type") unless ok
    end

    # The `protocol_name_list` wire form: each entry a one-byte length then its bytes.
    def self.alpn_wire(protocols : Array(String)) : Bytes
      io = IO::Memory.new
      protocols.each do |p|
        io.write_byte(p.bytesize.to_u8)
        io.write(p.to_slice)
      end
      io.to_slice
    end

    # What gori actually offers, given what the CALLER asked for and what the destination's
    # rule configured. This is the one composition rule in the feature, and it is a safety rule
    # first:
    #
    #   * No configured list ⇒ exactly today's behaviour: the caller's single protocol, or none.
    #   * The caller named a protocol (only ever "h2" today, the origin-ALPN probe) ⇒ the
    #     configured list, verbatim. Every such caller already branches on what came BACK
    #     (`alpn_protocol == "h2"`), so an origin picking `http/1.1` off a browser-shaped list
    #     lands on the HTTP/1.1 path it already had.
    #   * The caller named NOTHING ⇒ it is going to speak HTTP/1.1 on this socket (the
    #     forward-proxy leg, the Repeater, the WebSocket engine). `h2` is dropped from the offer
    #     because an origin that selected it would leave gori writing HTTP/1.1 into an HTTP/2
    #     connection. This is the field's one honest limitation, and it is documented as such:
    #     on a forced-HTTP/1.1 leg the ALPN half of the fingerprint is `http/1.1` alone.
    #
    # nil means "offer no ALPN extension at all", which is not the same as an empty list.
    def self.alpn_offer(requested : String?, configured : Array(String)) : Array(String)?
      if configured.empty?
        return requested ? [requested] : nil
      end
      return configured if requested
      h1 = configured & ALPN_HTTP1
      h1.empty? ? nil : h1
    end

    # ── validate ───────────────────────────────────────────────────────────────────────────
    #
    # nil when the value is usable, else a sentence naming the setting. Each asks OpenSSL on a
    # throwaway context, so the answer is this build's answer and not a guess about it.

    def self.groups_error(list : String, permissive : Bool = false) : String?
      return nil if list.empty?
      return nil if ctrl_string(probe_context(permissive), SSL_CTRL_SET_GROUPS_LIST, list)
      "settings: outbound TLS `groups` is not a group list this OpenSSL accepts: #{list}"
    rescue
      # Never let a context this build refuses to CREATE become an error about the operator's
      # string — and never let it escape: the only caller is a startup warning.
      nil
    end

    def self.sigalgs_error(list : String, permissive : Bool = false) : String?
      return nil if list.empty?
      return nil if ctrl_string(probe_context(permissive), SSL_CTRL_SET_SIGALGS_LIST, list)
      "settings: outbound TLS `sigalgs` is not a signature-algorithm list this OpenSSL accepts: #{list}"
    rescue
      nil
    end

    def self.ciphersuites_error(list : String, permissive : Bool = false) : String?
      return nil if list.empty?
      ctx = probe_context(permissive)
      begin
        ctx.cipher_suites = list
        nil
      rescue
        "settings: outbound TLS `ciphersuites` is not a TLS 1.3 suite list this OpenSSL accepts: #{list}" \
        " (TLS 1.2 and below use `ciphers`)"
      end
    rescue
      nil # the context itself could not be built — see groups_error
    end

    # ALPN is checked against gori's own list, not OpenSSL's — OpenSSL will happily offer any
    # identifier, and the constraint is what GORI can speak once the origin picks one.
    def self.alpn_error(protocols : Array(String)) : String?
      protocols.each do |p|
        return "settings: outbound TLS `alpn` entry is empty" if p.empty?
        next if ALPN_SUPPORTED.includes?(p)
        return "settings: outbound TLS `alpn` cannot offer #{p.inspect} — gori can only speak " \
               "#{ALPN_SUPPORTED.join(", ")} to an origin, and must be able to speak whatever it selects"
      end
      nil
    end

    # A fresh context to try a string against. Never the live one: a validator that mutated the
    # context a dial will use would make "is this legal?" a side effect.
    #
    # `permissive` mirrors what `Upstream.apply_outbound_tls` does BEFORE it applies any of
    # these knobs — it drops the security level to 0. Without that the validator answers for a
    # different context than the dial builds, and on a distribution built at SECLEVEL=2 it
    # would report a legacy rule that dials perfectly well as one that "will fail".
    private def self.probe_context(permissive : Bool = false) : OpenSSL::SSL::Context::Client
      ctx = OpenSSL::SSL::Context::Client.new
      ctx.security_level = 0 if permissive
      ctx
    end

    private def self.ctrl_string(ctx : OpenSSL::SSL::Context::Client, cmd : Int32, value : String) : Bool
      LibSSL.ssl_ctx_ctrl(ctx, cmd, LibC::ULong.new(0), value.to_unsafe.as(Void*)) == 1
    end
  end
end
