require "./ffi"

module Gori::Proxy::Tls
  # Owns an EVP_PKEY (EC P-256). Kept alive for as long as a context references
  # it (OpenSSL up-refs on SSL_CTX_use_PrivateKey, so finalize is safe).
  class KeyPair
    getter handle : LibCrypto::EVP_PKEY

    def initialize(@handle : LibCrypto::EVP_PKEY)
    end

    def self.generate_ec : KeyPair
      eckey = LibCrypto.ec_key_new_by_curve_name(NID_PRIME256V1)
      raise Gori::Error.new("EC_KEY_new_by_curve_name failed") if eckey.null?
      if LibCrypto.ec_key_generate_key(eckey) != 1
        LibCrypto.ec_key_free(eckey)
        raise Gori::Error.new("EC_KEY_generate_key failed")
      end
      pkey = LibCrypto.evp_pkey_new
      if pkey.null?
        LibCrypto.ec_key_free(eckey)
        raise Gori::Error.new("EVP_PKEY_new failed")
      end
      # EVP_PKEY takes ownership of eckey only on success; on failure free BOTH the
      # eckey and the freshly allocated pkey (else the pkey leaks).
      if LibCrypto.evp_pkey_assign(pkey, EVP_PKEY_EC, eckey.as(Void*)) != 1
        LibCrypto.ec_key_free(eckey)
        LibCrypto.evp_pkey_free(pkey)
        raise Gori::Error.new("EVP_PKEY_assign failed")
      end
      new(pkey)
    end

    def write_pem(path : String) : Nil
      bio = LibCrypto.bio_new_file(path, "w")
      raise Gori::Error.new("BIO_new_file(#{path}) failed") if bio.null?
      begin
        ok = LibCrypto.pem_write_bio_privatekey(bio, @handle, Pointer(Void).null,
          Pointer(UInt8).null, 0, Pointer(Void).null, Pointer(Void).null)
        raise Gori::Error.new("PEM_write_bio_PrivateKey failed") if ok != 1
      ensure
        LibCrypto.BIO_free(bio)
      end
    end

    def self.read_pem(path : String) : KeyPair
      bio = LibCrypto.bio_new_file(path, "r")
      raise Gori::Error.new("BIO_new_file(#{path}) failed") if bio.null?
      begin
        pkey = LibCrypto.pem_read_bio_privatekey(bio, Pointer(LibCrypto::EVP_PKEY).null,
          Pointer(Void).null, Pointer(Void).null)
        raise Gori::Error.new("PEM_read_bio_PrivateKey failed") if pkey.null?
        new(pkey)
      ensure
        LibCrypto.BIO_free(bio)
      end
    end

    def finalize
      LibCrypto.evp_pkey_free(@handle)
    end
  end

  # Owns an X509 certificate. Like KeyPair, kept alive while referenced.
  class Cert
    getter handle : LibCrypto::X509

    def initialize(@handle : LibCrypto::X509)
    end

    def write_pem(path : String) : Nil
      bio = LibCrypto.bio_new_file(path, "w")
      raise Gori::Error.new("BIO_new_file(#{path}) failed") if bio.null?
      begin
        raise Gori::Error.new("PEM_write_bio_X509 failed") if LibCrypto.pem_write_bio_x509(bio, @handle) != 1
      ensure
        LibCrypto.BIO_free(bio)
      end
    end

    def self.read_pem(path : String) : Cert
      bio = LibCrypto.bio_new_file(path, "r")
      raise Gori::Error.new("BIO_new_file(#{path}) failed") if bio.null?
      begin
        x = LibCrypto.pem_read_bio_x509(bio, Pointer(LibCrypto::X509).null,
          Pointer(Void).null, Pointer(Void).null)
        raise Gori::Error.new("PEM_read_bio_X509 failed") if x.null?
        new(x)
      ensure
        LibCrypto.BIO_free(bio)
      end
    end

    def finalize
      LibCrypto.x509_free(@handle)
    end
  end
end
