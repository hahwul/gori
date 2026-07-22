require "socket"
require "./key_pair"

module Gori::Proxy::Tls
  # Mints + signs X509 certificates via the FFI. The skeleton keeps extensions
  # minimal: basicConstraints (required for trust) + subjectAltName (required
  # for hostname verification). AKI/SKI and upstream-cert mirroring are deferred.
  module CertBuilder
    # OpenSSL enforces ub-common-name = 64 bytes on the CN attribute;
    # X509_NAME_add_entry_by_txt fails (returns 0) for a longer value, silently
    # leaving the subject EMPTY. CN is deprecated for hostname verification anyway
    # (clients use the SAN), so we only set it when it fits and fall back to an
    # empty subject + a CRITICAL SAN (RFC 5280 §4.2.1.6) for longer hostnames.
    MAX_CN_BYTES = 64

    # Self-signed root CA.
    def self.build_root(common_name : String) : {Cert, KeyPair}
      key = KeyPair.generate_ec
      cert = build(common_name, key, key, issuer: nil, is_ca: true,
        san_dns: nil, validity: CA_VALIDITY_SECS)
      {cert, key}
    end

    # Per-host leaf, signed by the CA. CN and SAN are the requested host.
    def self.build_leaf(host : String, ca_cert : Cert, ca_key : KeyPair) : {Cert, KeyPair}
      key = KeyPair.generate_ec
      cert = build(host, key, ca_key, issuer: ca_cert, is_ca: false,
        san_dns: host, validity: LEAF_VALIDITY_SECS)
      {cert, key}
    end

    private def self.build(common_name : String, pubkey : KeyPair, signing_key : KeyPair, *,
                           issuer : Cert?, is_ca : Bool, san_dns : String?, validity : Int64) : Cert
      x = LibCrypto.x509_new
      raise Gori::Error.new("X509_new failed") if x.null?
      begin
        LibCrypto.x509_set_version(x, 2) # v3
        LibCrypto.asn1_integer_set(LibCrypto.x509_get_serial(x), random_serial)
        LibCrypto.x509_gmtime_adj(LibCrypto.x509_getm_not_before(x), 0)
        LibCrypto.x509_gmtime_adj(LibCrypto.x509_getm_not_after(x), validity)

        subject = LibCrypto.x509_get_subject_name(x)
        # Only set CN when it fits OpenSSL's 64-byte cap AND the add succeeds; a
        # longer hostname (or any failure) leaves the subject empty, which then
        # requires a critical SAN below.
        subject_set = common_name.bytesize <= MAX_CN_BYTES &&
                      LibCrypto.x509_name_add_entry_by_txt(subject, "CN", LibCrypto::MBSTRING_UTF8,
                        common_name, common_name.bytesize, -1, 0) != 0

        issuer_name = issuer ? LibCrypto.x509_get_subject_name(issuer.handle) : subject
        LibCrypto.x509_set_issuer_name(x, issuer_name)
        LibCrypto.x509_set_pubkey(x, pubkey.handle)

        add_ext(x, NID_BASIC_CONSTR, is_ca ? "critical,CA:TRUE" : "critical,CA:FALSE")
        if san_dns && safe_san?(san_dns)
          # RFC 5280 §4.2.1.6: a cert with an empty subject DN MUST carry a CRITICAL
          # SAN, or strict TLS stacks (curl/LibreSSL, browsers) reject the handshake.
          value = san_value(san_dns)
          value = "critical,#{value}" unless subject_set
          add_ext(x, NID_SUBJECT_ALT, value)
        end

        raise Gori::Error.new("X509_sign failed") if LibCrypto.x509_sign(x, signing_key.handle, LibCrypto.evp_sha256) == 0
        Cert.new(x)
      rescue ex
        LibCrypto.x509_free(x)
        raise ex
      end
    end

    # The SAN value is spliced into the X509v3 config grammar, where ',' and ':'
    # begin new entries/types — so a hostile CONNECT/SNI host like
    # "a.com,DNS:victim.com" or "a.com,IP:1.2.3.4" would inject extra SAN entries.
    # Only emit the SAN for a plain hostname / IPv4 (+ wildcard) label set; for
    # anything else skip it (the cert then lacks a SAN and fails verification for
    # that bogus host — the safe outcome) rather than minting an injected cert.
    private def self.safe_san?(host : String) : Bool
      return false if host.empty? || host.bytesize > 253
      # scrub: host is the attacker-supplied CONNECT/SNI authority kept byte-exact; an invalid
      # UTF-8 byte would make this PCRE match raise on the proxy path. Scrubbed bytes (U+FFFD)
      # fall outside the charset → SAN skipped (the designed graceful outcome), never a raise.
      return true if (host.scrub =~ /\A[A-Za-z0-9.\-*]+\z/) != nil # hostname / IPv4 / wildcard labels
      ipv6?(host)                                                  # IPv6 literals contain ':' (rejected by the DNS charset above)
    end

    # An IP-literal CONNECT/SNI target must get an iPAddress SAN, not a dNSName:
    # RFC 6125 / RFC 2818 clients (curl, browsers) verify a literal IP against an
    # iPAddress SAN and reject a cert that only carries DNS:1.2.3.4 — which blocked
    # MITM of any HTTPS target addressed by IP. The IPv4 character set is a subset
    # of safe_san?'s, so this stays injection-safe.
    private def self.san_value(host : String) : String
      ipv4?(host) || ipv6?(host) ? "IP:#{host}" : "DNS:#{host}"
    end

    # CANONICAL dotted-quad only. OpenSSL's IP-SAN parser (a2i_GENERAL_NAME) rejects
    # zero-padded octets ("01.02.03.04"), so accepting them here would emit an
    # IP:<host> SAN that fails X509V3_EXT_nconf_nid → the leaf mint aborts and the
    # TLS MITM handshake tears down. A non-canonical IP falls through to a DNS SAN
    # instead (harmless: it just won't verify for that odd literal), never a crash.
    private def self.ipv4?(host : String) : Bool
      octets = host.split('.')
      return false unless octets.size == 4
      octets.all? do |o|
        next false if o.empty? || o.size > 3
        next false if o.size > 1 && o[0] == '0' # no leading zeros
        o.to_u8? != nil                         # 0..255
      end
    end

    # Canonical IPv6 literal (bare, no brackets / no %zone). An IP-literal HTTPS target
    # needs an iPAddress SAN just like IPv4, or RFC-6125 clients reject the leaf. The
    # charset guard excludes ',' (X509v3 nconf entry separator) and '%' (zone id), so the
    # value stays injection-safe and parseable by OpenSSL's a2i_IPADDRESS; anything else
    # falls through to a DNS SAN (won't verify for that odd literal, but never crashes).
    private def self.ipv6?(host : String) : Bool
      # scrub: independent raise site — safe_san? also reaches here with the raw (unscrubbed)
      # host, so this PCRE match must scrub too or an invalid-UTF-8 CONNECT authority raises.
      return false unless (host.scrub =~ /\A[0-9A-Fa-f:.]+\z/) != nil
      Socket::IPAddress.valid_v6?(host)
    end

    private def self.add_ext(x : LibCrypto::X509, nid : Int32, value : String) : Nil
      ext = LibCrypto.x509v3_ext_nconf_nid(Pointer(Void).null, Pointer(Void).null, nid, value)
      raise Gori::Error.new("X509V3_EXT_nconf_nid(#{nid}) failed") if ext.null?
      # Check the add too (stdlib X509_add_ext returns the ext on success, NULL on
      # failure): a silently-dropped basicConstraints/SAN would mint a cert that
      # only fails later at client verification, with no error at build time. Free
      # the ext regardless — X509_add_ext copies it.
      added = LibCrypto.x509_add_ext(x, ext, -1)
      LibCrypto.x509_extension_free(ext)
      raise Gori::Error.new("X509_add_ext(#{nid}) failed") if added.null?
    end

    private def self.random_serial : Int64
      Random::Secure.rand(1_i64..0x7fff_ffff_ffff_ffff_i64)
    end
  end
end
