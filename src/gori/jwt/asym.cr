require "../proxy/tls/ffi"

# The asymmetric half of the JWT workbench's signing engine: RSASSA-PKCS1 (RS*),
# RSASSA-PSS (PS*), ECDSA (ES*) and EdDSA (Ed25519), the algorithms real OIDC
# deployments actually ship. `forge.cr` keeps the HMAC family and routes here by `alg`.
#
# Crystal's stdlib has no `OpenSSL::PKey`, so this is FFI — `lib LibCrypto` is declared
# at top level in `../proxy/tls/ffi.cr` (which also owns the shared memory-BIO and
# EVP_PKEY_CTX funs) and REOPENED here for the digest-sign path. Redeclaring a fun that
# ffi.cr, `../oast/rsa.cr` or stdlib already binds collides, so only the new ones are below.
lib LibCrypto
  # Reading the operator's key. `PEM_read_bio_PrivateKey` is in ffi.cr; the SPKI public
  # reader and the certificate's embedded key are not (an IdP publishes a cert as often
  # as a bare public key, and `X509_free` comes from stdlib).
  fun pem_read_bio_pubkey = PEM_read_bio_PUBKEY(bio : Bio*, pkey : EVP_PKEY*, cb : Void*, u : Void*) : EVP_PKEY
  fun x509_get_pubkey = X509_get_pubkey(x : X509) : EVP_PKEY

  # `verification_key` tries three PEM readers in sequence, so one or two of them FAIL on the
  # success path and push onto OpenSSL's per-thread error queue. gori never reads that detail,
  # but Crystal's `OpenSSL::Error` does (`ERR_get_error`), so a stale PEM parse error would be
  # reported later as the reason a proxy TLS handshake failed. Clear it on every BIO teardown.
  fun err_clear_error = ERR_clear_error

  # Key introspection, to refuse an alg/key mismatch by name rather than emit a signature
  # nothing can verify. OpenSSL 3.0 renamed both to `EVP_PKEY_get_*` and left the old
  # spellings as MACROS, which do not link — so the name is chosen at compile time.
  {% if compare_versions(OPENSSL_VERSION, "3.0.0") >= 0 %}
    fun evp_pkey_base_id = EVP_PKEY_get_base_id(pkey : EVP_PKEY) : Int
    fun evp_pkey_bits = EVP_PKEY_get_bits(pkey : EVP_PKEY) : Int
  {% else %}
    fun evp_pkey_base_id = EVP_PKEY_base_id(pkey : EVP_PKEY) : Int
    fun evp_pkey_bits = EVP_PKEY_bits(pkey : EVP_PKEY) : Int
  {% end %}

  # The ONE-SHOT digest-sign/verify pair, deliberately, not Update/Final: Ed25519 refuses
  # the streaming calls outright (RFC 8032 signs the whole message), and `EVP_DigestSignUpdate`
  # is a macro in 1.1.1 and a function in 3.x. `EVP_DigestSign` is one spelling that links
  # everywhere and covers every algorithm here.
  fun evp_digest_sign_init = EVP_DigestSignInit(ctx : EVP_MD_CTX, pctx : EVP_PKEY_CTX*, type : EVP_MD,
                                                e : Void*, pkey : EVP_PKEY) : Int
  fun evp_digest_sign = EVP_DigestSign(ctx : EVP_MD_CTX, sig : UInt8*, siglen : SizeT*,
                                       tbs : UInt8*, tbslen : SizeT) : Int
  fun evp_digest_verify_init = EVP_DigestVerifyInit(ctx : EVP_MD_CTX, pctx : EVP_PKEY_CTX*, type : EVP_MD,
                                                    e : Void*, pkey : EVP_PKEY) : Int
  fun evp_digest_verify = EVP_DigestVerify(ctx : EVP_MD_CTX, sig : UInt8*, siglen : SizeT,
                                           tbs : UInt8*, tbslen : SizeT) : Int
end

module Gori
  module Jwt
    # Sign / verify a JWS signing input under an asymmetric algorithm, with a key the
    # OPERATOR supplies (inline PEM or a path to one). gori generates nothing on its own —
    # forging an RS256 token still requires holding the RS256 private key.
    module Asym
      extend self

      # The JOSE algorithm names this module handles, in the order the workbench offers
      # them. `Jwt::ALGS` (forge.cr) is HMAC + these + `none`.
      ALGS = %w[RS256 RS384 RS512 PS256 PS384 PS512 ES256 ES384 ES512 EdDSA]

      # OpenSSL NIDs (obj_mac.h). RSA and RSA-PSS are distinct key types that both sign
      # RS*/PS*; an EVP_PKEY parsed from a plain RSA PEM reports NID_rsaEncryption.
      NID_RSA     =    6 # NID_rsaEncryption
      NID_RSA_PSS =  912 # NID_rsassaPss
      NID_EC      =  408 # NID_X9_62_id_ecPublicKey
      NID_ED25519 = 1087
      NID_ED448   = 1088

      # EVP_PKEY_CTX_ctrl commands for RSA-PSS (rsa.h: EVP_PKEY_ALG_CTRL 0x1000 + offset).
      # Both keytype and optype are -1 so the call is version-independent: 1.1.1 spells these
      # as macros whose optype is EVP_PKEY_OP_SIGN|VERIFY, but a DigestSign context reports
      # EVP_PKEY_OP_SIGNCTX and would fail that check.
      EVP_PKEY_CTRL_RSA_PADDING     = 0x1001
      EVP_PKEY_CTRL_RSA_PSS_SALTLEN = 0x1002
      RSA_PKCS1_PSS_PADDING         =      6
      RSA_PSS_SALTLEN_DIGEST        =     -1 # RFC 7518 §3.5: salt length == hash length

      # A key PEM larger than this is not a key. Bounds a `--key /dev/zero` typo.
      MAX_KEY_BYTES = 256 * 1024

      def alg?(alg : String) : Bool
        ALGS.includes?(alg)
      end

      # The signature for `signing_input`, in the JOSE wire form (see `der_to_raw` for why
      # ES* is not what OpenSSL hands back). `key_spec` is an inline PEM or a path to one.
      def sign(signing_input : String, alg : String, key_spec : String) : Bytes
        key = private_key(key_spec)
        check_key!(alg, key)
        sig = digest_sign(signing_input, alg, key)
        alg.starts_with?("ES") ? der_to_raw(sig, ec_component(alg)) : sig
      end

      # Does `signature` (JOSE wire form) verify over `signing_input`? `key_spec` may be a
      # public key, a certificate, or the private key — an operator who holds the private
      # half should not have to extract the public one to check a token.
      #
      # A structurally impossible signature (wrong ES* width, unparseable) is `false`, not a
      # raise: "this token does not verify" is the answer, and the only honest one.
      def verify(signing_input : String, alg : String, signature : Bytes, key_spec : String) : Bool
        key = verification_key(key_spec)
        check_key!(alg, key)
        der = if alg.starts_with?("ES")
                n = ec_component(alg)
                return false unless signature.size == n * 2
                raw_to_der(signature, n)
              else
                signature
              end
        digest_verify(signing_input, alg, der, key)
      end

      # The PEM text behind a key spec: the string itself when it IS a PEM block, else the
      # contents of the file it names.
      #
      # The spec is never echoed back in an error. An operator who passes an HMAC secret to
      # an asymmetric alg would otherwise read their own key material out of the message —
      # and out of whatever log or transcript captured it.
      def pem_for(key_spec : String) : String
        return key_spec if key_spec.includes?("-----BEGIN")
        path = key_spec.strip
        # Short on purpose: this is what the TUI's live OUTPUT pane shows the moment `^A`
        # cycles onto an asymmetric alg with the KEY card still empty, and the pane is narrow.
        raise ForgeError.new("no key given — RS/PS/ES/EdDSA need a PEM key (inline, or a path to a .pem file)") if path.empty?
        # `File.file?` raises ArgumentError — NOT an IO::Error — on a path carrying a NUL, and
        # that escapes every caller's `rescue ForgeError`: an MCP `key` of "a\0b" reached the
        # server's blanket rescue and was coded INTERNAL ("gori is broken") for a mistake in
        # the agent's own call, and the same value in the TUI's KEY card crashed the tab.
        raise ForgeError.new("key path contains a NUL byte") if path.includes?('\0')
        unless File.file?(path)
          raise ForgeError.new("key is neither an inline PEM block nor a readable file path")
        end
        if File.size(path) > MAX_KEY_BYTES
          raise ForgeError.new("key file is larger than #{MAX_KEY_BYTES // 1024} KiB — not a PEM key")
        end
        File.read(path)
      rescue IO::Error | ArgumentError # a race, a directory, a permission denial, a bad path
        raise ForgeError.new("cannot read the key file")
      end

      # --- key loading --------------------------------------------------------

      # Owns one EVP_PKEY. `finalize` frees it; the handle must not outlive the wrapper,
      # so every use below keeps the PKey itself in a local (mirrors Oast::RsaKeyPair).
      class PKey
        getter handle : LibCrypto::EVP_PKEY

        def initialize(@handle : LibCrypto::EVP_PKEY)
        end

        def finalize
          LibCrypto.evp_pkey_free(@handle)
        end
      end

      # A PRIVATE key — signing needs one, and a public key must fail loudly rather than
      # produce nothing.
      def private_key(key_spec : String) : PKey
        pem = pem_for(key_spec)
        with_bio(pem) do |bio|
          k = LibCrypto.pem_read_bio_privatekey(bio, Pointer(LibCrypto::EVP_PKEY).null,
            Pointer(Void).null, Pointer(Void).null)
          return PKey.new(k) unless k.null?
        end
        raise ForgeError.new("not a readable PEM PRIVATE key " \
                             "(signing needs the private half; an encrypted key must be decrypted first)")
      end

      # A key to VERIFY with: an SPKI public key, an X.509 certificate's embedded key, or a
      # private key (whose public half OpenSSL derives). Tried in that order — the public
      # readers reject a private PEM, so a fallback chain cannot mis-identify.
      def verification_key(key_spec : String) : PKey
        pem = pem_for(key_spec)
        with_bio(pem) do |bio|
          k = LibCrypto.pem_read_bio_pubkey(bio, Pointer(LibCrypto::EVP_PKEY).null,
            Pointer(Void).null, Pointer(Void).null)
          return PKey.new(k) unless k.null?
        end
        with_bio(pem) do |bio|
          cert = LibCrypto.pem_read_bio_x509(bio, Pointer(LibCrypto::X509).null,
            Pointer(Void).null, Pointer(Void).null)
          unless cert.null?
            k = LibCrypto.x509_get_pubkey(cert)
            LibCrypto.x509_free(cert)
            return PKey.new(k) unless k.null?
          end
        end
        with_bio(pem) do |bio|
          k = LibCrypto.pem_read_bio_privatekey(bio, Pointer(LibCrypto::EVP_PKEY).null,
            Pointer(Void).null, Pointer(Void).null)
          return PKey.new(k) unless k.null?
        end
        raise ForgeError.new("not a readable PEM key (expected a PUBLIC KEY, a CERTIFICATE, or a PRIVATE KEY block)")
      end

      # The CANONICAL SubjectPublicKeyInfo PEM for a key spec — what a server that loaded the
      # key through OpenSSL holds in memory, which is not necessarily the bytes the operator
      # handed over: a certificate PEM, a PKCS#8 private key and an SPKI public key all
      # resolve to the same public half but serialize differently, and the algorithm-confusion
      # family is exactly the case where the BYTES are the HMAC secret.
      def public_spki_pem(key_spec : String) : String
        key = verification_key(key_spec)
        bio = LibCrypto.BIO_new(LibCrypto.bio_s_mem)
        raise ForgeError.new("BIO_new(mem) failed") if bio.null?
        begin
          raise ForgeError.new("cannot serialize this key as a public PEM") if LibCrypto.pem_write_bio_pubkey(bio, key.handle) != 1
          io = IO::Memory.new
          buf = Bytes.new(4096)
          loop do
            n = LibCrypto.bio_read(bio, buf.to_unsafe, buf.size)
            break if n <= 0
            io.write(buf[0, n])
          end
          io.to_s
        ensure
          LibCrypto.BIO_free(bio)
        end
      end

      private def with_bio(pem : String, &)
        bio = LibCrypto.bio_new_mem_buf(pem.to_unsafe, pem.bytesize)
        raise ForgeError.new("BIO_new_mem_buf failed") if bio.null?
        begin
          yield bio
        ensure
          LibCrypto.BIO_free(bio)
          # A failed PEM read is EXPECTED here (the reader chain tries three), so its error
          # queue entries are noise that must not outlive the call — see `err_clear_error`.
          LibCrypto.err_clear_error
        end
      end

      # Refuse an alg/key mismatch by name. Without this an RSA key under `ES256` would sign
      # happily (PKCS#1 over SHA-256) and emit 256 bytes that `der_to_raw` then tears apart
      # into nonsense, or worse, parses by accident.
      private def check_key!(alg : String, key : PKey) : Nil
        id = LibCrypto.evp_pkey_base_id(key.handle)
        case alg[0, 2]
        when "RS", "PS"
          unless id == NID_RSA || id == NID_RSA_PSS
            raise ForgeError.new("#{alg} needs an RSA key (this key is #{key_kind(id)})")
          end
        when "ES"
          raise ForgeError.new("#{alg} needs an EC key (this key is #{key_kind(id)})") unless id == NID_EC
          # Size, not curve NAME: `EVP_PKEY_get_group_name` is 3.0-only and the 1.1.1 route to
          # the NID goes through EC_KEY accessors 3.0 deprecates, so there is no portable
          # spelling. The gap that leaves is a same-width non-NIST curve — a secp256k1 key
          # passes as ES256 and emits a signature no RFC 7518 verifier accepts. So the message
          # reports the WIDTH it measured and does not claim the key is a P-curve.
          want = ec_bits(alg)
          got = LibCrypto.evp_pkey_bits(key.handle)
          if got != want
            raise ForgeError.new("#{alg} needs a P-#{want} curve (this key is a #{got}-bit curve)")
          end
        else # EdDSA
          unless id == NID_ED25519
            hint = id == NID_ED448 ? "Ed448, which JOSE does not define an alg for" : key_kind(id)
            raise ForgeError.new("EdDSA needs an Ed25519 key (this key is #{hint})")
          end
        end
      end

      private def key_kind(id : Int32) : String
        case id
        when NID_RSA, NID_RSA_PSS then "RSA"
        when NID_EC               then "EC"
        when NID_ED25519          then "Ed25519"
        when NID_ED448            then "Ed448"
        else                           "key type ##{id}"
        end
      end

      # --- the OpenSSL digest-sign path ---------------------------------------

      private def digest_sign(signing_input : String, alg : String, key : PKey) : Bytes
        ctx = LibCrypto.evp_md_ctx_new
        raise ForgeError.new("EVP_MD_CTX_new failed") if ctx.null?
        begin
          pctx = uninitialized LibCrypto::EVP_PKEY_CTX
          if LibCrypto.evp_digest_sign_init(ctx, pointerof(pctx), digest_for(alg), Pointer(Void).null, key.handle) != 1
            raise ForgeError.new("#{alg}: EVP_DigestSignInit failed (key does not support this algorithm)")
          end
          pss_ctrl(pctx, alg)
          len = LibC::SizeT.new(0)
          if LibCrypto.evp_digest_sign(ctx, Pointer(UInt8).null, pointerof(len),
               signing_input.to_unsafe, LibC::SizeT.new(signing_input.bytesize)) != 1
            raise ForgeError.new("#{alg}: EVP_DigestSign sizing failed")
          end
          buf = Bytes.new(len.to_i)
          if LibCrypto.evp_digest_sign(ctx, buf.to_unsafe, pointerof(len),
               signing_input.to_unsafe, LibC::SizeT.new(signing_input.bytesize)) != 1
            raise ForgeError.new("#{alg}: signing failed")
          end
          # `len` is rewritten with the actual length, which for ECDSA is shorter than the
          # sizing estimate (DER integers drop leading zero bytes).
          buf[0, len.to_i].dup
        ensure
          LibCrypto.evp_md_ctx_free(ctx)
        end
      end

      private def digest_verify(signing_input : String, alg : String, sig : Bytes, key : PKey) : Bool
        ctx = LibCrypto.evp_md_ctx_new
        raise ForgeError.new("EVP_MD_CTX_new failed") if ctx.null?
        begin
          pctx = uninitialized LibCrypto::EVP_PKEY_CTX
          if LibCrypto.evp_digest_verify_init(ctx, pointerof(pctx), digest_for(alg), Pointer(Void).null, key.handle) != 1
            raise ForgeError.new("#{alg}: EVP_DigestVerifyInit failed (key does not support this algorithm)")
          end
          pss_ctrl(pctx, alg)
          LibCrypto.evp_digest_verify(ctx, sig.to_unsafe, LibC::SizeT.new(sig.size),
            signing_input.to_unsafe, LibC::SizeT.new(signing_input.bytesize)) == 1
        ensure
          LibCrypto.evp_md_ctx_free(ctx)
        end
      end

      # PS* is RSASSA-PSS, which is the SAME EVP call as RS* plus two ctrls. Omit them and
      # OpenSSL signs PKCS#1 v1.5 silently — a valid RS* signature under a PS* header, which
      # no verifier accepts and no error reports.
      private def pss_ctrl(pctx : LibCrypto::EVP_PKEY_CTX, alg : String) : Nil
        return unless alg.starts_with?("PS")
        if LibCrypto.evp_pkey_ctx_ctrl(pctx, -1, -1, EVP_PKEY_CTRL_RSA_PADDING, RSA_PKCS1_PSS_PADDING, Pointer(Void).null) != 1
          raise ForgeError.new("#{alg}: cannot select PSS padding for this key")
        end
        if LibCrypto.evp_pkey_ctx_ctrl(pctx, -1, -1, EVP_PKEY_CTRL_RSA_PSS_SALTLEN, RSA_PSS_SALTLEN_DIGEST, Pointer(Void).null) != 1
          raise ForgeError.new("#{alg}: cannot set the PSS salt length")
        end
      end

      # EdDSA passes a NULL md: Ed25519 fixes its own hash (SHA-512) and EVP_DigestSignInit
      # rejects an explicit one.
      private def digest_for(alg : String) : LibCrypto::EVP_MD
        case alg
        when "EdDSA"                   then Pointer(Void).null.as(LibCrypto::EVP_MD)
        when "RS256", "PS256", "ES256" then LibCrypto.evp_sha256
        when "RS384", "PS384", "ES384" then LibCrypto.evp_sha384
        when "RS512", "PS512", "ES512" then LibCrypto.evp_sha512
        else
          raise ForgeError.new("unsupported alg #{alg.inspect}")
        end
      end

      # --- ECDSA: DER <-> the JOSE fixed-width form ---------------------------
      # OpenSSL emits `SEQUENCE { INTEGER r, INTEGER s }`; RFC 7518 §3.4 wants r and s as
      # fixed-width big-endian octet strings concatenated. ES512 is the one that catches
      # people out: P-521 is 66 bytes per component, so the signature is 132, not 128.

      # Octets per component. Derived from the ALG, not the key — the alg is what the wire
      # format has to match, and `check_key!` has already refused a curve that disagrees.
      def ec_component(alg : String) : Int32
        case alg
        when "ES256" then 32
        when "ES384" then 48
        when "ES512" then 66 # ceil(521 / 8)
        else
          raise ForgeError.new("not an ECDSA alg: #{alg.inspect}")
        end
      end

      private def ec_bits(alg : String) : Int32
        case alg
        when "ES256" then 256
        when "ES384" then 384
        else              521
        end
      end

      # DER SEQUENCE{INTEGER,INTEGER} -> r||s, each left-padded to `n` bytes.
      def der_to_raw(der : Bytes, n : Int32) : Bytes
        i = 0
        raise ForgeError.new("ECDSA signature is not a DER SEQUENCE") unless der.size > 1 && der[0] == 0x30
        i += 1
        # Length: short form (< 0x80) is one byte, long form encodes the byte count. The
        # value itself is not needed — the two INTEGERs carry their own lengths.
        if der[i] & 0x80 != 0
          i += 1 + (der[i] & 0x7f).to_i
        else
          i += 1
        end
        raw = Bytes.new(n * 2)
        2.times do |k|
          raise ForgeError.new("malformed ECDSA signature") unless i + 1 < der.size && der[i] == 0x02
          i += 1
          len = der[i].to_i
          i += 1
          raise ForgeError.new("malformed ECDSA signature") if len <= 0 || i + len > der.size
          v = der[i, len]
          i += len
          # DER INTEGERs are signed, so a component whose top bit is set carries a leading
          # 0x00. Strip any leading zeros before right-aligning into the fixed-width slot.
          off = 0
          while off < v.size - 1 && v[off] == 0
            off += 1
          end
          v = v[off, v.size - off]
          raise ForgeError.new("ECDSA component wider than the curve — wrong alg for this key") if v.size > n
          v.copy_to(raw[k * n + (n - v.size), v.size])
        end
        raw
      end

      # r||s -> DER SEQUENCE{INTEGER,INTEGER}, for handing a JOSE signature to OpenSSL.
      def raw_to_der(raw : Bytes, n : Int32) : Bytes
        r = der_integer(raw[0, n])
        s = der_integer(raw[n, n])
        body = r.size + s.size
        io = IO::Memory.new
        io.write_byte(0x30_u8)
        if body < 0x80
          io.write_byte(body.to_u8)
        else
          # P-521's two 67-byte INTEGERs push the body past 127, so the long form is reached
          # in practice — one length byte is always enough (the body is well under 256).
          io.write_byte(0x81_u8)
          io.write_byte(body.to_u8)
        end
        io.write(r)
        io.write(s)
        io.to_slice
      end

      private def der_integer(v : Bytes) : Bytes
        off = 0
        while off < v.size - 1 && v[off] == 0
          off += 1
        end
        body = v[off, v.size - off]
        pad = body[0] & 0x80 != 0 ? 1 : 0
        buf = Bytes.new(2 + pad + body.size)
        buf[0] = 0x02_u8
        buf[1] = (pad + body.size).to_u8
        body.copy_to(buf[2 + pad, body.size])
        buf
      end
    end
  end
end
