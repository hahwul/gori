require "./proxy/codec/http1"

module Gori
  # Normalises cache-related response headers into ONE signal:
  # `hit | miss | dynamic | none` (#1247, PortSwigger "Gotta cache 'em all").
  #
  # It reports WHAT THE HEADERS SAY, not what a cache actually did — a response can be
  # cacheable but not yet cached, and the wire cannot always tell the two apart. So the
  # signal is deliberately conservative:
  #
  #   * `hit`     — evidence this response was served FROM a shared cache (a positive `Age`,
  #                 an `X-Cache: HIT`, a two-id `X-Varnish`, or a vendor status). This is the
  #                 deception candidate — confirm it with a no-session re-request
  #                 (`Gori::CacheDeception`).
  #   * `miss`    — evidence a cache SAW this response but went to the origin for it
  #                 (`X-Cache: MISS`, `CF-Cache-Status: MISS`/`EXPIRED`,
  #                 `X-Cache-Hits: 0`). Cacheable, not (yet) cached.
  #   * `dynamic` — the response declares itself UNCACHEABLE (`CF-Cache-Status: DYNAMIC`/
  #                 `BYPASS`, bare `Cache-Control: private`, or `no-store` without a shared-cache
  #                 max-age override). It will not be cached, so a deception attempt is expected
  #                 to fail.
  #   * `none`    — no cache verdict is present; this includes no cache headers and neutral values
  #                 such as `Age: 0` or field-limited `private="set-cookie"`.
  #
  # RFC 9211 `Cache-Status` uses the last recognized list member (closest to the client) when
  # present. Otherwise, ANY hit signal wins over any miss signal, which wins over a DYNAMIC
  # declaration. This feeds a cache-DECEPTION check, whose worst failure is calling a cached
  # private response uncached, so a positive `Age` or `X-Cache: HIT` anywhere in a cache chain
  # reports `hit` even next to an `X-Cache: MISS` from another tier or `Cache-Control: private`.
  #
  # Not a projection over the store and NO storage change (P7/P8, #1247): the value is computed
  # from `response_head` on read, in the SQLite UDF `gori_cache_status` (QL `cache:`) and in
  # Crystal for a `FlowDetail` in hand. The two share this one classifier so they cannot
  # disagree about what a header means.
  module CacheStatus
    enum Signal
      Hit
      Miss
      Dynamic
      None

      # The token QL matches and every surface prints — the field's whole value vocabulary.
      def token : String
        case self
        in Hit     then "hit"
        in Miss    then "miss"
        in Dynamic then "dynamic"
        in None    then "none"
        end
      end
    end

    # `cache:`'s WHOLE value vocabulary, for the completion pools (History's own table and
    # `InterceptFilter.suggest_values`) — beside the classifier so a value the classifier can
    # produce and a value a surface offers cannot drift. `none` is offered too: it is the
    # answer for a response with no cache headers, and a queryable one.
    VALUES = Signal.values.map(&.token)

    # The `CF-Cache-Status` values that mean the response was SERVED from Cloudflare's cache.
    # `REVALIDATED`/`UPDATING`/`STALE` are all cache-served variants (the edge answered from
    # its store, revalidating or serving stale in the background), so they read as `hit`.
    CF_HIT  = {"hit", "revalidated", "updating", "stale"}
    CF_MISS = {"miss", "expired"}
    # `DYNAMIC` = not eligible for caching; `BYPASS` = a rule told the edge not to cache;
    # `NONE` = no caching applied. All three say "this will not be cached".
    CF_DYNAMIC = {"dynamic", "bypass", "none"}

    CACHE_HEADERS = %w[
      Age X-Cache X-Cache-Status CF-Cache-Status X-Cache-Hits X-Varnish Cache-Status
      X-Vercel-Cache X-Proxy-Cache Akamai-Cache-Status CDN-Cache Server-Timing
      Cache-Control Surrogate-Control CDN-Cache-Control
    ]

    private class Signals
      def initialize
        @hit = false
        @miss = false
        @dynamic = false
        @cache_control_no_store = false
        @cache_control_private = false
        @shared_max_age = false
        @closest_cache_status = nil.as(Signal?)
      end

      def observe(header : Proxy::Codec::Header) : Nil
        value = header.value
        name = header.name.downcase
        case name
        when "cache-status"
          @closest_cache_status = cache_status_signal(value) || @closest_cache_status
        when "age", "x-cache-hits"
          observe_counts(name, value)
        when "x-varnish"
          ids = value.split
          @hit = true if ids.size == 2 && ids.all?(&.to_i64?)
        when "cf-cache-status"
          observe_cf_status(value)
        when "cache-control"
          no_store, private_directive = cache_control_directives(value)
          @cache_control_no_store ||= no_store
          @cache_control_private ||= private_directive
        when "surrogate-control", "cdn-cache-control"
          @shared_max_age ||= shared_cache_max_age?(value)
        when "server-timing"
          observe_signal(server_timing_signal(value))
        when "x-cache", "x-cache-status", "x-vercel-cache", "x-proxy-cache",
             "akamai-cache-status", "cdn-cache"
          observe_signal(vendor_signal(value))
        end
      end

      def result : Signal
        if signal = @closest_cache_status
          return signal
        end
        return Signal::Hit if @hit
        return Signal::Miss if @miss
        return Signal::Dynamic if @dynamic || @cache_control_private ||
                                  (@cache_control_no_store && !@shared_max_age)
        Signal::None
      end

      def cache_status : Signal?
        @closest_cache_status
      end

      def hit? : Bool
        @hit
      end

      private def observe_counts(name : String, value : String) : Nil
        value.split(',').each do |part|
          if number = part.strip.to_i64?
            @hit = true if number > 0
            @miss = true if name == "x-cache-hits" && number == 0
          end
        end
      end

      private def observe_cf_status(value : String) : Nil
        token = value.strip.downcase
        @hit = true if CF_HIT.includes?(token)
        @miss = true if CF_MISS.includes?(token)
        @dynamic = true if CF_DYNAMIC.includes?(token)
      end

      private def observe_signal(signal : Signal?) : Nil
        return unless signal
        @hit = true if signal.hit?
        @miss = true if signal.miss?
        @dynamic = true if signal.dynamic?
      end

      private def vendor_signal(value : String) : Signal?
        d = value.downcase
        hit = d.includes?("hit") || d.includes?("stale") || d.includes?("updating") || d.includes?("revalidated")
        miss = d.includes?("miss") || d.includes?("expired")
        dynamic = d.includes?("bypass") || d == "dynamic" || d == "pass" || d == "none"
        return Signal::Hit if hit
        return Signal::Miss if miss
        return Signal::Dynamic if dynamic
        nil
      end

      private def server_timing_signal(value : String) : Signal?
        split_outside_quotes(value, ',').each do |metric|
          params = split_outside_quotes(metric, ';')
          next unless params.first?.try(&.downcase.includes?("cache"))
          params.each do |param|
            eq = param.index('=') || next
            next unless param[0...eq].strip.downcase == "desc"
            return vendor_signal(unquote(param[(eq + 1)..].strip))
          end
        end
        nil
      end

      private def cache_status_signal(value : String) : Signal?
        member = split_outside_quotes(value, ',').last? || return nil
        hit = false
        fwd = nil.as(String?)
        split_outside_quotes(member, ';').each do |param|
          eq = param.index('=')
          name = eq ? param[0...eq].strip.downcase : param.strip.downcase
          case name
          when "hit"
            hit = true if eq.nil? || param[(eq + 1)..].strip == "?1"
          when "fwd"
            fwd = unquote(param[(eq + 1)..].strip).downcase if eq
          end
        end
        return Signal::Hit if hit
        if reason = fwd
          return Signal::Dynamic if reason == "bypass"
          return Signal::Miss
        end
        nil
      end

      private def split_outside_quotes(value : String, delimiter : Char) : Array(String)
        bytes = value.to_slice
        parts = [] of String
        start = 0
        quoted = false
        escaped = false
        bytes.size.times do |i|
          byte = bytes.unsafe_fetch(i)
          if quoted && escaped
            escaped = false
          elsif quoted && byte == 0x5C_u8 # backslash
            escaped = true
          elsif byte == 0x22_u8 # quote
            quoted = !quoted
          elsif !quoted && byte == delimiter.ord.to_u8
            parts << String.new(bytes[start, i - start]).strip
            start = i + 1
          end
        end
        parts << String.new(bytes[start, bytes.size - start]).strip
        parts
      end

      private def unquote(value : String) : String
        value.size >= 2 && value.starts_with?('"') && value.ends_with?('"') ? value[1...-1] : value
      end

      private def cache_control_directives(value : String) : {Bool, Bool}
        no_store = false
        private_directive = false
        value.split(',').each do |directive|
          eq = directive.index('=')
          name = eq ? directive[0...eq].strip.downcase : directive.strip.downcase
          no_store ||= name == "no-store"
          private_directive ||= name == "private" && eq.nil?
        end
        {no_store, private_directive}
      end

      private def shared_cache_max_age?(value : String) : Bool
        value.split(',').any? do |directive|
          eq = directive.index('=') || next false
          next false unless directive[0...eq].strip.downcase == "max-age"
          raw = unquote(directive[(eq + 1)..].strip)
          (age = raw.to_i64?) && age >= 0
        end
      end
    end

    # Classify a raw response head. An empty/nil head — a Pending flow, a send that never got
    # a response — is `None`: there are no headers to read, which is the same answer as a
    # response that simply carried none. This scans only field names in CACHE_HEADERS, allocates
    # values only for those fields, and stops at the empty line. `bench/cache_status_bench.cr`
    # compares it with materializing every response header through the full HTTP/1 parser.
    def self.classify(head : Bytes?) : Signal
      return Signal::None if head.nil? || head.empty?
      first_crlf = crlf_at(head, 0)
      return Signal::None unless first_crlf

      classify_header_lines(head, first_crlf + 2)
    end

    private def self.classify_header_lines(head : Bytes, pos : Int32) : Signal
      signals = Signals.new
      tail_scanned = false
      last_cache_status = nil.as(Int32?)
      while pos < head.size
        line_end = crlf_at(head, pos)
        stop = line_end || head.size
        break if stop == pos
        observe_cache_header(signals, head, pos, stop)
        tail_scanned, last_cache_status, signal = early_result(signals, head, pos, line_end,
          tail_scanned, last_cache_status)
        if signal
          return signal
        end
        break unless line_end
        pos = line_end + 2
      end
      signals.result
    end

    private def self.early_result(signals : Signals, head : Bytes, pos : Int32, line_end : Int32?,
                                  tail_scanned : Bool, last_cache_status : Int32?) : {Bool, Int32?, Signal?}
      if !tail_scanned && (signals.hit? || !signals.cache_status.nil?)
        tail_scanned = true
        after_line = line_end ? line_end + 2 : head.size
        last_cache_status = last_cache_status_after(head, after_line)
        return {tail_scanned, last_cache_status, signals.result} unless last_cache_status
      end
      if last_cache_status && pos >= last_cache_status && (signals.hit? || !signals.cache_status.nil?)
        return {tail_scanned, last_cache_status, signals.result}
      end
      {tail_scanned, last_cache_status, nil}
    end

    private def self.observe_cache_header(signals : Signals, head : Bytes, from : Int32,
                                          to : Int32) : Nil
      colon = byte_index(head, 0x3A_u8, from, to)
      return unless colon && cache_header_name?(head, from, colon)
      name = String.new(head[from, colon - from])
      value = String.new(head[colon + 1, to - colon - 1]).strip
      signals.observe(Proxy::Codec::Header.new(name, value))
    end

    # Classify a parsed header list — the shared core, so a caller that already has the parse
    # (the detail view) does not re-parse.
    def self.classify(headers : Proxy::Codec::HeaderList) : Signal
      signals = Signals.new
      headers.each do |header|
        signals.observe(header)
      end
      signals.result
    end

    private def self.cache_header_name?(bytes : Bytes, from : Int32, to : Int32) : Bool
      CACHE_HEADERS.any? { |name| name_equals?(bytes, from, to, name) }
    end

    # Once a positive signal or a Cache-Status verdict is found, only a later Cache-Status
    # member can change the answer. Scan the tail for that field name alone once before returning.
    private def self.last_cache_status_after(bytes : Bytes, from : Int32) : Int32?
      pos = from
      last = nil.as(Int32?)
      while pos < bytes.size
        line_end = crlf_at(bytes, pos)
        stop = line_end || bytes.size
        break if stop == pos
        colon = byte_index(bytes, 0x3A_u8, pos, stop)
        last = pos if colon && name_equals?(bytes, pos, colon, "Cache-Status")
        break unless line_end
        pos = line_end + 2
      end
      last
    end

    private def self.name_equals?(bytes : Bytes, from : Int32, to : Int32, name : String) : Bool
      return false unless to - from == name.bytesize
      needle = name.to_slice
      name.bytesize.times.all? do |i|
        ascii_lower(bytes.unsafe_fetch(from + i)) == ascii_lower(needle.unsafe_fetch(i))
      end
    end

    private def self.crlf_at(bytes : Bytes, from : Int32) : Int32?
      i = from
      while i < bytes.size - 1
        return i if bytes.unsafe_fetch(i) == 0x0D_u8 && bytes.unsafe_fetch(i + 1) == 0x0A_u8
        i += 1
      end
      nil
    end

    private def self.byte_index(bytes : Bytes, needle : UInt8, from : Int32, limit : Int32) : Int32?
      i = from
      while i < limit
        return i if bytes.unsafe_fetch(i) == needle
        i += 1
      end
      nil
    end

    private def self.ascii_lower(byte : UInt8) : UInt8
      byte >= 0x41_u8 && byte <= 0x5A_u8 ? byte + 0x20_u8 : byte
    end
  end
end
