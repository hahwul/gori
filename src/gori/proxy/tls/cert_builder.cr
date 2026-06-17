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
        add_ext(x, NID_SUBJECT_ALT, "DNS:#{san_dns}") if san_dns

        raise Gori::Error.new("X509_sign failed") if LibCrypto.x509_sign(x, signing_key.handle, LibCrypto.evp_sha256) == 0
        Cert.new(x)
      rescue ex
        LibCrypto.x509_free(x)
        raise ex
      end
    end

    private def self.add_ext(x : LibCrypto::X509, nid : Int32, value : String) : Nil
      ext = LibCrypto.x509v3_ext_nconf_nid(Pointer(Void).null, Pointer(Void).null, nid, value)
      raise Gori::Error.new("X509V3_EXT_nconf_nid(#{nid}) failed") if ext.null?
      LibCrypto.x509_add_ext(x, ext, -1)
      LibCrypto.x509_extension_free(ext)
    end

    private def self.random_serial : Int64
      Random::Secure.rand(1_i64..0x7fff_ffff_ffff_ffff_i64)
    end
  end
end
