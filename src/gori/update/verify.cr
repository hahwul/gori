# Tar-entry safety, download progress, and SHA-256 verification — reopens Gori::Update.
# Split out of update.cr along the banners that file already drew; `run` and the rest of
# the CLI orchestration stay there.
module Gori::Update
  # ---------------------------------------------------------------------------
  # Tar safety (listing only — pure relative to process I/O but testable with fixtures)
  # ---------------------------------------------------------------------------

  # Reject absolute paths and `..` segments (tar slip).
  def self.unsafe_tar_entry?(entry : String) : Bool
    e = entry.strip
    return false if e.empty?
    return true if e.starts_with?('/')
    e.split('/').any? { |seg| seg == ".." }
  end

  def self.assert_safe_tar_listing(listing : String) : Nil
    listing.each_line do |entry|
      if unsafe_tar_entry?(entry)
        raise Error.new("refusing archive with unsafe path entry: #{entry.strip}")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Download progress (pure formatters + streaming copy)
  # ---------------------------------------------------------------------------

  # Human-readable byte size with a space before the unit (e.g. "12.4 MB").
  def self.format_size(bytes : Int64) : String
    n = bytes.to_f
    return "#{bytes} B" if n < 1024
    n /= 1024
    return "#{round1(n)} kB" if n < 1024
    n /= 1024
    return "#{round1(n)} MB" if n < 1024
    n /= 1024
    return "#{round1(n)} GB" if n < 1024
    "#{round1(n / 1024)} TB"
  end

  # Elapsed span for download summaries ("850ms", "5.1s").
  def self.format_duration(span : Time::Span) : String
    ms = span.total_milliseconds
    return "#{ms.round.to_i}ms" if ms < 1000
    "#{round1(span.total_seconds)}s"
  end

  # Horizontal block bar of `done/total`, exactly `width` columns.
  # Unknown total (total <= 0) → empty string (caller uses indeterminate line).
  def self.format_progress_bar(done : Int64, total : Int64, width : Int32 = PROGRESS_BAR_WIDTH) : String
    return "" if width <= 0
    return "░" * width if total <= 0
    frac = (done.to_f / total.to_f).clamp(0.0, 1.0)
    filled = (frac * width).round.to_i
    filled = 1 if filled < 1 && done > 0
    filled = width if filled > width
    String.build do |io|
      filled.times { io << '█' }
      (width - filled).times { io << '░' }
    end
  end

  # One progress line (no trailing newline). When total is unknown, omit the bar/%.
  def self.format_progress_line(done : Int64, total : Int64, *,
                                elapsed : Time::Span = Time::Span::ZERO,
                                width : Int32 = PROGRESS_BAR_WIDTH) : String
    rate = if elapsed.total_seconds > 0
             format_size((done.to_f / elapsed.total_seconds).round.to_i64) + "/s"
           else
             "—/s"
           end
    if total > 0
      pct = ((done.to_f / total.to_f) * 100).clamp(0.0, 100.0).round.to_i
      bar = format_progress_bar(done, total, width)
      "#{bar}  #{pct.to_s.rjust(3)}%  #{format_size(done)} / #{format_size(total)}  #{rate}"
    else
      "#{format_size(done)}  #{rate}"
    end
  end

  private def self.round1(n : Float64) : String
    ((n * 10).round / 10.0).to_s
  end

  # Stream body_io → dest with optional live progress on a TTY (or when force_progress).
  # Returns bytes written. `on_progress` is always invoked when present (for tests).
  def self.copy_with_progress(body_io : IO, dest : String, total : Int64, *,
                              progress_io : IO? = nil,
                              on_progress : Proc(Int64, Int64, Nil)? = nil,
                              force_progress : Bool = false) : Int64
    show = force_progress || !!(progress_io && progress_io.tty?)
    started = Time.instant
    last_draw = Time.instant - PROGRESS_MIN_INTERVAL # allow first draw immediately
    downloaded = 0_i64
    buf = Bytes.new(PROGRESS_CHUNK)

    begin
      File.open(dest, "w") do |file|
        loop do
          n = body_io.read(buf)
          break if n == 0
          file.write(buf[0, n])
          downloaded += n
          on_progress.try &.call(downloaded, total)

          if show && progress_io
            now = Time.instant
            if now - last_draw >= PROGRESS_MIN_INTERVAL || (total > 0 && downloaded >= total)
              line = format_progress_line(downloaded, total, elapsed: started.elapsed)
              progress_io.print "\r\e[K  #{line}"
              progress_io.flush
              last_draw = now
            end
          end
        end
      end
    ensure
      # In an `ensure`, not after the loop: a reset mid-transfer left the last
      # bar standing and the error message was then printed onto that same
      # line, right after the rate — the one moment the operator most needs to
      # read it. The line belongs to this method either way it exits.
      if show && progress_io
        progress_io.print "\r\e[K"
        progress_io.flush
      end
    end
    downloaded
  end

  # ---------------------------------------------------------------------------
  # Checksum verification (integrity, NOT authenticity — see NOTE)
  # ---------------------------------------------------------------------------
  #
  # NOTE: the digest verified here comes from the SAME release JSON that names
  # the asset. It defeats CDN/transfer tampering and wrong-asset installs (the
  # JSON is fetched over TLS from api.github.com; assets are redirected to a
  # separate CDN host), but it does NOT defeat an attacker who controls the
  # release itself — they would publish a fake tarball AND a matching digest.
  # True authenticity needs a signed checksums file verified against a public
  # key embedded in this binary (release-side infra; not implemented).
  HEX_SHA256 = /\A[0-9a-f]{64}\z/

  # Parse a GitHub asset digest ("sha256:<hex>") into a lowercase 64-char hex
  # string, or nil when absent/unsupported (older API, GHE, non-sha256 algo).
  def self.parse_sha256_digest(digest : String?) : String?
    return nil unless digest
    # `.scrub`: the digest is copied verbatim out of the release JSON, and `matches?` is a
    # PCRE2 call that raises `ArgumentError` on a non-UTF-8 subject — from inside
    # `verify_download!`, which has no rescue below `CLI.run`. A scrubbed digest simply
    # fails the hex test and returns nil, which is this method's documented "unsupported".
    d = digest.scrub.strip.downcase
    return nil unless d.starts_with?("sha256:")
    hex = d.lchop("sha256:")
    HEX_SHA256.matches?(hex) ? hex : nil
  end

  # Parses a `sha256sum`-style SHA256SUMS body into {asset name => hex}. Lines
  # are "<64 hex><spaces><name>", the name optionally prefixed with `*` for
  # binary mode. Anything that does not match that shape is skipped rather than
  # raising — a malformed line must not cost us the checksums we can read.
  def self.parse_checksums(text : String) : Hash(String, String)
    sums = {} of String => String
    text.each_line do |line|
      # `.scrub` per line: the SHA256SUMS body is fetched over the network, and the
      # `split(/\s+/, 2)` is a PCRE2 call that raises `ArgumentError` on a non-UTF-8
      # subject — which would break this method's documented contract that a malformed
      # line is SKIPPED rather than raised on.
      parts = line.scrub.strip.split(/\s+/, 2)
      next unless parts.size == 2
      hex = parts[0].downcase
      next unless HEX_SHA256.matches?(hex)
      name = parts[1].strip.lchop('*')
      sums[name] = hex unless name.empty?
    end
    sums
  end

  # Streamed SHA256 of a file as lowercase hex (constant memory).
  def self.file_sha256(path : String) : String
    digest = Digest::SHA256.new
    io_guard("could not read #{path} to checksum it") do
      File.open(path) do |file|
        buf = Bytes.new(PROGRESS_CHUNK)
        loop do
          n = file.read(buf)
          break if n == 0
          digest.update(buf[0, n])
        end
      end
    end
    digest.hexfinal
  end

  # Verify a downloaded file against the expected sha256 hex; raise on mismatch.
  # No-op when `expected_hex` is nil (release JSON advertised no usable digest)
  # so behavior is preserved against older APIs — keeps this change non-breaking.
  def self.verify_sha256!(path : String, expected_hex : String?, asset_name : String) : Nil
    return unless expected_hex
    actual = file_sha256(path)
    return if actual == expected_hex
    raise Error.new(
      "checksum mismatch for #{asset_name}: expected sha256 #{expected_hex} " \
      "but got #{actual} (download corrupted or tampered in transit)"
    )
  end
end
