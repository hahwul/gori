require "json"
require "./settings"
require "./store"

module Gori
  # Global + per-project environment variables for `$KEY`-style substitution in
  # outbound requests (Repeater, Fuzzer, Miner, Intercept, CLI, MCP). The editor
  # keeps the raw `$KEY` text; `expand` runs at send time only. Highlighting
  # reuses the same prefix/KEY rules via `token_regions`.
  module Env
    DEFAULT_PREFIX   = "$"
    PROJECT_VARS_KEY = "env.vars"
    KEY_HEAD         = /[A-Za-z_]/
    KEY_TAIL         = /[A-Za-z0-9_]/

    @@highlight_rev : UInt32 = 0

    def self.highlight_rev : UInt32
      @@highlight_rev
    end

    def self.bump_highlight_rev : Nil
      @@highlight_rev += 1
    end

    # Merged vars: global first, then project (project wins on KEY collision).
    def self.effective_vars : Hash(String, String)
      h = {} of String => String
      Settings.env_vars.each { |(k, v)| h[k] = v }
      Settings.project_env_vars.each { |(k, v)| h[k] = v }
      h
    end

    # Expand env tokens in wire-form HTTP text (LF or CRLF) and return CRLF bytes.
    # Normalizes newlines with a byte-level scan (`normalize_crlf`) — NOT
    # `gsub(/\r?\n/, "\r\n")` and NOT `split('\n').join("\r\n")` — for two reasons:
    # the gsub-vs-split/join distinction avoids doubling already-CRLF input
    # (captured flow bytes) into `\r\r\n`, which would destroy the head/body
    # separator and break framing on every CLI/MCP repeater+mine send path; and a
    # `Regex` (gsub) *requires* valid UTF-8 and raises `ArgumentError` on a subject
    # string that isn't — which a captured flow's binary body routinely isn't. See
    # `expand` below for why the text reaching this point may carry invalid UTF-8.
    #
    # CRLF normalization is HEAD-ONLY: a raw `0x0A` inside the BODY is just a byte
    # (binary/compressed data, or a bare LF a client legitimately sent) — not a line
    # ending — and must never be rewritten to `0x0D 0x0A`. Only HTTP header lines
    # require CRLF termination on the wire; the editors that feed this (Repeater,
    # Miner) store the whole head+body blob as one LF-joined buffer, so naively
    # normalizing the entire buffer corrupted every bare-LF byte in the body
    # (silently, since Content-Length gets resynced to the corrupted body
    # afterward). `head_body_boundary` locates the blank-line separator first;
    # only the head (through and including that separator) is normalized, and the
    # body is copied through byte-for-byte untouched.
    def self.expand_wire(text : String, vars : Hash(String, String) = effective_vars,
                         prefix : String = Settings.env_prefix) : Bytes
      bytes = expand(text, vars, prefix).to_slice
      boundary = head_body_boundary(bytes)
      head = normalize_crlf(bytes[0...boundary])
      return head if boundary >= bytes.size

      body = bytes[boundary..]
      buf = IO::Memory.new(head.size + body.size)
      buf.write(head)
      buf.write(body)
      buf.to_slice
    end

    # Substitute registered `prefix+KEY` tokens; unknown keys stay literal.
    #
    # Operates on raw bytes, not `String#chars`. `prefix` and KEY names are always
    # ASCII (`KEY_HEAD`/`KEY_TAIL`), so a token can be found/replaced by scanning
    # bytes alone — never decoding to codepoints. That matters because the text
    # here can be a captured flow's body loaded verbatim into the Repeater editor,
    # which may contain byte sequences that are not valid UTF-8 (a raw binary
    # body). `String#chars` (the previous implementation) decodes lossily: any
    # invalid sequence is silently replaced by U+FFFD, corrupting the wire bytes
    # on every send — even when the text has no `$KEY` token at all. Scanning
    # bytes instead means every span that isn't part of a matched token — valid
    # UTF-8 or not — is copied through byte-for-byte, unchanged.
    def self.expand(text : String, vars : Hash(String, String) = effective_vars,
                    prefix : String = Settings.env_prefix) : String
      return text if prefix.empty?
      return text unless text.byte_index(prefix) # fast, lossless no-op when the prefix never occurs

      bytes = text.to_slice
      prefix_bytes = prefix.to_slice
      n = bytes.size
      plen = prefix_bytes.size
      buf = IO::Memory.new(n)
      i = 0
      while i < n
        if i + plen <= n && prefix_bytes.each_with_index.all? { |b, j| bytes[i + j] == b }
          if parsed = read_key_bytes(bytes, i + plen, n)
            key, consumed = parsed
            if val = vars[key]?
              buf << val
              i += plen + consumed
            else
              buf << prefix
              i += plen
            end
          else
            buf << prefix
            i += plen
          end
        else
          buf.write_byte(bytes[i])
          i += 1
        end
      end
      String.new(buf.to_slice)
    end

    # Finds the head/body boundary in wire-form text: the byte offset where the
    # body starts, right after the first blank line. Checks for both a bare
    # `\n\n` (how the Repeater/Miner editors store the blob internally) and,
    # defensively, an already-CRLF `\r\n\r\n` (e.g. captured flow bytes loaded
    # verbatim). Returns `bytes.size` when no blank line is found — an all-head
    # buffer (no body), which `expand_wire` then normalizes in full, matching the
    # pre-existing behavior for header-only text.
    private def self.head_body_boundary(bytes : Bytes) : Int32
      n = bytes.size
      i = 0
      while i < n
        if bytes[i] == 0x0A_u8 && i + 1 < n && bytes[i + 1] == 0x0A_u8
          return i + 2
        end
        if bytes[i] == 0x0D_u8 && i + 3 < n &&
           bytes[i + 1] == 0x0A_u8 && bytes[i + 2] == 0x0D_u8 && bytes[i + 3] == 0x0A_u8
          return i + 4
        end
        i += 1
      end
      n
    end

    # Byte-level equivalent of `gsub(/\r?\n/, "\r\n")`: inserts `\r` before any
    # `\n` not already preceded by one, leaving everything else untouched. Used
    # instead of a `Regex` because `bytes` (the expanded request text) may carry
    # invalid UTF-8, which `Regex` cannot accept as a subject.
    private def self.normalize_crlf(bytes : Bytes) : Bytes
      buf = IO::Memory.new(bytes.size)
      prev : UInt8 = 0
      bytes.each do |b|
        buf.write_byte(0x0D_u8) if b == 0x0A_u8 && prev != 0x0D_u8
        buf.write_byte(b)
        prev = b
      end
      buf.to_slice
    end

    # Scans the text for occurrences of any registered env var value and replaces
    # it with the corresponding token (e.g. "$KEY"). Longest value wins at each
    # position (avoids "secret_value" vs "secret" sub-string collisions).
    #
    # Single left-to-right pass (NOT sequential `gsub` per value): a `gsub` chain
    # can re-match a token an earlier replacement inserted — e.g. value "OKEN"
    # matching inside a just-inserted "$TOKEN" — silently corrupting the mask. The
    # pass never re-scans replaced spans, so inserted tokens stay intact.
    #
    # Byte-level, same reasoning as `expand`: callers pass raw request/response
    # text (e.g. MCP `send`/`repeater` tools mask a captured flow's raw bytes for
    # display), which may not be valid UTF-8. Scanning `text.chars` would silently
    # replace any invalid byte sequence with U+FFFD even where no secret value
    # matches nearby — corrupting the displayed/logged text on every call, not
    # just the masked spans. Byte-level value matching is also strictly more
    # precise than char matching: it finds a value's literal bytes regardless of
    # whether the surrounding haystack happens to be well-formed UTF-8.
    def self.mask_secrets(text : String, vars : Hash(String, String) = effective_vars,
                          prefix : String = Settings.env_prefix) : String
      return text if prefix.empty? || vars.empty?

      # Filter out empty values and short/common values that might lead to false positives (e.g., single characters)
      candidates = vars.to_a
        .reject { |(k, v)| v.strip.empty? || v.size < 4 }
        .sort_by! { |(k, v)| -v.bytesize }
        .map { |(k, v)| {k, v.to_slice} }

      return text if candidates.empty?

      bytes = text.to_slice
      n = bytes.size
      buf = IO::Memory.new(n)
      i = 0
      while i < n
        hit = candidates.find do |(_, vbytes)|
          i + vbytes.size <= n && vbytes.each_with_index.all? { |b, j| bytes[i + j] == b }
        end
        if hit
          buf << prefix << hit[0]
          i += hit[1].size
        else
          buf.write_byte(bytes[i])
          i += 1
        end
      end
      String.new(buf.to_slice)
    end

    # Char offsets [start, end) of each env-shaped token in `text` (end exclusive).
    # Char-based (not byte) — the consumer (Highlight.env_spans_in) slices with
    # `text[a...b]`, which is char-indexed in Crystal, so multi-byte text stays aligned.
    # `known` is true when KEY is registered in `vars`.
    def self.token_regions(text : String, prefix : String = Settings.env_prefix,
                           vars : Hash(String, String) = effective_vars) : Array({Int32, Int32, Bool})
      return [] of {Int32, Int32, Bool} if prefix.empty?
      regions = [] of {Int32, Int32, Bool}
      chars = text.chars
      n = chars.size
      plen = prefix.size
      prefix_chars = prefix.chars
      i = 0
      while i < n
        if i + plen <= n && prefix_chars.each_with_index.all? { |c, j| chars[i + j] == c }
          if parsed = read_key(chars, i + plen, n)
            key, consumed = parsed
            regions << {i, i + plen + consumed, vars.has_key?(key)}
            i += plen + consumed
          else
            i += plen
          end
        else
          i += 1
        end
      end
      regions
    end

    # Parse "KEY VALUE" or "KEY=value" (value may contain spaces when using the
    # space form). Which syntax was used is decided by whichever separator — `=`
    # or whitespace — appears FIRST in the string, not by whether `=` appears
    # anywhere at all: a space-form value that itself contains `=` (e.g. a
    # base64-padded API key, `APIKEY dGVzdA==`) must still split on the leading
    # whitespace, not on the `=` buried inside the value. Returns nil when KEY is
    # invalid.
    def self.parse_line(text : String) : {String, String}?
      raw = text.strip
      return nil if raw.empty?
      eq = raw.index('=')
      ws = raw.index(/\s/)
      if eq && (ws.nil? || eq < ws)
        key = raw[0...eq].strip
        val = raw[eq + 1..]
        return nil unless valid_key?(key)
        {key, val}
      else
        parts = raw.split(/\s+/, 2)
        return nil if parts.size < 2
        key = parts[0]
        return nil unless valid_key?(parts[0])
        {key, parts[1]}
      end
    end

    def self.parse_vars_json(raw : String?) : Array({String, String})
      return [] of {String, String} if raw.nil? || raw.strip.empty?
      arr = JSON.parse(raw).as_a?
      return [] of {String, String} unless arr
      out = [] of {String, String}
      arr.each do |e|
        next unless o = e.as_h?
        key = o["key"]?.try(&.as_s?)
        val = o["value"]?.try(&.as_s?)
        next if key.nil? || key.empty? || val.nil?
        next unless valid_key?(key)
        out << {key, val}
      end
      out
    end

    def self.serialize_vars(vars : Array({String, String})) : String
      JSON.build do |j|
        j.array do
          vars.each do |(key, val)|
            j.object do
              j.field "key", key
              j.field "value", val
            end
          end
        end
      end
    end

    def self.load_project(store : Store) : Nil
      Settings.project_env_vars = parse_vars_json(store.setting(PROJECT_VARS_KEY))
      bump_highlight_rev
    end

    def self.save_project(store : Store, vars : Array({String, String})) : Nil
      if vars.empty?
        store.delete_setting(PROJECT_VARS_KEY)
      else
        store.set_setting(PROJECT_VARS_KEY, serialize_vars(vars))
      end
      Settings.project_env_vars = vars.dup
      bump_highlight_rev
    end

    def self.valid_key?(key : String) : Bool
      return false if key.empty?
      return false unless KEY_HEAD.matches?(key[0].to_s)
      key.chars[1..].all? { |c| KEY_TAIL.matches?(c.to_s) }
    end

    private def self.read_key(chars : Array(Char), start : Int32, n : Int32) : {String, Int32}?
      return nil if start >= n || !KEY_HEAD.matches?(chars[start].to_s)
      j = start + 1
      while j < n && KEY_TAIL.matches?(chars[j].to_s)
        j += 1
      end
      {chars[start...j].join, j - start}
    end

    # Byte-level counterpart to `read_key`, used by `expand`. KEY_HEAD/KEY_TAIL
    # are pure-ASCII patterns, so matching a single byte at a time via `UInt8#chr`
    # (never decoding a multi-byte sequence) is exact — and safe on invalid UTF-8,
    # since a byte that's part of an invalid sequence simply won't match `[A-Za-z0-9_]`
    # and gets left alone by the caller.
    private def self.read_key_bytes(bytes : Bytes, start : Int32, n : Int32) : {String, Int32}?
      return nil if start >= n || !KEY_HEAD.matches?(bytes[start].chr.to_s)
      j = start + 1
      while j < n && KEY_TAIL.matches?(bytes[j].chr.to_s)
        j += 1
      end
      {String.new(bytes[start...j]), j - start}
    end
  end
end
