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

    # `tighten: false` because `--ca-dir` is an OPERATOR-named path (four entry points: the
    # TUI, `gori ca`, `ca regenerate`, `ca import`), exactly like `--config` in #466 — gori
    # does not own a directory it merely FINDS, and a relative `--ca-dir certs` would re-mode
    # a checked-out directory, a bare `.` the working directory. A dir gori CREATES is still
    # made 0700 (see Paths.ensure_dir), and what actually protects the secret either way is
    # the key file's own 0600 below: the cert beside it is public by design.
    def self.load_or_create(dir : String, common_name : String = DEFAULT_CN) : CertAuthority
      Gori::Paths.ensure_dir(dir, tighten: false) # race-tolerant (two instances may start at once)
      cert_path = File.join(dir, CA_CERT_FILE)
      key_path = File.join(dir, CA_KEY_FILE)

      if File.exists?(cert_path) && File.exists?(key_path)
        # Re-assert the mode on EVERY load, not just at mint time: a key can arrive loose
        # from a pre-0600 gori, a `cp`/restore that dropped the mode, or a crash mid-write —
        # and nothing else would ever tighten it again. Mirrors Store.harden_permissions
        # re-locking the db on every open. Best-effort: a filesystem that cannot represent
        # 0600 (a mounted share) must not make gori refuse to start.
        File.chmod(key_path, 0o600) rescue nil
        new(Cert.read_pem(cert_path), KeyPair.read_pem(key_path), cert_path)
      elsif File.exists?(cert_path) || File.exists?(key_path)
        # Exactly ONE of the pair survives — a partial restore, an accidental `rm
        # root.key.pem`, a disk fault that clobbered one inode. This is NOT the first-run
        # case (neither file exists, handled below) and must not be folded into it: a lone
        # cert can't sign anything without its key, and a lone key has no certificate left
        # to present as the root a client already trusts. Silently minting a fresh pair here
        # would overwrite the survivor with a brand-new root — same identity swap as
        # `regenerate!`, but done by ACCIDENT and reported as clean success. Refuse instead,
        # naming exactly which file is missing, so the operator can restore it from backup
        # or make the swap deliberately via `gori ca regenerate` (which also re-trusts
        # clients as part of the workflow, not as a silent side effect).
        present = File.exists?(cert_path) ? CA_CERT_FILE : CA_KEY_FILE
        missing = File.exists?(cert_path) ? CA_KEY_FILE : CA_CERT_FILE
        raise Gori::Error.new(
          "CA pair broken in #{dir}: found #{present} but #{missing} is missing — restore " \
          "#{missing} from backup, or run `gori ca regenerate` to mint a fresh CA (existing " \
          "clients will need to re-trust it)")
      else
        cert, key = CertBuilder.build_root(common_name)
        cert.write_pem(cert_path)
        key.write_pem(key_path) # 0600 at CREATE time — see KeyPair#write_pem
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
      cert, key = CertAuthority.read_external_pair(cert_path, key_path)
      warning = CertAuthority.validate_ca_pair!(cert, key)
      install!(cert, key)
      warning
    end

    # Read + validate an external CA pair WITHOUT installing it. Lets a caller (the
    # CLI) reject a bad import BEFORE creating or loading any CA, so a failed import
    # never leaves a spurious auto-generated CA behind. Same checks as import!.
    def self.validate_pem_pair(cert_path : String, key_path : String) : String?
      cert, key = read_external_pair(cert_path, key_path)
      validate_ca_pair!(cert, key)
    end

    # Read an OPERATOR-NAMED cert/key PEM pair (`gori ca import --cert/--key`, the TUI's
    # CA import overlay). Distinct from Cert/KeyPair.read_pem for its messages alone: those
    # surface the raw OpenSSL step ("BIO_new_file(nope.pem) failed", and — because a
    # directory opens fine — "PEM_read_bio_X509 failed" for `--cert ~/certs`), which names
    # an internal call instead of the mistake the operator made. Every path here is one they
    # typed, so a typo, a directory, an unreadable file and a file that simply isn't PEM are
    # the four likely inputs and each gets said plainly.
    def self.read_external_pair(cert_path : String, key_path : String) : {Cert, KeyPair}
      cert = read_operator_pem(cert_path, "certificate") { Cert.read_pem(cert_path) }
      key = read_operator_pem(key_path, "private key") { KeyPair.read_pem(key_path) }
      {cert, key}
    end

    private def self.read_operator_pem(path : String, what : String, &)
      raise Gori::Error.new("#{what} file not found: #{path}") unless File.exists?(path)
      raise Gori::Error.new("#{what} path is a directory, not a PEM file: #{path}") if File.directory?(path)
      raise Gori::Error.new("#{what} file is not readable: #{path}") unless File::Info.readable?(path)
      begin
        yield
      rescue Gori::Error
        raise Gori::Error.new("#{path} is not a PEM #{what} gori can read " \
                              "(expecting a -----BEGIN …----- block)")
      end
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
      # A pair can pass BOTH checks above and still be useless to gori: CertBuilder signs
      # every leaf with SHA-256, and an Ed25519/Ed448 key cannot sign with a digest at all
      # (X509_sign fails). Such a root imported "successfully", was persisted, and then broke
      # EVERY interception with "X509_sign failed" at the first CONNECT — a working import
      # reported as success followed by a proxy that MITMs nothing. Signature algorithms are
      # not enumerable from here, so prove it functionally: mint one throwaway leaf. `.invalid`
      # (RFC 2606) can never be a real SNI host, and build_leaf touches no cache or file, so
      # the probe is pure. Runs before the time checks so a hard "cannot sign" wins over the
      # soft expiry warning.
      #
      # The message cannot name the offending algorithm: EVP_PKEY_id is a real symbol in
      # OpenSSL 1.1.1 but a macro alias for EVP_PKEY_get_id in 3.x, so binding either one
      # fails to link against the other — and gori builds against both (Homebrew 3.x, distro
      # 1.1.1, the static-musl release). Naming the two key types that hit this, plus the two
      # that work, is as actionable and cannot mislead about an unfamiliar third.
      begin
        CertBuilder.build_leaf("probe.invalid", cert, key)
      rescue
        raise Gori::Error.new(
          "gori cannot sign certificates with this CA key — leaf certificates are signed " \
          "with SHA-256, which Ed25519 and Ed448 keys do not support; use an EC P-256 or an " \
          "RSA root CA")
      end
      if LibCrypto.x509_cmp_time(LibCrypto.x509_getm_not_after(cert.handle), Pointer(Void).null) < 0
        return "certificate is expired"
      end
      if LibCrypto.x509_cmp_time(LibCrypto.x509_getm_not_before(cert.handle), Pointer(Void).null) > 0
        return "certificate is not valid yet"
      end
      nil
    end

    # Persist a cert/key pair over the on-disk root (write_pair) and swap it live. Shared by
    # regenerate! and import!, which run against a LOADED CA — a running proxy, the TUI
    # palette — so the in-memory swap and the cache drop belong here rather than in write_pair.
    private def install!(cert : Cert, key : KeyPair) : Nil
      CertAuthority.write_pair(File.dirname(@ca_cert_path), cert, key)
      @mutex.synchronize do
        @cert = cert
        @key = key
        @cache.clear # old leaves were signed by the previous root — drop them
      end
    end

    # Write a cert/key pair over the root PEMs in `dir` and return the cert path. The
    # class-level half of install! — no loaded CA required, which is what lets
    # regenerate_at/import_at repair a directory nothing can load (see those).
    #
    # Overwriting a WORKING CA means a half-written pair (disk full, a permission error) must
    # not corrupt it: stage both PEMs in full to temp files, then rename into place (atomic on
    # POSIX; both temps already exist, so the on-disk cert/key never disagree past the gap
    # between the two renames). A crash inside that gap does leave a mismatched pair — hence
    # key_matches_cert?, and hence regenerate_at not needing a loadable CA to fix one.
    def self.write_pair(dir : String, cert : Cert, key : KeyPair) : String
      # Full parity with load_or_create, `tighten:` included: the dir may have been removed
      # at runtime, and re-creating it must not re-mode an operator's --ca-dir either.
      Gori::Paths.ensure_dir(dir, tighten: false)
      cert_path = File.join(dir, CA_CERT_FILE)
      key_path = File.join(dir, CA_KEY_FILE)
      cert_tmp = "#{cert_path}.tmp"
      key_tmp = "#{key_path}.tmp"
      begin
        cert.write_pem(cert_tmp)
        # 0600 before any key bytes reach the temp (KeyPair#write_pem); rename moves the
        # inode, mode and all, so the installed key is never briefly readable.
        key.write_pem(key_tmp)
        File.rename(key_tmp, key_path)
        File.rename(cert_tmp, cert_path)
      rescue ex
        File.delete?(cert_tmp)
        File.delete?(key_tmp)
        raise ex
      end
      cert_path
    end

    # Mint a fresh root straight into `dir`, WITHOUT loading whatever is there. Returns the
    # cert path.
    #
    # This exists because load_or_create is the wrong entry point for a rotation. It refuses a
    # half-present pair (a lone root.crt.pem after an `rm` of the key, a partial restore) and
    # tells the operator to "run `gori ca regenerate`" — but regenerate itself went through
    # load_or_create, so it hit the same refusal and aborted. The advertised repair was blocked
    # by the very check that advertised it, leaving no non-manual way out of a broken CA dir.
    # A rotation never needs the old pair, so it no longer asks for it.
    def self.regenerate_at(dir : String, common_name : String = DEFAULT_CN) : String
      cert, key = CertBuilder.build_root(common_name)
      write_pair(dir, cert, key)
    end

    # Install an external root into `dir` without loading what is there — the import twin of
    # regenerate_at, and the repair path for the same broken-pair dead end. Validation runs
    # first, so a bad pair leaves the directory exactly as it was. Returns the installed cert
    # path plus import!'s soft warning (expired / not-yet-valid), if any.
    def self.import_at(dir : String, cert_path : String, key_path : String) : {String, String?}
      cert, key = read_external_pair(cert_path, key_path)
      warning = validate_ca_pair!(cert, key)
      {write_pair(dir, cert, key), warning}
    end

    # Does the private key actually belong to the certificate? load_or_create does not ask
    # (nothing did), and a mismatch is silent-by-construction — see usability_error.
    def key_matches_cert? : Bool
      @mutex.synchronize { LibCrypto.x509_check_private_key(@cert.handle, @key.handle) == 1 }
    end

    # Why this loaded CA cannot actually serve, phrased as a cause, or nil if it can. The two
    # ways a CA that LOADS is still broken, both of them silent-by-construction:
    #
    #   - the key does not match the cert (a crash inside write_pair's rename gap, one file of
    #     the pair hand-copied from another machine)
    #   - gori cannot sign with the key at all (an Ed25519 root that a pre-fix `gori ca import`
    #     accepted before validate_ca_pair! probed for this)
    #
    # Neither produces a gori-side error: gori starts, and every handshake fails at the CLIENT
    # ("unknown CA", "bad signature") or dies mid-CONNECT. So `gori ca`, the CA's diagnostic
    # command, asks both questions and is the one place either gets named. Cheap enough to run
    # on every invocation: one X509_check_private_key, and one throwaway leaf mint.
    def usability_error : String?
      return "the private key does not match the certificate" unless key_matches_cert?
      begin
        @mutex.synchronize { CertBuilder.build_leaf("probe.invalid", @cert, @key) }
      rescue
        return "gori cannot sign leaf certificates with this CA key (leaves are signed with " \
               "SHA-256, which Ed25519 and Ed448 keys do not support)"
      end
      nil
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
