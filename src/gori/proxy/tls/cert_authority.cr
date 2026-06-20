require "base64"
require "digest/sha256"
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
      Dir.mkdir_p(dir)
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

    # PEM bytes of the root certificate, for the `ca export` verb / trust setup.
    def ca_cert_pem : String
      File.read(@ca_cert_path)
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
