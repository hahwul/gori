require "../proxy/tls/ffi"

# RSA-2048 keygen + SPKI-PEM export + RSA-OAEP(SHA-256) decrypt — the crypto interactsh
# mandates (the poll response ships an AES key encrypted to our RSA public key). Crystal
# stdlib has no RSA, so we extend the in-process OpenSSL FFI the project already uses for
# EC certs (src/gori/proxy/tls/ffi.cr + key_pair.cr).
#
# `lib LibCrypto` is declared at top level in ffi.cr; we REOPEN it here to append the RSA
# funs. We must NOT re-declare shared type aliases (EVP_PKEY from ffi.cr; Bio/BioMethod/
# EVP_MD/SizeT + BIO_new/BIO_free/evp_sha256 from stdlib) — that would collide. Only the
# funs stdlib/ffi.cr don't already bind are added below.
lib LibCrypto
  type RSA = Void*
  type BIGNUM = Void*
  type EVP_PKEY_CTX = Void*

  # RSA-2048 keygen (legacy path — mirrors ffi.cr's EC_KEY route, needs no EVP_PKEY_CTX_ctrl,
  # so the version-sensitive ctrl macros only bite on decrypt below).
  fun rsa_new = RSA_new : RSA
  fun rsa_free = RSA_free(rsa : RSA)
  fun bn_new = BN_new : BIGNUM
  fun bn_free = BN_free(bn : BIGNUM)
  fun bn_set_word = BN_set_word(bn : BIGNUM, w : ULong) : Int
  fun rsa_generate_key_ex = RSA_generate_key_ex(rsa : RSA, bits : Int, e : BIGNUM, cb : Void*) : Int

  # SPKI public-key PEM export + reading our own private-key PEM back (manual resume) via
  # memory BIOs. BIO_new / BIO_free / EVP_sha256 come from stdlib; BIO_s_mem / BIO_read /
  # BIO_new_mem_buf / PEM_write_bio_PUBKEY do not.
  fun bio_s_mem = BIO_s_mem : BioMethod*
  fun bio_read = BIO_read(b : Bio*, data : UInt8*, dlen : Int) : Int
  fun bio_new_mem_buf = BIO_new_mem_buf(buf : UInt8*, len : Int) : Bio*
  fun pem_write_bio_pubkey = PEM_write_bio_PUBKEY(bio : Bio*, pkey : EVP_PKEY) : Int

  # RSA-OAEP-SHA256 decrypt.
  fun evp_pkey_ctx_new = EVP_PKEY_CTX_new(pkey : EVP_PKEY, e : Void*) : EVP_PKEY_CTX
  fun evp_pkey_ctx_free = EVP_PKEY_CTX_free(ctx : EVP_PKEY_CTX)
  fun evp_pkey_decrypt_init = EVP_PKEY_decrypt_init(ctx : EVP_PKEY_CTX) : Int
  fun evp_pkey_ctx_ctrl = EVP_PKEY_CTX_ctrl(ctx : EVP_PKEY_CTX, keytype : Int, optype : Int,
                                            cmd : Int, p1 : Int, p2 : Void*) : Int
  fun evp_pkey_decrypt = EVP_PKEY_decrypt(ctx : EVP_PKEY_CTX, outbuf : UInt8*, outlen : SizeT*,
                                          inbuf : UInt8*, inlen : SizeT) : Int
end

module Gori::Oast
  # OpenSSL NID / padding / ctrl constants (kept OAST-local, not in Gori::Proxy::Tls).
  EVP_PKEY_RSA           =      6      # NID_rsaEncryption
  RSA_F4                 = 65537_u64   # public exponent e (0x10001)
  RSA_PKCS1_OAEP_PADDING =      4
  # EVP_PKEY_CTX_ctrl cmds: EVP_PKEY_ALG_CTRL (0x1000) + offset.
  EVP_PKEY_CTRL_RSA_PADDING = 0x1001
  EVP_PKEY_CTRL_RSA_MGF1_MD = 0x1005
  EVP_PKEY_CTRL_RSA_OAEP_MD = 0x1009

  # Owns an EVP_PKEY holding an RSA-2048 keypair. Kept alive while referenced; finalize
  # frees it (which frees the contained RSA — EVP_PKEY_assign took ownership).
  class RsaKeyPair
    getter handle : LibCrypto::EVP_PKEY

    def initialize(@handle : LibCrypto::EVP_PKEY)
    end

    # Generate a fresh RSA-2048 keypair (e = 65537). Explicit free on every failure branch,
    # mirroring KeyPair.generate_ec's ownership dance (EVP_PKEY owns the RSA on success).
    def self.generate_2048 : RsaKeyPair
      rsa = LibCrypto.rsa_new
      raise Gori::Error.new("RSA_new failed") if rsa.null?
      e = LibCrypto.bn_new
      if e.null?
        LibCrypto.rsa_free(rsa)
        raise Gori::Error.new("BN_new failed")
      end
      if LibCrypto.bn_set_word(e, RSA_F4) != 1
        LibCrypto.bn_free(e)
        LibCrypto.rsa_free(rsa)
        raise Gori::Error.new("BN_set_word failed")
      end
      if LibCrypto.rsa_generate_key_ex(rsa, 2048, e, Pointer(Void).null) != 1
        LibCrypto.bn_free(e)
        LibCrypto.rsa_free(rsa)
        raise Gori::Error.new("RSA_generate_key_ex failed")
      end
      LibCrypto.bn_free(e)

      pkey = LibCrypto.evp_pkey_new
      if pkey.null?
        LibCrypto.rsa_free(rsa)
        raise Gori::Error.new("EVP_PKEY_new failed")
      end
      if LibCrypto.evp_pkey_assign(pkey, EVP_PKEY_RSA, rsa.as(Void*)) != 1
        LibCrypto.rsa_free(rsa)
        LibCrypto.evp_pkey_free(pkey)
        raise Gori::Error.new("EVP_PKEY_assign(RSA) failed")
      end
      new(pkey)
    end

    # Re-import a previously exported private-key PEM (manual session resume).
    def self.from_private_pem(pem : String) : RsaKeyPair
      bio = LibCrypto.bio_new_mem_buf(pem.to_unsafe, pem.bytesize)
      raise Gori::Error.new("BIO_new_mem_buf failed") if bio.null?
      begin
        pkey = LibCrypto.pem_read_bio_privatekey(bio, Pointer(LibCrypto::EVP_PKEY).null,
          Pointer(Void).null, Pointer(Void).null)
        raise Gori::Error.new("PEM_read_bio_PrivateKey failed") if pkey.null?
        new(pkey)
      ensure
        LibCrypto.BIO_free(bio)
      end
    end

    # The SubjectPublicKeyInfo PEM ("-----BEGIN PUBLIC KEY-----"). interactsh's /register
    # wants this base64-encoded (the caller does the outer Base64).
    def public_spki_pem : String
      bio = LibCrypto.BIO_new(LibCrypto.bio_s_mem)
      raise Gori::Error.new("BIO_new(mem) failed") if bio.null?
      begin
        raise Gori::Error.new("PEM_write_bio_PUBKEY failed") if LibCrypto.pem_write_bio_pubkey(bio, @handle) != 1
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

    # Also export the PRIVATE key PEM (persisted so a session can be manually resumed).
    def private_pem : String
      bio = LibCrypto.BIO_new(LibCrypto.bio_s_mem)
      raise Gori::Error.new("BIO_new(mem) failed") if bio.null?
      begin
        ok = LibCrypto.pem_write_bio_privatekey(bio, @handle, Pointer(Void).null,
          Pointer(UInt8).null, 0, Pointer(Void).null, Pointer(Void).null)
        raise Gori::Error.new("PEM_write_bio_PrivateKey failed") if ok != 1
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

    # RSA-OAEP(SHA-256, MGF1=SHA-256) decrypt. MGF1 MUST also be SHA-256 — OpenSSL defaults
    # it to SHA-1, and interactsh's Go server uses SHA-256 for both, so omitting the MGF1
    # ctrl makes every decrypt silently fail. optype = -1 keeps the ctrl calls
    # version-independent across OpenSSL 1.1.1 (macros) and 3.x (functions).
    def oaep_sha256_decrypt(ciphertext : Bytes) : Bytes
      ctx = LibCrypto.evp_pkey_ctx_new(@handle, Pointer(Void).null)
      raise Gori::Error.new("EVP_PKEY_CTX_new failed") if ctx.null?
      begin
        raise Gori::Error.new("EVP_PKEY_decrypt_init failed") if LibCrypto.evp_pkey_decrypt_init(ctx) != 1
        md = LibCrypto.evp_sha256
        ctrl(ctx, EVP_PKEY_CTRL_RSA_PADDING, RSA_PKCS1_OAEP_PADDING, Pointer(Void).null)
        ctrl(ctx, EVP_PKEY_CTRL_RSA_OAEP_MD, 0, md.as(Void*))
        ctrl(ctx, EVP_PKEY_CTRL_RSA_MGF1_MD, 0, md.as(Void*))

        inptr = ciphertext.to_unsafe
        inlen = LibC::SizeT.new(ciphertext.size)
        outlen = LibC::SizeT.new(0)
        if LibCrypto.evp_pkey_decrypt(ctx, Pointer(UInt8).null, pointerof(outlen), inptr, inlen) != 1
          raise Gori::Error.new("EVP_PKEY_decrypt sizing failed")
        end
        decoded = Bytes.new(outlen.to_i)
        if LibCrypto.evp_pkey_decrypt(ctx, decoded.to_unsafe, pointerof(outlen), inptr, inlen) != 1
          raise Gori::Error.new("RSA-OAEP decrypt failed")
        end
        decoded[0, outlen.to_i]
      ensure
        LibCrypto.evp_pkey_ctx_free(ctx)
      end
    end

    def finalize
      LibCrypto.evp_pkey_free(@handle)
    end

    private def ctrl(ctx : LibCrypto::EVP_PKEY_CTX, cmd : Int32, p1 : Int32, p2 : Void*) : Nil
      if LibCrypto.evp_pkey_ctx_ctrl(ctx, EVP_PKEY_RSA, -1, cmd, p1, p2) != 1
        raise Gori::Error.new("EVP_PKEY_CTX_ctrl(cmd=#{cmd}) failed")
      end
    end
  end
end
