require "./key_pair"

module Gori::Proxy::Tls
  # Mints + signs X509 certificates via the FFI. The skeleton keeps extensions
  # minimal: basicConstraints (required for trust) + subjectAltName (required
  # for hostname verification). AKI/SKI and upstream-cert mirroring are deferred.
  module CertBuilder
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
        LibCrypto.x509_name_add_entry_by_txt(subject, "CN", LibCrypto::MBSTRING_UTF8,
          common_name, common_name.bytesize, -1, 0)

        issuer_name = issuer ? LibCrypto.x509_get_subject_name(issuer.handle) : subject
        LibCrypto.x509_set_issuer_name(x, issuer_name)
        LibCrypto.x509_set_pubkey(x, pubkey.handle)

        add_ext(x, NID_BASIC_CONSTR, is_ca ? "critical,CA:TRUE" : "critical,CA:FALSE")
        add_ext(x, NID_SUBJECT_ALT, san_value(san_dns)) if san_dns && safe_san?(san_dns)

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
      !host.empty? && host.bytesize <= 253 && (host =~ /\A[A-Za-z0-9.\-*]+\z/) != nil
    end

    # An IP-literal CONNECT/SNI target must get an iPAddress SAN, not a dNSName:
    # RFC 6125 / RFC 2818 clients (curl, browsers) verify a literal IP against an
    # iPAddress SAN and reject a cert that only carries DNS:1.2.3.4 — which blocked
    # MITM of any HTTPS target addressed by IP. The IPv4 character set is a subset
    # of safe_san?'s, so this stays injection-safe.
    private def self.san_value(host : String) : String
      ipv4?(host) ? "IP:#{host}" : "DNS:#{host}"
    end

    private def self.ipv4?(host : String) : Bool
      octets = host.split('.')
      octets.size == 4 && octets.all? { |o| o.to_u8? != nil }
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
