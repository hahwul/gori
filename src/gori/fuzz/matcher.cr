require "../proxy/codec/content_decode"
require "../proxy/h2/grpc"
require "../intercept_filter"
require "../repeater/engine"
require "../ascii_bytes"

module Gori::Fuzz
  # gRPC facts a fuzz run needs off raw wire bytes: the CALL's outcome (which for gRPC is
  # never the h2 `:status` — that is 200 by definition — but the `grpc-status` /
  # `grpc-message` trailers the Assembler merges into the response head), and whether an
  # OUTGOING request's body still frames as gRPC after a payload was spliced into it.
  #
  # Both answers already existed one surface away — `run show --format json`, MCP `get_flow`,
  # the Repeater head and the TUI transcript all read them off a STORED flow through
  # `Proxy::H2::Grpc` — and the fuzz result row was the one place they were thrown away. So
  # this is a projection over the same `Grpc` primitives, not a second parser: a sweep against
  # an origin that answers `grpc-status: 7 PERMISSION_DENIED` to every call used to be
  # byte-identical to one against an origin that allowed them all.
  module GrpcVerdict
    # Lowercase needles for the allocation-free pre-checks. `String.new(head)` is only paid
    # by a response that really carries a gRPC status, so a non-gRPC sweep costs one byte
    # scan per response and nothing else.
    STATUS_NEEDLE = "grpc-status".to_slice

    # `{grpc-status, grpc-message}` off a response head, or `{nil, nil}` when it carries no
    # gRPC status at all (an ordinary HTTP response, or a gRPC one whose origin sent no
    # trailer — the TUI calls that last case out as `⚠ no grpc-status trailer`).
    #
    # LAST value wins, matching `Codec::Message#get?`'s `reverse_each`: the trailers are
    # merged in after the initial HEADERS block, and the gRPC rule is that the trailer is the
    # call's real status — an origin that "promotes" a `grpc-status: 0` into the head must not
    # be able to hide the 7 it actually sent.
    def self.response(head : Bytes?) : {Int32?, String?}
      return {nil, nil} unless head && AsciiBytes.contains_ci?(head, STATUS_NEEDLE)
      code = nil.as(Int32?)
      msg = nil.as(String?)
      # scrub: a head is wire bytes and a hostile `grpc-message` is not guaranteed to be
      # valid UTF-8 — best-effort parsing, never a raise on the result path.
      String.new(head).scrub.each_line do |raw|
        line = raw.rstrip
        next unless idx = line.index(':')
        value = line[(idx + 1)..].strip
        case line[0, idx].strip.downcase
        when "grpc-status"  then code = value.to_i?
        when "grpc-message" then msg = value.presence
        end
      end
      {code, msg}
    end

    # Does this REQUEST declare a gRPC content-type? Read once per run off the template's
    # baseline rendering, never per request.
    def self.grpc_request?(request : Bytes) : Bool
      Proxy::H2::Grpc.grpc?(header(request, "content-type"))
    end

    # The declared content-type STRING, for a caller that needs more than the two predicates
    # around it. `Fuzz::GrpcFieldTemplate` has three refusals to tell apart — not gRPC at all,
    # gRPC but grpc-web-TEXT, gRPC but already mis-framed — and they carry different remedies,
    # so answering them from one boolean would name the wrong fix. Read once per plan, like
    # everything else here.
    def self.content_type(request : Bytes) : String?
      header(request, "content-type")
    end

    # Tail bytes of the request body that are NOT a complete gRPC frame — `Grpc.scan`'s
    # residual, i.e. "a length prefix claiming more than arrived". 0 for a body that frames
    # cleanly and for a request with no body at all.
    def self.residual(request : Bytes) : Int32
      body = body(request)
      return 0 unless body && !body.empty?
      # `scan_body`: grpc-web-text carries its frames base64-encoded, so scanning the raw
      # bytes reports a residual for a perfectly well-framed request — which made
      # `framed_template?` false and turned the whole gRPC verdict OFF for every grpc-web-text
      # sweep, silently.
      Proxy::H2::Grpc.scan_body(header(request, "content-type"), body)[1]
    end

    # A template whose gRPC framing a payload can INVALIDATE: it declares a gRPC
    # content-type and its seed body frames cleanly. A seed that was already mis-framed is
    # the operator's own deliberate parser test (see `Grpc.scan`'s comment), so a run over it
    # has nothing to report.
    def self.framed_template?(request : Bytes) : Bool
      grpc_request?(request) && residual(request) == 0
    end

    # A template this run may RE-length-prefix under `reframe_grpc`: `framed_template?` (a
    # gRPC content-type over a seed body that frames CLEANLY) minus grpc-web-TEXT, whose
    # frames are base64 on the wire — see `Grpc.reframe_body`.
    #
    # The clean-seed half is not a leftover of the warning's logic, it is the same argument in
    # the other direction: a seed that was ALREADY mis-framed is the operator's own parser
    # test, so "recompute the prefix after a payload changes the message" has nothing to
    # recompute there and would only DESTROY the test. Read ONCE per run — see
    # `Generator#initialize`.
    def self.reframable_template?(request : Bytes) : Bool
      framed_template?(request) && !Proxy::H2::Grpc.web_text?(header(request, "content-type"))
    end

    # A rendered request with its gRPC length prefix recomputed over the body it actually
    # carries, or the request UNCHANGED when there is nothing unambiguous to do (see
    # `Grpc.reframe`). Only ever called on a run whose template `reframable_template?`
    # accepted, so the content-type re-read is the only per-request head scan it adds.
    #
    # SIZE-PRESERVING, which is why `Generator#emit` can run it after `ContentLength.sync_at`
    # without moving a single payload span and without invalidating the Content-Length that
    # pass just wrote.
    def self.reframe(request : Bytes) : Bytes
      body = body(request)
      return request unless body && !body.empty?
      framed = Proxy::H2::Grpc.reframe_body(header(request, "content-type"), body)
      return request unless framed
      reframed = request.dup
      framed.copy_to(reframed[request.size - body.size, body.size])
      reframed
    end

    # The body slice of a raw request, or nil when there is no head/body boundary. Same
    # LFLF-or-CRLFCRLF rule as `Fuzz::ContentLength.boundary` — a bare-LF head is a desync
    # primitive the fuzzer deliberately crafts, and it still has a body.
    def self.body(request : Bytes) : Bytes?
      sep, width = boundary(request)
      return nil unless sep
      start = sep + width
      start >= request.size ? Bytes.empty : request[start, request.size - start]
    end

    # First value of a header field in the request head, or nil. Only ever called once per
    # run, so it takes the simple String path rather than a byte scan.
    private def self.header(request : Bytes, name : String) : String?
      sep, _ = boundary(request)
      head = sep ? request[0, sep] : request
      String.new(head).scrub.each_line do |raw|
        line = raw.rstrip
        next unless idx = line.index(':')
        return line[(idx + 1)..].strip if line[0, idx].strip.downcase == name
      end
      nil
    end

    private def self.boundary(bytes : Bytes) : {Int32?, Int32}
      i = 0
      while i + 1 < bytes.size
        return {i, 2} if bytes[i] == 0x0a_u8 && bytes[i + 1] == 0x0a_u8
        if i + 3 < bytes.size && bytes[i] == 0x0d_u8 && bytes[i + 1] == 0x0a_u8 &&
           bytes[i + 2] == 0x0d_u8 && bytes[i + 3] == 0x0a_u8
          return {i, 4}
        end
        i += 1
      end
      {nil, 0}
    end
  end

  # Decoded-response metrics for one send.
  record Metrics,
    status : Int32?,
    length : Int64,
    words : Int32,
    lines : Int32,
    duration_us : Int64

  # One auto-calibration sample: the metrics of a synthetic (nonce-payloaded) baseline
  # response, tagged with how much payload text was injected across every marked
  # position for THAT sample. `payload_len` is what lets Matcher.reflects_length?
  # tell "this target's response length legitimately tracks payload length" (reflection)
  # apart from "this target's response length is just noisy" (needs a wider sample set).
  record BaselineSample, metrics : Metrics, payload_len : Int32

  # Decides whether a response is "interesting" and extracts a value from it.
  # ffuf/Burp semantics: a result is MATCHED when every active matcher dimension
  # passes AND no filter dimension passes. Each dimension is a comma-list spec
  # supporting exact (`200`), range (`200-299`), comparator (`>=400`), and — for
  # status — class (`2xx`). Metrics are computed over the DECODED body (gzip/br/…),
  # falling back to the raw body when a codec isn't built in.
  class Matcher
    # Each match/filter spec string is set ONCE (CLI run.cr / TUI fuzzer_view.cr / MCP
    # tools.cr) and then evaluated on EVERY response. Keep the raw string (the TUI reads it
    # back verbatim for the config screen + JSON persist) but precompile it into a parsed
    # term list, so the per-response hot path does zero split/strip/to_i64 work and allocates
    # nothing. Recompiled on assignment, so a mid-run TUI re-apply stays correct. A blank ("")
    # or nil spec compiles to nil ⇒ treated as absent (the `default` is returned), exactly as
    # the old `spec.nil? || spec.blank?` guard — so a match dimension stays "unconstrained"
    # rather than flipping to "reject everything".
    macro num_spec(name)
      getter {{ name.id }} : String?
      @{{ name.id }}_c : Array(NumTerm)?

      def {{ name.id }}=(v : String?)
        @{{ name.id }} = v
        @{{ name.id }}_c = (v && !v.blank?) ? Predicate.compile_num(v) : nil
      end
    end

    macro status_spec(name)
      getter {{ name.id }} : String?
      @{{ name.id }}_c : Array(StatusTerm)?

      def {{ name.id }}=(v : String?)
        @{{ name.id }} = v
        @{{ name.id }}_c = (v && !v.blank?) ? Predicate.compile_status(v) : nil
      end
    end

    status_spec match_status
    status_spec filter_status
    # gRPC call status (`grpc-status`), the dimension the h2 `:status` cannot express: for a
    # gRPC target EVERY response is 200, so `--mc`/`--fc` — and every downstream reading of
    # `status` — cannot separate a granted call from `7 PERMISSION_DENIED`. Compiled as a
    # NUMERIC spec rather than a status one (`2xx` classes are meaningless for a gRPC code,
    # while `7`, `>0` and `1-16` are exactly the useful forms). Absent = unconstrained, so a
    # non-gRPC run is unaffected.
    num_spec match_grpc
    num_spec filter_grpc
    num_spec match_size
    num_spec filter_size
    num_spec match_words
    num_spec filter_words
    num_spec match_lines
    num_spec filter_lines
    # Round-trip time in MILLISECONDS, the dimension every other one here is blind to: a
    # time-based blind injection (`' OR SLEEP(5)--`, `; ping -c 10 127.0.0.1`, a `pg_sleep`)
    # answers with the SAME status, the same byte length, the same words and the same body as
    # the payload that did nothing. The only thing it changes is how long the origin took, and
    # `Metrics`/`Result` have carried `duration_us` since the Fuzzer landed while no surface
    # could name it — so the one payload class whose whole signal is timing was the one class
    # a run could not express.
    #
    # MILLISECONDS rather than the stored microseconds because that is the unit the operator
    # thinks and types in (`--mt '>=5000'` for a 5-second sleep, the same unit MCP's
    # `timeout_ms` already uses); microseconds would make every useful threshold a
    # seven-digit number. Compiled as a NUMERIC spec, so ranges (`4500-6000`) and comparators
    # (`>=5000`) both work — the two shapes a timing threshold actually wants.
    #
    # A timing dimension is noisy by nature (a shared origin, a slow hop, one unlucky GC
    # pause), so it is a matcher, not a verdict: `--mt` narrows a sweep to the rows worth
    # re-sending by hand, exactly as `--ms` does. Nothing here calls a slow response a finding.
    num_spec match_time
    num_spec filter_time

    property match_regex : Regex?
    property filter_regex : Regex?

    # Substring over the response head. Cache the lowercased needle ONCE on assignment
    # (like the num_spec/status_spec setters) so the per-response check neither re-lowercases
    # the needle nor materializes a downcased head String — it byte-scans the raw head.
    #
    # ONE macro for the two, and `filter_header` exists at all because a HEADER dimension with
    # only a matcher half was the odd one out: every other dimension here (status, grpc, size,
    # words, lines, regex) carries both, `fuzz_conditions` on MCP feeds `match` and `filter`
    # off the SAME parsed shape, and a `filter: {header: …}` that quietly did nothing is the
    # silent-ignore this file spends its comments avoiding. The response head is also where
    # the noise lives on a real sweep — a `Set-Cookie` on every WAF challenge, an
    # `X-Cache: HIT` — so filtering on it is the more useful half of the pair, not the
    # decorative one.
    macro header_spec(name)
      getter {{ name.id }} : String?
      @{{ name.id }}_lc : Bytes?

      def {{ name.id }}=(v : String?)
        @{{ name.id }} = v
        @{{ name.id }}_lc = (v && !v.empty?) ? v.downcase.to_slice : nil
      end
    end

    header_spec match_header
    header_spec filter_header

    property extract : Regex?
    # The active calibration set (see Engine#calibrate_baseline). Empty = "no
    # calibration collected" (auto-calibration off, or the calibration sends all
    # failed) — calibrated_out? treats that identically to auto_calibrate being off.
    getter baseline : Array(BaselineSample)
    # Cached alongside `baseline` (recomputed only when the set changes, never on the
    # per-response hot path) — see Matcher.reflects_length? for what it detects.
    getter? reflects_length : Bool = false
    # Half-widths of the baseline bands, recomputed with `baseline` and never on the
    # per-response path — see `Matcher.tolerance`. All 0 until a calibration set is assigned,
    # which is what makes an uncalibrated matcher's arithmetic identical to plain equality.
    getter len_tol : Int64 = 0_i64
    getter word_tol : Int64 = 0_i64
    getter line_tol : Int64 = 0_i64
    property? auto_calibrate : Bool
    property keep_bodies : Symbol # :none | :matched | :all

    # The template is a gRPC request whose SEED body frames cleanly (set once by
    # `Fuzz::Plan.build` — see `GrpcVerdict.framed_template?`). While it is on, every rendered
    # request is re-scanned and the ones a payload left MIS-framed are counted below.
    #
    # gori does not touch the bytes either way (P7: the operator's payload goes out verbatim),
    # but it resyncs `Content-Length` by default and says so loudly, while the gRPC 5-byte
    # length prefix — the same kind of declaration — got neither the resync nor a word: a
    # sweep whose payloads change the message length puts a prefix claiming the OLD length on
    # the wire, a real gRPC server rejects it, and gori reported `3 sent · 0 errors`. So the
    # verdict is computed and named ONCE per run instead of changing what leaves the machine.
    property? grpc_template : Bool = false
    # Rendered requests scanned (the denominator of the notice) and how many of them left the
    # length prefix stale, plus the first `Grpc.framing_error` sentence. Zero on every
    # non-gRPC run, so no surface grows a line it did not have.
    getter grpc_requests : Int64 = 0_i64
    getter grpc_stale : Int64 = 0_i64
    getter grpc_stale_reason : String? = nil

    def initialize(@keep_bodies : Symbol = :matched, @auto_calibrate : Bool = false)
      @baseline = [] of BaselineSample
    end

    def baseline=(samples : Array(BaselineSample)) : Nil
      @baseline = samples
      @reflects_length = Matcher.reflects_length?(samples)
      @len_tol = Matcher.tolerance(samples.map(&.metrics.length), LEN_JITTER_FLOOR)
      @word_tol = Matcher.tolerance(samples.map(&.metrics.words.to_i64), COUNT_JITTER_FLOOR)
      @line_tol = Matcher.tolerance(samples.map(&.metrics.lines.to_i64), COUNT_JITTER_FLOOR)
    end

    # A generous per-pair slack (bytes) for the length-tracks-payload check below — covers
    # HTML-entity re-encoding of a few nonce characters, off-by-one wrapper text, etc.
    # without being wide enough to misclassify genuinely-noisy (non-reflecting) targets.
    LENGTH_TOLERANCE = 4_i64

    # ── the baseline's own jitter ────────────────────────────────────────────
    #
    # `baseline_matches?` used to compare EXACTLY (`length == b.length && words == b.words`),
    # which answers the discrete case perfectly and the continuous one not at all. A target
    # that embeds anything per-response — a request id, a rendering time, a CSRF token, a
    # cache-age — has no finite set of shapes for six samples to enumerate, so every sampled
    # length was a length no sweep response would ever hit again, `--ac` suppressed NOTHING,
    # and the operator got a page of false positives from the flag whose whole job is to
    # remove them. (The rotating-banner case the multi-sample baseline fixed is the OTHER
    # failure; both are real and they want different answers.)
    #
    # So a sample is now a small BAND rather than a point, and the band's width is the
    # variability the target ITSELF demonstrated across the calibration samples — never a
    # constant this file invented. Two properties follow, and they are the reason it is safe:
    #
    #   * A target whose samples were byte-identical gets width 0, i.e. exact equality —
    #     bit-for-bit the old behaviour, on every stable target there is.
    #   * A target that jittered by N bytes gets width ≤ N. gori can only ever suppress a
    #     response the target's own noise could have produced.
    #
    # Two statistics, and BOTH are deliberately robust to one odd sample, because a
    # calibration set of six against a live target reliably contains one: a cached error page,
    # an A/B variant, a debug dump.
    #
    #   * the width is the LARGEST GAP between consecutive sorted samples, not the full
    #     min-to-max spread. Since a response is compared against EVERY sample, the bands only
    #     have to bridge the gaps BETWEEN them for their union to cover the target's noise —
    #     and the full spread is a wildly wrong number when the samples are multi-modal.
    #   * the cap's scale is the sample in the MIDDLE, not the largest. `2% of the biggest
    #     sample` reads a single 200 KB outlier among five 5 KB pages as licence for a 4 KB
    #     band around every one of them, which is precisely the over-suppression this whole
    #     mechanism must not do.
    #
    # The cap is there because "observed spread" is the right measure of jitter and the wrong
    # measure of ROTATION: samples of 100 and 250 bytes are 150 apart, and widening each band
    # by 150 merges two distinct shapes into one blanket that swallows every anomaly between
    # them. Jitter is small and absolute (a nonce, a timestamp, a few bytes); a rotation is
    # large and structural. STATUS is compared exactly at every width, so no tolerance here can
    # calibrate away a seeded 500.
    JITTER_CAP_DIVISOR = 50_i64 # 2% of the middle sample
    LEN_JITTER_FLOOR   = 16_i64 # bytes — a request id / timestamp / token is smaller than this
    COUNT_JITTER_FLOOR =  2_i64 # words and lines: a reflected nonce moves these by ~1

    # The half-width of a baseline band for one metric, from that metric's values across the
    # calibration samples. 0 (exact match) for a single sample and for a metric that did not
    # move — see the block above for the two statistics and why each is the robust one.
    def self.tolerance(values : Array(Int64), floor : Int64) : Int64
      return 0_i64 if values.size < 2
      sorted = values.sort
      gap = 0_i64
      sorted.each_cons_pair { |a, b| gap = b - a if b - a > gap }
      return 0_i64 if gap <= 0
      # Lower-middle rather than a mean of the two middles: it is a sample the target actually
      # produced, and it needs no tie-breaking rule on an even count.
      middle = sorted[(sorted.size - 1) // 2]
      Math.min(gap, Math.max(floor, middle // JITTER_CAP_DIVISOR))
    end

    # Detects a target that reflects the substituted payload back into its response body:
    # the calibration samples deliberately inject STAGGERED payload lengths (see
    # Generator#calibration_requests), so if response byte length grows in lockstep with
    # payload length across every pair of samples, comparing raw length can never repeat —
    # every distinct real attack payload has its own length, so no finite baseline set
    # would ever exact-match it (the second proven-broken scenario: 100/100 false
    # positives with a single-sample baseline). `baseline_matches?` then substitutes
    # word/line counts for length.
    #
    # Conservative by design: EVERY pair with a different payload length must show the
    # tracking relationship, or this returns false and length stays in the (safe, if
    # sometimes less effective) exact-match comparison — a target that just happens to be
    # noisy must never be misread as "reflecting".
    #
    # What this does NOT catch: partial reflection (the target truncates, HTML-escapes, or
    # otherwise transforms the payload before embedding it, so growth isn't ~1:1) reads as
    # "not reflecting" and falls through to stricter exact-length matching — under-
    # suppressing rather than over-suppressing, the safe failure direction for a security
    # tool. A target whose word/line count ALSO happens to shift with an opaque nonce
    # (e.g. it reflects the payload on its own line, adding a line each time) likewise
    # isn't calibrated out — again a missed suppression, never a missed finding.
    def self.reflects_length?(samples : Array(BaselineSample)) : Bool
      pairs = 0
      tracked = 0
      samples.each_with_index do |a, i|
        samples.each_with_index do |b, j|
          next unless j > i
          dp = (b.payload_len - a.payload_len).to_i64
          next if dp == 0
          dl = b.metrics.length - a.metrics.length
          pairs += 1
          tracked += 1 if (dl - dp).abs <= LENGTH_TOLERANCE
        end
      end
      pairs > 0 && tracked == pairs
    end

    # Build the metrics for a raw send WITHOUT deciding match (used to seed the
    # baseline from the unmodified request).
    def metrics(raw : Repeater::Result) : Metrics
      body = decode(raw)
      words, lines = count_metrics(body)
      Metrics.new(raw.response.try(&.status), body.size.to_i64, words, lines, raw.duration_us)
    end

    # `resent_count` is the number of CONFIG-retry re-sends `Engine#run_one` made after a
    # network error (0 unless `--retries` fired); it is passed in because the retry loop lives
    # in the engine, not here — this is the one build site for every Fuzz::Result, so the count
    # has to arrive as an argument. `timed_out` rides straight off the Repeater result, the twin
    # of the already-carried `incomplete?`: the engine observed both and, until now, dropped one.
    def build(job : Job, raw : Repeater::Result, resent_count : Int32 = 0) : Result
      # The OUTGOING request, before anything is said about the response: a payload that
      # changed the gRPC message length leaves the 5-byte prefix declaring the old one.
      note_grpc_framing(job.bytes) if @grpc_template
      body = decode(raw)
      status = raw.response.try(&.status)
      # The call's real outcome for a gRPC target — `status` is 200 for every gRPC response
      # there is. Nil (and free) for any other response: see `GrpcVerdict.response`.
      grpc_status, grpc_message = GrpcVerdict.response(raw.head)
      length = body.size.to_i64
      words, lines = count_metrics(body)

      need_text = !@match_regex.nil? || !@filter_regex.nil? || !@extract.nil?
      text = need_text ? String.new(body).scrub : ""
      extracted = extract_value(text)
      matched = decide(raw, status, grpc_status, length, words, lines, elapsed_ms(raw), text)
      keep = keep?(matched)

      Result.new(
        index: job.index, payloads: job.payloads, position: job.position,
        status: status, length: length, words: words, lines: lines,
        duration_us: raw.duration_us, error: raw.error, matched: matched,
        incomplete: raw.incomplete?, extracted: extracted,
        head: keep ? present(raw.head) : nil, body: keep ? raw.body : nil,
        request: keep ? present(job.bytes) : nil, retried: raw.retried?,
        wire: keep ? raw.wire.try { |w| present(w) } : nil,
        chain_error: job.chain_error,
        grpc_status: grpc_status, grpc_message: grpc_message,
        timed_out: raw.timed_out?, resent_count: resent_count)
    end

    # Count a rendered request whose gRPC framing a payload broke. Only reached while
    # `grpc_template?` is set, so it costs a non-gRPC run nothing. Never rewrites and never
    # refuses — the bytes are the operator's test case; the run merely gets to say so once.
    private def note_grpc_framing(request : Bytes) : Nil
      @grpc_requests += 1
      residual = GrpcVerdict.residual(request)
      return unless residual > 0
      @grpc_stale += 1
      @grpc_stale_reason ||= Proxy::H2::Grpc.framing_error(residual)
    end

    # The round-trip in MILLISECONDS, the unit `--mt`/`--ft` are written in. Truncating
    # division: a spec is a threshold ("slower than 5s"), and rounding 4999.6µs up to 5ms
    # would put a sub-millisecond response on the wrong side of `>=5`.
    private def elapsed_ms(raw : Repeater::Result) : Int64
      raw.duration_us // 1000
    end

    private def decide(raw : Repeater::Result, status : Int32?, grpc_status : Int32?,
                       length : Int64, words : Int32, lines : Int32, elapsed_ms : Int64,
                       text : String) : Bool
      return false unless eligible?(raw)
      return false if calibrated_out?(status, length, words, lines)
      matchers_pass?(raw, status, grpc_status, length, words, lines, elapsed_ms, text) &&
        !filtered?(raw, status, grpc_status, length, words, lines, elapsed_ms, text)
    end

    # A failed send has nothing to match on — no status, no body, no header — so it is not a
    # result, and every dimension but one is being asked about bytes that never arrived.
    #
    # The one is TIME. A payload that pushes the origin past the run's own timeout is the
    # loudest possible time-based signal, and it arrives here as an error with a duration
    # attached: on `--mt '>=5000'` against a 10s timeout, the sleep that WORKED timed out and
    # was discarded, while the sleep that did nothing came back at 40ms and was reported —
    # exactly inverted. So a TIMED-OUT send stays eligible while a match_time spec is set, and
    # nothing else changes: a refused, reset or unreachable send is still not a result, and a
    # run with no `--mt` behaves as it always did.
    #
    # The other dimensions do not need a special case on that path. A timed-out send carries
    # no status and an empty body, so a `--mc`/`--ms`/`--mr` alongside `--mt` fails it on its
    # own terms — "slow AND 200" cannot be satisfied by a response that never came, and it
    # should not be.
    private def eligible?(raw : Repeater::Result) : Bool
      return true if raw.error.nil?
      raw.timed_out? && !@match_time_c.nil?
    end

    # A response is "noise" when it matches ANY collected baseline sample — not just a
    # single exact snapshot. That's what lets a target that legitimately rotates between
    # a handful of response shapes (a rotating banner, an A/B variant, …) get every
    # sampled shape recognized as noise, instead of only whichever one shape a single
    # lucky/unlucky baseline call happened to catch (the original bug: with one sample,
    # 3 of 4 rotating shapes were reported as false-positive hits).
    private def calibrated_out?(status : Int32?, length : Int64, words : Int32, lines : Int32) : Bool
      return false unless @auto_calibrate
      samples = @baseline
      return false if samples.empty?
      samples.any? { |b| baseline_matches?(b.metrics, status, length, words, lines) }
    end

    # Status is always compared exactly — a genuine anomaly that flips status (e.g. a
    # seeded 500) must never calibrate out, regardless of body-size heuristics. When
    # `reflects_length?` is set (see Matcher.reflects_length?), raw byte length is
    # dropped from the comparison since it legitimately varies with EVERY distinct
    # payload (no finite sample set would ever exact-match it); word/line counts are
    # used instead, since an opaque alphanumeric nonce substitution — unlike its byte
    # length — rarely changes how many whitespace-delimited words or lines a page has.
    #
    # Each comparison is against that sample's BAND — the value ± the jitter the calibration
    # set itself showed for that metric (see the `JITTER_CAP_DIVISOR` block). Every band is
    # zero-width on a stable target, so this reduces to the exact `==` it replaced.
    private def baseline_matches?(b : Metrics, status : Int32?, length : Int64,
                                  words : Int32, lines : Int32) : Bool
      return false unless status == b.status
      if reflects_length?
        return near?(words.to_i64, b.words.to_i64, @word_tol) &&
          near?(lines.to_i64, b.lines.to_i64, @line_tol)
      end
      near?(length, b.length, @len_tol) && near?(words.to_i64, b.words.to_i64, @word_tol)
    end

    private def near?(value : Int64, sampled : Int64, tolerance : Int64) : Bool
      (value - sampled).abs <= tolerance
    end

    # Whether a TIMED-OUT send is a result this matcher can report rather than a failure —
    # i.e. whether `--mt` is set (see `eligible?`). The ENGINE reads it: `run_one` retries a
    # failed send before the matcher ever sees it, so on a `--mt '>=4500' --retries 2` run
    # every payload that actually fired the sleep was sent three times and cost three
    # timeouts of wall clock to report the row it had already earned on the first.
    def timeout_matchable? : Bool
      !@match_time_c.nil?
    end

    # True when ANY match/filter dimension is set — the run carries a success/rejection
    # criterion rather than the "everything passes" default. `extract` is deliberately excluded:
    # it grabs a value from each response, it is not a pass/reject predicate. Surfaces read this
    # to decide whether to nudge the operator toward `--mc/--fc` (a race run's `matched` count is
    # only meaningful once a predicate names the success response — see `Engine#matcher_constrained?`).
    def constrained? : Bool
      !(@match_status_c.nil? && @filter_status_c.nil? &&
        @match_grpc_c.nil? && @filter_grpc_c.nil? &&
        @match_size_c.nil? && @filter_size_c.nil? &&
        @match_words_c.nil? && @filter_words_c.nil? &&
        @match_lines_c.nil? && @filter_lines_c.nil? &&
        @match_time_c.nil? && @filter_time_c.nil? &&
        @match_regex.nil? && @filter_regex.nil? &&
        @match_header_lc.nil? && @filter_header_lc.nil?)
    end

    # Every active matcher dimension must pass.
    private def matchers_pass?(raw : Repeater::Result, status : Int32?, grpc_status : Int32?,
                               length : Int64, words : Int32, lines : Int32, elapsed_ms : Int64,
                               text : String) : Bool
      status_pass?(@match_status_c, status, default: true) &&
        grpc_pass?(@match_grpc_c, grpc_status, default: true) &&
        num_pass?(@match_size_c, length, default: true) &&
        num_pass?(@match_words_c, words.to_i64, default: true) &&
        num_pass?(@match_lines_c, lines.to_i64, default: true) &&
        num_pass?(@match_time_c, elapsed_ms, default: true) &&
        # header_pass? (an allocation-free byte scan over the short head) before regex_pass?
        # (a PCRE match over the whole body): both are pure predicates, so `&&` short-circuits
        # identically either way, but this order lets a failing --mh skip the body match.
        header_pass?(@match_header_lc, raw, default: true) &&
        regex_pass?(@match_regex, text, default: true)
    end

    # Any filter dimension that passes removes the result.
    private def filtered?(raw : Repeater::Result, status : Int32?, grpc_status : Int32?,
                          length : Int64, words : Int32, lines : Int32, elapsed_ms : Int64,
                          text : String) : Bool
      status_pass?(@filter_status_c, status, default: false) ||
        grpc_pass?(@filter_grpc_c, grpc_status, default: false) ||
        num_pass?(@filter_size_c, length, default: false) ||
        num_pass?(@filter_words_c, words.to_i64, default: false) ||
        num_pass?(@filter_lines_c, lines.to_i64, default: false) ||
        num_pass?(@filter_time_c, elapsed_ms, default: false) ||
        # Before the body regex, for the reason `matchers_pass?` orders them that way: a byte
        # scan over the short head is cheaper than a PCRE match over the whole body, and `||`
        # short-circuits identically either way.
        header_pass?(@filter_header_lc, raw, default: false) ||
        regex_pass?(@filter_regex, text, default: false)
    end

    private def regex_pass?(re : Regex?, text : String, default : Bool) : Bool
      re ? re.matches?(text) : default
    rescue Regex::Error
      # A catastrophic-backtracking user regex (--mr / --fr) raises "match limit exceeded" on a
      # large response body instead of returning false; treat an un-evaluable pattern as no-match
      # so one runaway regex can't kill the fuzz worker fiber on every response.
      false
    end

    # `default` is what an ABSENT spec answers, exactly as on `status_pass?`/`num_pass?`: a
    # matcher with no needle passes, a filter with no needle never fires.
    private def header_pass?(needle : Bytes?, raw : Repeater::Result, default : Bool) : Bool
      return default unless needle
      # ASCII case-insensitive substring scan over the raw head bytes — no per-response
      # `String.new(raw.head).scrub.downcase` allocation. Header field tokens are ASCII, so
      # this equals the old downcased-substring test for any ASCII/ISO-8859-1 head + needle.
      AsciiBytes.contains_ci?(raw.head, needle)
    end

    # `default` is returned when the spec is absent (compiled == nil, i.e. the raw spec was
    # nil or blank — see the status_spec/num_spec setters): a matcher with no spec passes; a
    # filter with no spec never fires. When a spec IS present but the response has no status,
    # a status dimension can't match (false), mirroring the old behaviour.
    private def status_pass?(compiled : Array(StatusTerm)?, status : Int32?, default : Bool) : Bool
      return default if compiled.nil?
      (s = status) ? compiled.any?(&.matches?(s)) : false
    end

    private def num_pass?(compiled : Array(NumTerm)?, value : Int64, default : Bool) : Bool
      return default if compiled.nil?
      compiled.any?(&.matches?(value))
    end

    # `num_pass?` for the gRPC status, which is ABSENT on every non-gRPC response — so a spec
    # that is present can't match one, exactly as `status_pass?` treats a response with no
    # status. Without a spec the dimension is unconstrained (matcher) / never fires (filter).
    private def grpc_pass?(compiled : Array(NumTerm)?, code : Int32?, default : Bool) : Bool
      return default if compiled.nil?
      (c = code) ? compiled.any?(&.matches?(c.to_i64)) : false
    end

    private def extract_value(text : String) : String?
      re = @extract
      return nil if re.nil? || text.empty?
      md = re.match(text)
      return nil unless md
      md[1]? || md[0]
    rescue Regex::Error
      nil # a runaway --extract regex yields no capture rather than a dead worker (see regex_pass?)
    end

    # Cap the INFLATE at the same ceiling the capture read already enforces. Left at
    # `ContentDecode`'s 32 MiB default this was the one decode site in the active engines
    # with no cap of its own (discover passes `MAX_BODY`, every probe rule passes
    # `BODY_CAP`), so a hostile target answering every request `Content-Encoding: gzip`
    # could inflate an 8 MiB capture toward 32 MiB per in-flight worker — and `--concurrency`
    # goes to `MAX_CONCURRENCY` = 1000, which is tens of GB of transient allocation and an
    # OOM kill no worker-loop rescue can catch. Pinning it to `CAPTURE_READ_MAX` removes the
    # decompression AMPLIFICATION without inventing a truncation policy: the raw body is
    # already bounded there, so no response that fits the capture can have its length,
    # word/line counts or regex text changed by this cap.
    private def decode(raw : Repeater::Result) : Bytes
      decoded, _ = Proxy::Codec::ContentDecode.decode(raw.head, raw.body, Proxy::Codec::Body::CAPTURE_READ_MAX)
      decoded || raw.body || Bytes.empty
    end

    private def keep?(matched : Bool) : Bool
      case @keep_bodies
      when :all     then true
      when :matched then matched
      else               false
      end
    end

    private def present(head : Bytes) : Bytes?
      head.empty? ? nil : head
    end

    # Word count (whitespace transitions) AND line count (0x0a bytes) over the decoded body
    # in ONE allocation-free pass. 0x0a is already a whitespace byte in the word scan, so
    # counting lines inside that same branch is bit-identical to two separate traversals.
    private def count_metrics(body : Bytes) : {Int32, Int32}
      words = 0
      lines = 0
      in_word = false
      body.each do |b|
        if b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
          in_word = false
          lines += 1 if b == 0x0a_u8
        elsif !in_word
          in_word = true
          words += 1
        end
      end
      {words, lines}
    end
  end

  # A precompiled numeric predicate term — parsed once from a comma-spec, evaluated per
  # response with plain integer comparisons. Mirrors the old Predicate.term? decision exactly.
  enum NumKind : UInt8
    Exact
    Range
    Ge
    Le
    Gt
    Lt
    Never # a comparator/bare term whose number failed to parse — never matches (was `false`)
  end

  struct NumTerm
    getter kind : NumKind
    getter a : Int64
    getter b : Int64

    def initialize(@kind : NumKind, @a : Int64 = 0_i64, @b : Int64 = 0_i64)
    end

    def matches?(v : Int64) : Bool
      case kind
      in NumKind::Exact then v == a
      in NumKind::Range then v >= a && v <= b
      in NumKind::Ge    then v >= a
      in NumKind::Le    then v <= a
      in NumKind::Gt    then v > a
      in NumKind::Lt    then v < a
      in NumKind::Never then false
      end
    end
  end

  # A precompiled status term: either an inclusive `lo-hi` range, or a raw term delegated to
  # InterceptFilter.status_match? at eval time (exact / `Nxx` class / comparator forms). The
  # comma-split is done ONCE at compile; eval allocates nothing. Ranges keep Int64 bounds so a
  # range wider than Int32 can't overflow (status is small; the compare promotes to Int64).
  struct StatusTerm
    getter a : Int64
    getter b : Int64
    getter raw : String?

    def initialize(@a : Int64, @b : Int64, @raw : String? = nil)
    end

    def self.range(lo : Int64, hi : Int64) : StatusTerm
      new(lo, hi)
    end

    def self.delegate(term : String) : StatusTerm
      new(0_i64, 0_i64, term)
    end

    def matches?(status : Int32) : Bool
      if r = @raw
        InterceptFilter.status_match?(status, r)
      else
        status >= @a && status <= @b
      end
    end
  end

  # Parses match/filter spec strings into evaluable terms — the single source of truth for spec
  # PARSING. The Matcher compiles each spec ONCE per run (on assignment) and evaluates the parsed
  # NumTerm/StatusTerm arrays per response, so no string is re-parsed or re-split on the hot path.
  module Predicate
    # Parse a comma-spec into evaluable numeric terms ONCE (mirrors the old per-call term?).
    def self.compile_num(spec : String) : Array(NumTerm)
      terms(spec).map { |t| classify_num(t) }
    end

    # Parse a comma-spec into evaluable status terms ONCE: a `lo-hi` range (inclusive) is
    # matched numerically; every other term delegates to InterceptFilter.status_match?, the
    # SAME decision order the old status_any? used (parse_range first, else class/exact match).
    def self.compile_status(spec : String) : Array(StatusTerm)
      terms(spec).map do |t|
        if range = parse_range(t)
          StatusTerm.range(range[0], range[1])
        else
          StatusTerm.delegate(t)
        end
      end
    end

    private def self.classify_num(t : String) : NumTerm
      {">=", "<=", ">", "<", "="}.each do |op|
        if t.starts_with?(op)
          n = t[op.size..].strip.to_i64?
          return NumTerm.new(NumKind::Never) unless n
          kind = case op
                 when ">=" then NumKind::Ge
                 when "<=" then NumKind::Le
                 when ">"  then NumKind::Gt
                 when "<"  then NumKind::Lt
                 else           NumKind::Exact # "="
                 end
          return NumTerm.new(kind, n)
        end
      end
      if range = parse_range(t)
        return NumTerm.new(NumKind::Range, range[0], range[1])
      end
      (n = t.to_i64?) ? NumTerm.new(NumKind::Exact, n) : NumTerm.new(NumKind::Never)
    end

    private def self.terms(spec : String) : Array(String)
      spec.split(',').map(&.strip).reject(&.empty?)
    end

    private def self.parse_range(t : String) : {Int64, Int64}?
      dash = t.index('-', 1) # not a leading minus
      return nil unless dash
      lo = t[0...dash].to_i64?
      hi = t[(dash + 1)..].to_i64?
      (lo && hi) ? {lo, hi} : nil
    end
  end
end
