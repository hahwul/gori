require "base64"
require "digest/sha256"
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

    # Owner-only from the first byte. `BIO_new_file` goes through fopen(), which creates at
    # the umask default (0644 on a stock box) — so chmod'ing AFTER the write leaves both a
    # window where a machine secret is world-readable and, if the process dies in between, a
    # key that STAYS that way: nothing re-modes a file that already exists (CertAuthority's
    # create-time chmod only ever ran on the branch that mints the key). Set the mode first
    # instead, at the one place every private key is written.
    #
    # Truncating here is not a new risk — the "w" BIO truncates anyway — and a caller
    # replacing a LIVE key stages to a temp file and renames (see CertAuthority#install!),
    # so a failed write never lands on the real key path.
    def write_pem(path : String) : Nil
      perm = File::Permissions.new(0o600)
      # `perm:` applies only to a file File.open CREATES, so chmod as well: a `.tmp` left by
      # an earlier crashed write would otherwise keep its old mode and carry it through the
      # rename. Unrescued, unlike the load-path re-assert — a key we are minting right now
      # and cannot protect is not a key to hand out.
      File.open(path, "w", perm: perm) { }
      File.chmod(path, perm)
      bio = LibCrypto.bio_new_file(path, "wb") # binary: a text-mode Windows fopen writes CRLF
      raise Gori::Error.new("BIO_new_file(#{path}) failed") if bio.null?
      begin
        ok = LibCrypto.pem_write_bio_privatekey(bio, @handle, Pointer(Void).null,
          Pointer(UInt8).null, 0, Pointer(Void).null, Pointer(Void).null)
        raise Gori::Error.new("PEM_write_bio_PrivateKey failed") if ok != 1
      ensure
        LibCrypto.BIO_free(bio)
      end
    end

    # Whether a PEM private key file carries a passphrase: the PKCS#8 "ENCRYPTED PRIVATE KEY"
    # header, or a traditional-format key's legacy `Proc-Type: 4,ENCRYPTED` line. Reads only
    # the head of the file, enough for both markers.
    def self.encrypted_pem?(path : String) : Bool
      buf = Bytes.new(4096)
      n = File.open(path, &.read(buf))
      head = String.new(buf[0, n])
      head.includes?("ENCRYPTED PRIVATE KEY") || head.includes?("Proc-Type: 4,ENCRYPTED")
    rescue
      false
    end

    def self.read_pem(path : String) : KeyPair
      bio = LibCrypto.bio_new_file(path, "r")
      raise Gori::Error.new("BIO_new_file(#{path}) failed") if bio.null?
      begin
        pkey = LibCrypto.pem_read_bio_privatekey(bio, Pointer(LibCrypto::EVP_PKEY).null,
          Pointer(Void).null, NO_PASSPHRASE)
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
      # Binary, so the file is byte-identical to `to_pem`: a text-mode Windows fopen writes CRLF.
      bio = LibCrypto.bio_new_file(path, "wb")
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

    # Base64(SHA-256(DER SubjectPublicKeyInfo)) — the value a Chromium browser wants in
    # `--ignore-certificate-errors-spki-list` to trust exactly this certificate's key. On the
    # cert rather than the CA so a process holding only the cert file (`gori run browser`)
    # pins the same value the TUI does.
    def spki_sha256_base64 : String
      pubkey = LibCrypto.x509_get_x509_pubkey(@handle)
      raise Gori::Error.new("X509_get_X509_PUBKEY failed") if pubkey.null?
      len = LibCrypto.i2d_x509_pubkey(pubkey, Pointer(Pointer(UInt8)).null)
      raise Gori::Error.new("i2d_X509_PUBKEY sizing failed") if len <= 0
      der = Bytes.new(len)
      ptr = der.to_unsafe
      LibCrypto.i2d_x509_pubkey(pubkey, pointerof(ptr)) # writes into der, advances ptr
      Base64.strict_encode(Digest::SHA256.digest(der))
    end

    # The 8-hex-digit `subject_hash_old` Android's system CA store names this cert's file by
    # (`c317345c.0`), as `openssl x509 -subject_hash_old` prints it.
    def subject_hash_old : String
      "%08x" % LibCrypto.x509_subject_name_hash_old(@handle)
    end

    # The certificate's SHA-256 fingerprint as `openssl x509 -fingerprint -sha256`, Firefox and
    # the OS certificate viewers print it: the digest of the DER, upper-case hex in colon
    # pairs. This is the value to compare after an install. The SPKI pin is a different
    # digest (of the public key, base64) that only Chromium's flag takes.
    def self.sha256_fingerprint(der : Bytes) : String
      Digest::SHA256.digest(der).join(':') { |b| "%02X" % b }
    end

    def sha256_fingerprint : String
      Cert.sha256_fingerprint(to_der)
    end

    # RFC 2253 string escaping minus ESC_MSB (so UTF-8 stays readable) — UTF8_CONVERT turns a
    # BMPString into UTF-8 instead of its raw UTF-16, ESC_CTRL writes a control byte as `\1B` —
    # with `, ` between attributes, short field names, and an unknown attribute as its dotted OID.
    # Forward order, as `openssl x509 -subject` prints it.
    # LibC::ULong, not UInt64: it is 32 bits on Windows, and the value fits either way.
    SUBJECT_PRINT_FLAGS = LibC::ULong.new((0x317 & ~0x4) | (2 << 16) | (1 << 24))

    # The subject as `C=KR, O=…, CN=gori Root CA`. Not stdlib's `X509::Name#to_a`: it copies a
    # value's bytes whatever the string type, so a BMPString CN (common on enterprise roots)
    # came out as UTF-16 garbage — invalid UTF-8 in `gori ca info --json` — and an ESC in an
    # imported root's CN reached the terminal raw.
    def subject : String
      name = LibCrypto.x509_get_subject_name(@handle)
      raise Gori::Error.new("X509_get_subject_name failed") if name.null?
      bio = LibCrypto.BIO_new(LibCrypto.bio_s_mem)
      raise Gori::Error.new("BIO_new(mem) failed") if bio.null?
      begin
        raise Gori::Error.new("X509_NAME_print_ex failed") if LibCrypto.x509_name_print_ex(bio, name, 0, SUBJECT_PRINT_FLAGS) < 0
        io = IO::Memory.new
        buf = Bytes.new(1024)
        while (n = LibCrypto.bio_read(bio, buf.to_unsafe, buf.size)) > 0
          io.write(buf[0, n])
        end
        io.to_s.scrub
      ensure
        LibCrypto.BIO_free(bio)
      end
    end

    def not_before : Time
      asn1_time(LibCrypto.x509_getm_not_before(@handle))
    end

    def not_after : Time
      asn1_time(LibCrypto.x509_getm_not_after(@handle))
    end

    # ASN1_TIME_diff from now, not ASN1_TIME_to_tm: no `struct tm` to bind per platform, and
    # second precision is all a validity line prints.
    private def asn1_time(t : LibCrypto::ASN1_TIME) : Time
      days = 0
      secs = 0
      raise Gori::Error.new("ASN1_TIME_diff failed") if LibCrypto.asn1_time_diff(pointerof(days), pointerof(secs), Pointer(Void).null.as(LibCrypto::ASN1_TIME), t) != 1
      Time.utc.at_beginning_of_second + days.days + secs.seconds
    end

    # DER (binary ASN.1) encoding of the certificate — the form OS/browser trust
    # stores accept for a double-click install (the self-serve CA download page's
    # .der/.crt route). A null `pp` first sizes the buffer, then i2d writes into it
    # and ADVANCES the pointer (hence a local copy of `der.to_unsafe`), mirroring
    # #spki_sha256_base64.
    def to_der : Bytes
      len = LibCrypto.i2d_x509(@handle, Pointer(Pointer(UInt8)).null)
      raise Gori::Error.new("i2d_X509 sizing failed") if len <= 0
      der = Bytes.new(len)
      ptr = der.to_unsafe
      LibCrypto.i2d_x509(@handle, pointerof(ptr))
      der
    end

    # PEM encoding, byte-identical to what write_pem puts in a file (RFC 7468: base64 in
    # 64-column lines between the CERTIFICATE labels), built from to_der so it needs no
    # memory BIO.
    def to_pem : String
      String.build do |io|
        io << "-----BEGIN CERTIFICATE-----\n"
        Base64.strict_encode(to_der).each_char.each_slice(64) { |line| io << line.join << '\n' }
        io << "-----END CERTIFICATE-----\n"
      end
    end

    def finalize
      LibCrypto.x509_free(@handle)
    end
  end
end
