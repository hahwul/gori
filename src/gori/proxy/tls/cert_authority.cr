require "base64"
require "digest/sha256"
require "../../paths"
require "./cert_builder"
require "./context_factory"

module Gori::Proxy::Tls
  # The MITM certificate authority. Loads (or, on first run, generates and
  # persists) a root CA, then mints per-host leaf certs on demand and caches a
  # ready-to-use SSL server context per SNI host. Fiber-safe via a Mutex.
  class CertAuthority
    CA_CERT_FILE = "root.crt.pem"
    CA_KEY_FILE  = "root.key.pem"
    DEFAULT_CN   = "gori Root CA"
    # Bound the per-SNI leaf cache so a client (or a hostile SNI flood) can't grow
    # it without limit. Eviction is safe: SSL_CTX up-refs the cert/key, and a live
    # OpenSSL::SSL::Socket holds its Context, so an in-use context stays valid even
    # after its Leaf leaves the cache (a later request just rebuilds it).
    MAX_LEAVES = 256

    getter ca_cert_path : String

    # Holds the per-host leaf alive (cert + key) alongside its context so GC
    # doesn't collect FFI objects still referenced by the cached context.
    private record Leaf, context : OpenSSL::SSL::Context::Server, cert : Cert, key : KeyPair

    def initialize(@cert : Cert, @key : KeyPair, @ca_cert_path : String)
      # Keyed by {host, advertise_h2}: intercept downgrades a host to HTTP/1.1 by
      # presenting a context that does NOT advertise h2, so two variants per host
      # may coexist. Separate immutable contexts avoid racing a mutated context.
      @cache = {} of {String, Bool} => Leaf
      @mutex = Mutex.new
    end

    def self.load_or_create(dir : String, common_name : String = DEFAULT_CN) : CertAuthority
      Gori::Paths.ensure_dir(dir) # race-tolerant (two instances may start at once)
      cert_path = File.join(dir, CA_CERT_FILE)
      key_path = File.join(dir, CA_KEY_FILE)

      if File.exists?(cert_path) && File.exists?(key_path)
        new(Cert.read_pem(cert_path), KeyPair.read_pem(key_path), cert_path)
      else
        cert, key = CertBuilder.build_root(common_name)
        cert.write_pem(cert_path)
        key.write_pem(key_path)
        File.chmod(key_path, 0o600) # the CA private key is a machine secret
        new(cert, key, cert_path)
      end
    end

    # The SSL server context to present for a given SNI host (cached).
    # `advertise_h2: false` offers only HTTP/1.1 (clients fall back to h1) so the
    # connection flows through the interceptable path (used while intercept is on).
    def context_for(host : String, advertise_h2 : Bool = true) : OpenSSL::SSL::Context::Server
      @mutex.synchronize do
        key = {host, advertise_h2}
        if leaf = @cache[key]?
          # LRU bump: re-insert so the hot host survives eviction.
          @cache.delete(key)
          @cache[key] = leaf
          leaf.context
        else
          leaf = build_leaf(host, advertise_h2)
          @cache[key] = leaf
          if @cache.size > MAX_LEAVES && (oldest = @cache.first_key?)
            @cache.delete(oldest)
          end
          leaf.context
        end
      end
    end

    # PEM bytes of the root certificate, for `gori ca --pem` / TUI CA copy / trust setup.
    def ca_cert_pem : String
      File.read(@ca_cert_path)
    end

    # DER bytes of the root certificate, for the self-serve CA download page's .der
    # form. Encoded from the live in-memory cert (so it tracks regenerate!/import!),
    # unlike ca_cert_pem which reads the on-disk file.
    def ca_cert_der : Bytes
      @cert.to_der
    end

    # Regenerate the root CA in place: mint a brand-new self-signed root, persist
    # it over the existing PEM files, and drop the per-host leaf cache so every
    # subsequent connection is signed by the NEW root. The Tunnel/proxy hold THIS
    # object, so the swap is live (no restart) — but the new root is a different
    # key+identity, so any client that trusted the OLD CA must re-trust it.
    def regenerate!(common_name : String = DEFAULT_CN) : Nil
      cert, key = CertBuilder.build_root(common_name)
      install!(cert, key)
    end

    # Adopt an externally-created root CA (`gori ca import`): read the cert + key
    # PEMs, verify they are a usable CA pair, then swap them in over the current
    # root exactly like `regenerate!`. Returns a human warning (expired / not-yet-
    # valid) if the cert is time-invalid but otherwise usable, else nil. Raises
    # Gori::Error (leaving the current CA untouched) if a PEM won't parse or the
    # pair is unusable — validation runs BEFORE anything is written.
    def import!(cert_path : String, key_path : String) : String?
      cert = Cert.read_pem(cert_path)
      key = KeyPair.read_pem(key_path)
      warning = CertAuthority.validate_ca_pair!(cert, key)
      install!(cert, key)
      warning
    end

    # Read + validate an external CA pair WITHOUT installing it. Lets a caller (the
    # CLI) reject a bad import BEFORE creating or loading any CA, so a failed import
    # never leaves a spurious auto-generated CA behind. Same checks as import!.
    def self.validate_pem_pair(cert_path : String, key_path : String) : String?
      validate_ca_pair!(Cert.read_pem(cert_path), KeyPair.read_pem(key_path))
    end

    # Reject an imported pair that can't serve as a signing root; return a soft
    # warning for a time-invalid-but-usable cert. A mismatched key would make every
    # minted leaf fail verification, and a non-CA cert (basicConstraints CA:FALSE)
    # makes clients reject any leaf it signs — both are hard errors we catch up front.
    # A class method: it inspects the two handles via the FFI, no instance state.
    def self.validate_ca_pair!(cert : Cert, key : KeyPair) : String?
      if LibCrypto.x509_check_private_key(cert.handle, key.handle) != 1
        raise Gori::Error.new("private key does not match the certificate")
      end
      if LibCrypto.x509_check_ca(cert.handle) == 0
        raise Gori::Error.new("certificate is not a CA (basicConstraints CA:TRUE required)")
      end
      if LibCrypto.x509_cmp_time(LibCrypto.x509_getm_not_after(cert.handle), Pointer(Void).null) < 0
        return "certificate is expired"
      end
      if LibCrypto.x509_cmp_time(LibCrypto.x509_getm_not_before(cert.handle), Pointer(Void).null) > 0
        return "certificate is not valid yet"
      end
      nil
    end

    # Persist a cert/key pair over the on-disk root and swap it live. Shared by
    # regenerate! and import!. Overwriting a WORKING CA means a half-written pair
    # (disk full, a permission error) must not corrupt it: stage both PEMs in full
    # to temp files, then rename into place (atomic on POSIX; both temps already
    # exist, so the on-disk cert/key never disagree past the gap between renames).
    private def install!(cert : Cert, key : KeyPair) : Nil
      dir = File.dirname(@ca_cert_path)
      Gori::Paths.ensure_dir(dir) # parity with load_or_create: the dir may have been removed at runtime
      key_path = File.join(dir, CA_KEY_FILE)
      cert_tmp = "#{@ca_cert_path}.tmp"
      key_tmp = "#{key_path}.tmp"
      begin
        cert.write_pem(cert_tmp)
        key.write_pem(key_tmp)
        File.chmod(key_tmp, 0o600) # the CA private key is a machine secret
        File.rename(key_tmp, key_path)
        File.rename(cert_tmp, @ca_cert_path)
      rescue ex
        File.delete?(cert_tmp)
        File.delete?(key_tmp)
        raise ex
      end
      @mutex.synchronize do
        @cert = cert
        @key = key
        @cache.clear # old leaves were signed by the previous root — drop them
      end
    end

    # Base64(SHA-256(DER SubjectPublicKeyInfo)) of the root CA — the value a
    # Chromium browser wants in `--ignore-certificate-errors-spki-list` to trust
    # exactly this CA (and nothing else) for the launched session.
    def spki_sha256_base64 : String
      pubkey = LibCrypto.x509_get_x509_pubkey(@cert.handle)
      raise Gori::Error.new("X509_get_X509_PUBKEY failed") if pubkey.null?
      len = LibCrypto.i2d_x509_pubkey(pubkey, Pointer(Pointer(UInt8)).null)
      raise Gori::Error.new("i2d_X509_PUBKEY sizing failed") if len <= 0
      der = Bytes.new(len)
      ptr = der.to_unsafe
      LibCrypto.i2d_x509_pubkey(pubkey, pointerof(ptr)) # writes into der, advances ptr
      Base64.strict_encode(Digest::SHA256.digest(der))
    end

    private def build_leaf(host : String, advertise_h2 : Bool) : Leaf
      cert, key = CertBuilder.build_leaf(host, @cert, @key)
      ctx = ContextFactory.server_context(cert, key, ca_cert: @cert, advertise_h2: advertise_h2)
      Leaf.new(ctx, cert, key)
    end
  end
end
