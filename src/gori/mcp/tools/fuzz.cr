require "json"
require "../../fuzz"
require "../../decoder"
require "../../env"
require "../../flow_mapper"
require "../../proxy/codec/http1"
require "../../repeater/flow_request"
require "../../scope"
require "../serialize"
require "../../store"

module Gori
  module MCP
    class Tools
      # --- fuzz tools (gated, async job model) --------------------------------

      private def fuzz_start(h) : Result
        engine, origin, total, http2 = build_fuzz_job(h)
        # Scope gate before launching any real send (host-level: fuzz sweeps many
        # paths against one origin, so evaluate the origin host).
        sc = scope_check("#{origin.scheme}://#{origin.host}/", origin.host, bool(h, "allow_unscoped") || false)
        return scope_blocked(sc) if sc.blocked
        if total && total > FUZZ_MAX_REQUESTS
          return err("too many requests (#{total} > #{FUZZ_MAX_REQUESTS}); narrow positions/payloads", "BUDGET_EXHAUSTED")
        end
        @job_seq += 1
        id = "fz_#{@job_seq}"
        audit = JobAudit.new("#{origin.scheme}://#{origin.host}:#{origin.port}",
          int(h, "rate").try(&.to_f64), clamp(int(h, "concurrency"), 20, FUZZ_MAX_CONCURRENCY),
          int(h, "max_requests"), Time.utc.to_unix_ms)
        fjob = FuzzJob.new(id, total, engine, fuzz_record_policy(h), origin, http2, audit)
        @jobs[id] = fjob
        warn = budget_warning(total, int(h, "max_requests"))
        # Audit on STDERR — never STDOUT (reserved for JSON-RPC).
        Log.info { "fuzz_start #{id} #{origin.scheme}://#{origin.host}:#{origin.port} scope=#{sc.decision} record=#{fjob.record_history} total=#{total || "?"}" }
        spawn(name: "mcp-fuzz-#{id}") { run_fuzz_job(fjob, engine) }
        Result.new(JSON.build { |j| j.object { j.field "job_id", id; j.field "total", total; j.field "status", "running"; j.field "record_history", fjob.record_history.to_s; j.field("budget_warning", warn) if warn; emit_scope(j, sc) } })
      rescue ex : FuzzArgError
        Result.new(ex.message || "invalid fuzz arguments", is_error: true)
      end

      # Background drain (runs during the stdio loop's blocking read). Stores
      # matched results only, capped, never touches STDOUT. Robustness: a per-event
      # rescue keeps the drain alive on a callback failure (so the engine's worker
      # fibers, parked on @events.send, still finish and exit instead of leaking),
      # and the ensure GUARANTEES a terminal state — a fiber that dies here must
      # never leave the job wedged at :running, which would hang a polling client
      # forever and keep jobs_running? true (blocking switch_project/delete_project).
      private def run_fuzz_job(fjob : FuzzJob, engine : Fuzz::Engine) : Nil
        engine.run { |ev| drain_fuzz_event(fjob, ev) }
      rescue ex
        Log.error(exception: ex) { "fuzz job #{fjob.id} crashed" }
        fjob.error_msg ||= ex.message || "internal fuzz job error"
      ensure
        finalize_job(fjob)
      end

      # Apply one fuzz event to the job, contained: a callback failure records the
      # error and marks the job but never unwinds out of engine.run (see above).
      private def drain_fuzz_event(fjob : FuzzJob, ev : Fuzz::Event) : Nil
        case ev
        when Fuzz::ProgressEvent then apply_fuzz_progress(fjob, ev.progress)
        when Fuzz::ResultEvent
          flow_id = maybe_record_fuzz_flow(fjob, ev.result)
          store_fuzz_result(fjob, ev.result, flow_id)
        when Fuzz::DoneEvent
          apply_fuzz_progress(fjob, ev.progress)
          fjob.status = terminal_status(fjob.status, ev.stopped, fjob.sent, fjob.total)
          fjob.ended_at_ms = Time.utc.to_unix_ms
        when Fuzz::ErrorEvent
          fjob.status = :error
          fjob.error_msg = ev.message
          fjob.ended_at_ms ||= Time.utc.to_unix_ms
        end
      rescue ex
        Log.error(exception: ex) { "fuzz job #{fjob.id} drain error" }
        fjob.status = :error if fjob.status == :running
        fjob.error_msg ||= ex.message || "internal fuzz drain error"
      end

      # Record a fuzz result's rendered request + response as a History flow when
      # record_history asks (matched → matched results, all → every sent request),
      # returning the new flow id. Bounded by FUZZ_HISTORY_MAX to cap DB growth for
      # `all`. Recording must never break the run — a failure just yields nil.
      private def maybe_record_fuzz_flow(fjob : FuzzJob, r : Fuzz::Result) : Int64?
        return nil if fjob.record_history == :none
        return nil unless fjob.record_history == :all || r.matched?
        req = r.request
        return nil unless req
        if fjob.recorded_flows >= FUZZ_HISTORY_MAX
          fjob.history_truncated = true
          return nil
        end
        fid = record_fuzz_flow(req, fjob.origin, fjob.http2?, r)
        fjob.recorded_flows += 1 if fid
        fid
      end

      # Reconstruct a History flow (request head/body + response head/body) from a
      # fuzz Result. Stored raw; get_flow redacts sensitive headers on read.
      private def record_fuzz_flow(request : Bytes, origin : Fuzz::Origin, http2 : Bool, r : Fuzz::Result) : Int64?
        head, body = split_wire_request(request)
        parsed = Proxy::Codec::Http1.parse_request_head(head)
        fid = store.insert_flow(Store::CapturedRequest.new(
          created_at: Time.utc.to_unix_ms * 1000_i64,
          scheme: origin.scheme, host: origin.host, port: origin.port,
          method: parsed.method, target: parsed.target,
          http_version: http2 ? "HTTP/2" : parsed.version,
          head: head, body: body, body_size: body.try(&.size.to_i64)))
        return nil if fid <= 0
        rhead = r.head
        if rhead && !rhead.empty? && (resp = (Proxy::Codec::Http1.parse_response_head(rhead) rescue nil))
          store.update_response(FlowMapper.response(resp, flow_id: fid, body: r.body,
            duration_us: r.duration_us,
            state: r.error ? Store::FlowState::Error : Store::FlowState::Complete,
            error: r.error, body_size: r.body.try(&.size.to_i64)))
        else
          store.update_response(FlowMapper.error_response(fid, r.error || "no response recorded"))
        end
        fid
      rescue ex
        Log.warn(exception: ex) { "fuzz history record failed" }
        nil
      end

      # Up-front warning when a caller's max_requests can't cover the known
      # candidate total, so the run will end :budget_exhausted rather than :done.
      private def budget_warning(total : Int64?, caller_cap : Int64?) : String?
        return nil unless total && caller_cap && caller_cap > 0 && caller_cap < total
        "max_requests (#{caller_cap}) is below the #{total} candidate total; " \
        "the run will stop at the budget before checking every candidate"
      end

      private def apply_fuzz_progress(fjob : FuzzJob, p : Fuzz::Progress) : Nil
        fjob.sent = p.sent
        fjob.matched = p.matched
        fjob.errors = p.errors
      end

      private def store_fuzz_result(fjob : FuzzJob, r : Fuzz::Result, flow_id : Int64?) : Nil
        return unless r.matched?
        if fjob.results.size < FUZZ_MAX_STORED
          fjob.results << r
          fjob.result_flow_ids << flow_id
        else
          fjob.truncated = true
        end
      end

      private def fuzz_status(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        Result.new(JSON.build do |j|
          j.object do
            j.field "job_id", fjob.id
            j.field "status", fjob.status.to_s
            j.field "total", fjob.total
            j.field "sent", fjob.sent
            j.field "candidates_remaining", (t = fjob.total) ? {0_i64, t - fjob.sent}.max : nil
            j.field "matched", fjob.matched
            j.field "errors", fjob.errors
            j.field "stored_results", fjob.results.size
            j.field "results_truncated", fjob.truncated?
            j.field "record_history", fjob.record_history.to_s
            j.field "recorded_flows", fjob.recorded_flows
            j.field "history_truncated", fjob.history_truncated?
            j.field "job_complete", fjob.status != :running
            j.field "incomplete_reason", incomplete_reason(fjob.status)
            j.field "error", fjob.error_msg
            emit_audit(j, fjob.audit, fjob.ended_at_ms)
          end
        end)
      end

      private def fuzz_results(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        # Stored results are matched-only, so matched_only is a no-op; iterate by
        # index to keep each row aligned with its recorded History flow id.
        rows = fjob.results
        flow_ids = fjob.result_flow_ids
        offset = clamp_nonneg(int(h, "offset"))
        limit = clamp(int(h, "limit"), 100, 1000)
        last = offset < rows.size ? Math.min(offset + limit, rows.size) : offset
        returned = last - offset
        Result.new(JSON.build do |j|
          j.object do
            j.field("results") { j.array { (offset...last).each { |i| Serialize.fuzz_result(j, rows[i], flow_ids[i]?) } } }
            j.field "returned", returned
            j.field "offset", offset
            j.field "total_available", rows.size
            # `job_complete` = the JOB finished. `page_complete` is about THIS page:
            # whether it reached the end of the stored rows.
            j.field "job_complete", fjob.status != :running
            j.field "page_complete", last >= rows.size
            j.field "has_more", last < rows.size
            j.field "incomplete_reason", incomplete_reason(fjob.status)
            j.field "results_truncated", fjob.truncated?
            j.field "history_truncated", fjob.history_truncated?
          end
        end)
      end

      private def fuzz_stop(h) : Result
        fjob = lookup_fuzz_job(h)
        return fjob if fjob.is_a?(Result)
        fjob.stop
        Result.new(JSON.build { |j| j.object { j.field "job_id", fjob.id; j.field "status", "stopping" } })
      end

      # The job for `job_id`, or an error Result the caller returns as-is.
      private def lookup_fuzz_job(h) : FuzzJob | Result
        id = str(h, "job_id")
        return Result.new("missing required 'job_id'", is_error: true) if id.nil? || id.empty?
        @jobs[id]? || not_found("no fuzz job #{id}")
      end

      # Build a ready-to-run engine + its origin + total + effective http2 from the
      # tool args. Raises FuzzArgError (clean message) on any malformed input.
      private def build_fuzz_job(h) : {Fuzz::Engine, Fuzz::Origin, Int64?, Bool}
        text, default_target, src_h2 = fuzz_template_source(h)
        text = Env.expand(text)
        default_target = default_target.try { |t| Env.expand(t) }
        use_h2 = (bool(h, "http2") || false) || src_h2
        text = Fuzz::Template.auto_mark(text) if bool(h, "auto") || false
        m = Fuzz::Template::MARKER
        fuzz_marks(h).each { |tok| text = text.gsub(tok, "#{m}#{tok}#{m}") }
        template = Fuzz::Template.parse(text, use_h2)
        raise FuzzArgError.new("template has no §…§ positions (add markers, or pass auto:true with a flow_id)") if template.position_count == 0
        origin = fuzz_origin(h, default_target)
        mode = fuzz_mode(h)
        sets = fuzz_sets(h, fuzz_processors(h))
        raise FuzzArgError.new(%(no payloads — pass 'payloads' as a JSON array of sets, e.g. [{"list":["a","b"]}])) if sets.empty?
        matcher = fuzz_matcher(h)
        config = fuzz_config(h, mode)
        gen_sets = mode.per_position? ? sets : [sets.first]
        generator = Fuzz::Generator.new(template, gen_sets, config, registry: Decoder.shared_registry)
        sender = Fuzz::Sender.new(origin, http2: use_h2,
          verify: @verify_upstream && !(bool(h, "insecure") || false), timeout: fuzz_timeout(h))
        engine = Fuzz::Engine.new(generator, matcher, sender, config)
        {engine, origin, engine.total, use_h2}
      rescue ex : File::Error
        raise FuzzArgError.new("wordlist error: #{ex.message}")
      end

      # The audit/evidence policy for a fuzz run: none (default) | matched | all.
      # `matched` records each MATCHED result's rendered request + response as a
      # History flow; `all` records every sent request (bounded by FUZZ_HISTORY_MAX).
      private def fuzz_record_policy(h) : Symbol
        case str(h, "record_history").try(&.strip.downcase)
        when "matched" then :matched
        when "all"     then :all
        else                :none
        end
      end

      private def fuzz_template_source(h) : {String, String?, Bool}
        if t = str(h, "template")
          return {t, nil, false} unless t.strip.empty?
        end
        if id = int(h, "flow_id")
          detail = store.get_flow(id)
          raise FuzzArgError.new("no flow with id #{id}") unless detail
          built = Repeater::FlowRequest.build(detail)
          return {String.new(built.bytes).scrub, built.target, built.http2}
        end
        raise FuzzArgError.new("provide a 'template' (raw request with §…§) or a 'flow_id'")
      end

      private def fuzz_mode(h) : Fuzz::Mode
        s = str(h, "mode")
        return Fuzz::Mode::Sniper if s.nil? || s.strip.empty?
        Fuzz::Mode.parse?(s) || raise FuzzArgError.new("invalid mode '#{s}' (sniper|batteringram|pitchfork|clusterbomb)")
      end

      # Mirrors `fuzz_sets`'s array-pulling pattern (bare array, or a JSON-encoded
      # string — LLM clients vary), but for plain string tokens.
      private def fuzz_marks(h) : Array(String)
        raw = h["marks"]?
        return [] of String unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of String if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'marks' must be a JSON array of strings")
            parsed.as_a? || raise FuzzArgError.new("'marks' must be a JSON array")
          else
            raise FuzzArgError.new("'marks' must be a JSON array of strings (not a bare string/scalar)")
          end
        arr.map { |v| v.as_s? || raise FuzzArgError.new("each 'marks' entry must be a string") }
      end

      private def fuzz_sets(h, processors : Array(Fuzz::Processor)) : Array(Fuzz::PayloadSet)
        raw = h["payloads"]?
        return [] of Fuzz::PayloadSet unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of Fuzz::PayloadSet if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'payloads' must be a JSON array of sets")
            parsed.as_a? || raise FuzzArgError.new("'payloads' must be a JSON array")
          else
            raise FuzzArgError.new("'payloads' must be a JSON array of sets (not a bare string/scalar)")
          end
        arr.map { |spec| fuzz_set_from(spec, processors) }
      end

      private def fuzz_set_from(spec : JSON::Any, processors : Array(Fuzz::Processor)) : Fuzz::PayloadSet
        obj = spec.as_h? || raise FuzzArgError.new("each payload set must be a JSON object")
        Fuzz::PayloadSet.new(fuzz_source_from(obj, spec), processors)
      end

      # The processing pipeline applied to EVERY payload set (mirrors the CLI's
      # `--prefix`/`--suffix`/`--encode`/`--case`/`--hash`/`--regex-replace`, which all
      # feed one shared `processors` array applied to every source — see cli/run/fuzz.cr).
      # Mirrors fuzz_marks/fuzz_sets's dual bare-array/JSON-encoded-string acceptance
      # (LLM clients vary in whether they send a real array or a JSON string).
      private def fuzz_processors(h) : Array(Fuzz::Processor)
        raw = h["processors"]?
        return [] of Fuzz::Processor unless raw
        arr =
          if a = raw.as_a?
            a
          elsif s = raw.as_s?
            return [] of Fuzz::Processor if s.strip.empty?
            parsed = JSON.parse(s) rescue raise FuzzArgError.new("'processors' must be a JSON array")
            parsed.as_a? || raise FuzzArgError.new("'processors' must be a JSON array")
          else
            raise FuzzArgError.new("'processors' must be a JSON array (not a bare string/scalar)")
          end
        arr.map { |spec| fuzz_processor_from(spec) }
      end

      private def fuzz_processor_from(spec : JSON::Any) : Fuzz::Processor
        obj = spec.as_h? || raise FuzzArgError.new("each processor must be a JSON object")
        case obj["type"]?.try(&.as_s?).try(&.downcase)
        when "prefix"        then Fuzz::Prefix.new(fuzz_processor_text(obj, "text", "prefix"))
        when "suffix"        then Fuzz::Suffix.new(fuzz_processor_text(obj, "text", "suffix"))
        when "encode"        then Fuzz::Encode.new(fuzz_encode_kind(jstr(obj, "kind")))
        when "case"          then Fuzz::Case.new(fuzz_case_kind(jstr(obj, "kind")))
        when "hash"          then Fuzz::Hasher.new(fuzz_hash_algo(jstr(obj, "algo")))
        when "regex_replace" then fuzz_regex_replace_processor(obj)
        else                      raise FuzzArgError.new(%(unknown processor #{spec} (use prefix/suffix/encode/case/hash/regex_replace)))
        end
      end

      private def fuzz_processor_text(obj : Hash(String, JSON::Any), key : String, type : String) : String
        strict_jstr(obj, key) || raise FuzzArgError.new(%(processor "#{type}" needs a '#{key}' string))
      end

      private def fuzz_regex_replace_processor(obj : Hash(String, JSON::Any)) : Fuzz::RegexReplace
        pattern = strict_jstr(obj, "pattern")
        raise FuzzArgError.new(%(processor "regex_replace" needs a non-empty 'pattern' string)) if pattern.nil? || pattern.empty?
        regex = Regex.new(pattern) rescue raise FuzzArgError.new("invalid processors.regex_replace pattern '#{pattern}'")
        Fuzz::RegexReplace.new(regex, strict_jstr(obj, "replacement") || "")
      end

      # Like `jstr`, but WITHOUT its `v.to_s` fallback: a JSON null/array/object stays nil
      # instead of stringifying into a truthy-but-garbage value (`nil.to_s` => `""`, which is
      # truthy in Crystal and silently defeats a `jstr(...) || raise` guard; an array/object
      # stringifies into text that can itself pass as a non-empty regex pattern). Used for
      # values spliced directly onto the wire (`text`/`pattern`/`replacement`), where only a
      # genuine JSON string is ever a sane input.
      private def strict_jstr(obj : Hash(String, JSON::Any), key : String) : String?
        obj[key]?.try(&.as_s?)
      end

      private def fuzz_encode_kind(v : String?) : Symbol
        case v.try(&.downcase)
        when "url"    then :url
        when "urlall" then :url_all
        when "base64" then :base64
        when "hex"    then :hex
        else               raise FuzzArgError.new(%(processor "encode" needs 'kind' url|urlall|base64|hex, got #{v.inspect}))
        end
      end

      private def fuzz_case_kind(v : String?) : Symbol
        case v.try(&.downcase)
        when "upper" then :upper
        when "lower" then :lower
        else              raise FuzzArgError.new(%(processor "case" needs 'kind' upper|lower, got #{v.inspect}))
        end
      end

      private def fuzz_hash_algo(v : String?) : Symbol
        case v.try(&.downcase)
        when "md5"    then :md5
        when "sha1"   then :sha1
        when "sha256" then :sha256
        else               raise FuzzArgError.new(%(processor "hash" needs 'algo' md5|sha1|sha256, got #{v.inspect}))
        end
      end

      private def fuzz_source_from(obj : Hash(String, JSON::Any), spec : JSON::Any) : Fuzz::PayloadSource
        if list = obj["list"]?.try(&.as_a?)
          Fuzz::InlineList.new(list.map { |x| x.as_s? || x.to_s })
        elsif wl = obj["wordlist"]?.try(&.as_s?)
          Fuzz::WordlistFile.new(wl)
        elsif nums = obj["numbers"]?
          fuzz_numbers(nums)
        elsif (nul = obj["null"]?) && (n = (nul.as_i64? || nul.as_s?.try(&.to_i64?)))
          Fuzz::NullPayloads.new(n.clamp(0_i64, FUZZ_MAX_REQUESTS).to_i) # clamp before .to_i so a huge count can't OverflowError past the clean-error handler
        elsif br = obj["brute"]?
          fuzz_brute(br)
        else
          raise FuzzArgError.new("unknown payload set #{spec} (use list/wordlist/numbers/null/brute)")
        end
      end

      # An integer from a JSON scalar — a real number, or a numeric string (LLMs
      # sometimes quote numbers). nil when it is neither.
      private def fuzz_int(v : JSON::Any?) : Int64?
        return nil unless v
        v.as_i64? || v.as_s?.try(&.to_i64?)
      end

      # Clamp a length to Int32 so an absurd value from the object form can't
      # OverflowError past the clean-error handler (the run is still capped by
      # FUZZ_MAX_REQUESTS regardless).
      private def clamp_brute_len(n : Int64) : Int32
        n.clamp(0_i64, Int64.new(Int32::MAX)).to_i
      end

      # numbers set: the compact "FROM-TO[:STEP]" string OR a structured object
      # {"from":N,"to":N,"step":N}. Agents emit structured JSON more reliably than
      # partitioned strings, so both are accepted (#4).
      private def fuzz_numbers(v : JSON::Any) : Fuzz::NumberRange
        if obj = v.as_h?
          from = fuzz_int(obj["from"]?)
          to = fuzz_int(obj["to"]?)
          raise FuzzArgError.new(%(numbers object needs integer 'from' and 'to', e.g. {"from":1,"to":100,"step":2})) unless from && to
          return Fuzz::NumberRange.new(from, to, fuzz_int(obj["step"]?) || 1_i64)
        end
        s = v.as_s? || raise FuzzArgError.new(%('numbers' must be a string 'FROM-TO[:STEP]' or an object {from,to,step}))
        range_part, _, step_part = s.partition(':')
        if md = range_part.match(/^(-?\d+)-(-?\d+)$/)
          from = md[1].to_i64?
          to = md[2].to_i64?
        else
          from = nil
          to = nil
        end
        raise FuzzArgError.new("invalid numbers '#{s}' (use FROM-TO[:STEP])") unless from && to
        step = step_part.empty? ? 1_i64 : (step_part.to_i64? || raise FuzzArgError.new("invalid numbers step '#{step_part}'"))
        Fuzz::NumberRange.new(from, to, step)
      end

      # brute set: the compact "CHARSET:MIN-MAX" string OR a structured object
      # {"charset":"abc","min":1,"max":3} (max defaults to min).
      private def fuzz_brute(v : JSON::Any) : Fuzz::BruteForce
        if obj = v.as_h?
          charset = obj["charset"]?.try(&.as_s?)
          raise FuzzArgError.new(%(brute object needs a non-empty 'charset', e.g. {"charset":"abc","min":1,"max":3})) if charset.nil? || charset.empty?
          min = fuzz_int(obj["min"]?)
          raise FuzzArgError.new("brute object needs an integer 'min'") unless min
          max = fuzz_int(obj["max"]?) || min
          return Fuzz::BruteForce.new(charset, clamp_brute_len(min), clamp_brute_len(max))
        end
        s = v.as_s? || raise FuzzArgError.new(%('brute' must be a string 'CHARSET:MIN-MAX' or an object {charset,min,max}))
        charset, _, lens = s.rpartition(':')
        raise FuzzArgError.new("invalid brute '#{s}' (use CHARSET:MIN-MAX)") if charset.empty? || lens.empty?
        min_s, _, max_s = lens.partition('-')
        min = min_s.to_i?
        max = max_s.empty? ? min : max_s.to_i?
        raise FuzzArgError.new("invalid brute lengths '#{lens}'") unless min && max
        Fuzz::BruteForce.new(charset, min, max)
      end

      private def fuzz_matcher(h) : Fuzz::Matcher
        # keep_bodies drives whether each Result retains its rendered request +
        # response bytes — needed only when record_history asks us to persist them.
        m = Fuzz::Matcher.new(keep_bodies: fuzz_record_policy(h))
        if c = fuzz_conditions(h["match"]?, "match")
          m.match_status = c[:status]
          m.match_size = c[:size]
          m.match_words = c[:words]
          m.match_lines = c[:lines]
          m.match_regex = fuzz_regex(c[:regex], "match")
        end
        if c = fuzz_conditions(h["filter"]?, "filter")
          m.filter_status = c[:status]
          m.filter_size = c[:size]
          m.filter_words = c[:words]
          m.filter_lines = c[:lines]
          m.filter_regex = fuzz_regex(c[:regex], "filter")
        end
        m.extract = fuzz_regex(str(h, "extract"), "extract")
        m
      end

      private alias FuzzConds = NamedTuple(status: String?, size: String?, words: String?, lines: String?, regex: String?)

      private def fuzz_conditions(raw : JSON::Any?, which : String) : FuzzConds?
        return nil unless raw
        obj =
          if h = raw.as_h?
            h
          elsif s = raw.as_s?
            return nil if s.strip.empty?
            (JSON.parse(s).as_h? rescue nil) || raise FuzzArgError.new("'#{which}' must be a JSON object")
          else
            raise FuzzArgError.new("'#{which}' must be a JSON object (not a bare string/scalar)")
          end
        {status: jstr(obj, "status"), size: jstr(obj, "size"), words: jstr(obj, "words"),
         lines: jstr(obj, "lines"), regex: obj["regex"]?.try(&.as_s?)}
      end

      private def jstr(obj : Hash(String, JSON::Any), key : String) : String?
        obj[key]?.try { |v| v.as_s? || v.to_s }
      end

      private def fuzz_regex(s : String?, which : String) : Regex?
        return nil if s.nil? || s.empty?
        Regex.new(s)
      rescue ex
        raise FuzzArgError.new("invalid #{which} regex '#{s}': #{ex.message}")
      end

      private def fuzz_config(h, mode : Fuzz::Mode) : Fuzz::Config
        rate = int(h, "rate").try(&.to_f64)
        # Ignore a non-positive caller cap (it would otherwise become a negative cap
        # that halts the dispatcher at request 0); fall back to the hard ceiling.
        caller_cap = int(h, "max_requests").try { |m| m > 0 ? m : nil }
        cap = [caller_cap, FUZZ_MAX_REQUESTS].compact.min
        Fuzz::Config.new(mode: mode,
          concurrency: clamp(int(h, "concurrency"), 20, FUZZ_MAX_CONCURRENCY),
          rps: (rate && rate > 0 ? rate : nil),
          retries: (int(h, "retries") || 0_i64).clamp(0_i64, 1000_i64).to_i,
          timeout: fuzz_timeout(h),
          keep_bodies: fuzz_record_policy(h),
          max_requests: cap)
      end
    end
  end
end
