require "json"
require "../settings"
require "../display_columns"
require "./set_spec"
require "./session_options"

module Gori::Fuzz
  # The persisted Fuzzer tab format. Raw text knobs remain authored text, including
  # values that no longer resolve; parsing them into a runnable plan is a separate step.
  class SessionConfig
    property evidence : Bool? = nil
    property options : SessionOptions? = nil
    property options_error : String? = nil
    @options_raw : JSON::Any? = nil
    property config : Config
    property matcher : Matcher
    property? http2 : Bool
    property sni : String
    property sets : Array(SetSpec)
    property extractor_columns : Array(Store::DisplayColumn)
    property stop_on : String
    property grpc_fields : String
    property macro_steps : String
    property macro_every : String
    property macro_expect : String
    property macro_on_failure : String

    def initialize(@config = Config.new(keep_bodies: :all), @matcher = Matcher.new,
                   @http2 = false, @sni = "", @sets = [] of SetSpec,
                   @extractor_columns = [] of Store::DisplayColumn,
                   @stop_on = "",
                   @grpc_fields = "",
                   @macro_steps = "",
                   @macro_every = "",
                   @macro_expect = "",
                   @macro_on_failure = "")
    end

    def to_json : String
      JSON.build do |j|
        j.object do
          if options = @options
            j.field "plan_options", options
          elsif raw = @options_raw
            j.field "plan_options", raw
          end
          if (timeout = @config.timeout) && timeout.total_milliseconds % 1000 != 0
            j.field "timeout_ms", timeout.total_milliseconds.to_i64
          end
          j.field "evidence", @evidence unless @evidence.nil?
          j.field "mode", @config.mode.to_s
          j.field "http2", @http2
          j.field "sni", @sni
          j.field "concurrency", @config.concurrency
          j.field "rps", @config.rps
          j.field "throttle_ms", @config.throttle_ms
          j.field "timeout_s", @config.timeout.try(&.total_seconds.to_i)
          j.field "retries", @config.retries
          j.field "max_requests", @config.max_requests
          j.field "race_count", @config.race_count
          # `stop_on` (issue #1240): the match count, the raw DIM:SPEC condition text (the same
          # "store what the operator typed" reasoning as `grpc_fields`), and the archive policy.
          j.field "stop_after_matches", @config.stop_after_matches
          j.field "stop_on", @stop_on
          j.field "keep", @config.keep.label
          j.field "follow", @config.follow_redirects?
          j.field "calibrate", @config.auto_calibrate?
          j.field "keep_alive", @config.keep_alive?
          j.field "update_cl", @config.update_content_length?
          j.field "reframe_grpc", @config.reframe_grpc?
          j.field "tls_preset", @config.tls_preset
          j.field("sets") { j.array { @sets.each { |s| j.object { j.field "kind", s.kind.to_s; j.field "value", s.value } } } }
          j.field "match_status", @matcher.match_status
          j.field "filter_status", @matcher.filter_status
          j.field "match_size", @matcher.match_size
          j.field "filter_size", @matcher.filter_size
          j.field "match_words", @matcher.match_words
          j.field "filter_words", @matcher.filter_words
          j.field "match_time", @matcher.match_time
          j.field "filter_time", @matcher.filter_time
          j.field "match_regex", @matcher.match_regex.try(&.source)
          j.field "filter_regex", @matcher.filter_regex.try(&.source)
          j.field "match_grpc", @matcher.match_grpc if @matcher.match_grpc
          j.field "filter_grpc", @matcher.filter_grpc if @matcher.filter_grpc
          j.field "match_lines", @matcher.match_lines if @matcher.match_lines
          j.field "filter_lines", @matcher.filter_lines if @matcher.filter_lines
          j.field "match_header", @matcher.match_header if @matcher.match_header
          j.field "filter_header", @matcher.filter_header if @matcher.filter_header
          # The named extractors (#1592) as `--extractor` specs; the old single `extract` regex
          # is read back as extractor 0 and not written again.
          j.field("extractors") do
            j.array { @extractor_columns.each { |c| j.object { j.field "spec", c.spec; j.field "width", c.width } } }
          end
          # The raw row text, not the parsed list: it is what the operator typed and what the
          # ADVANCED card has to show again, and a spec that no longer resolves (the descriptor
          # set moved) must come back as itself rather than silently vanish on restore.
          j.field "grpc_fields", @grpc_fields
          # The request-time macro (#1350), as typed — the same "store what the operator typed"
          # reasoning as `grpc_fields` and `stop_on`.
          j.field "macro_steps", @macro_steps
          j.field "macro_every", @macro_every
          j.field "macro_expect", @macro_expect
          j.field "macro_on_failure", @macro_on_failure
        end
      end
    end

    def apply_json(raw : String) : Bool
      return false if raw.strip.empty?
      obj = JSON.parse(raw).as_h? || return false
      apply_options_json(obj)
      @evidence = obj["evidence"]?.try(&.as_bool?)
      obj["mode"]?.try(&.as_s?).try { |m| Fuzz::Mode.parse?(m).try { |mode| @config.mode = mode } }
      @http2 = obj["http2"]?.try(&.as_bool?) || @http2
      @sni = obj["sni"]?.try(&.as_s?) || @sni
      Settings.int_field(obj, "concurrency").try { |n| @config.concurrency = n }
      @config.rps = obj["rps"]?.try(&.as_f?)
      @config.throttle_ms = Settings.int_field(obj, "throttle_ms")
      # Assigned, not guarded: `config_json` writes the key as `null` when there is no
      # timeout, and a guarded read kept the stale one when the peer had CLEARED it.
      @config.timeout = Settings.int_field(obj, "timeout_s").try(&.seconds)
      obj["timeout_ms"]?.try(&.as_i64?).try { |ms| @config.timeout = ms.milliseconds }
      Settings.int_field(obj, "retries").try { |n| @config.retries = n }
      @config.max_requests = obj["max_requests"]?.try(&.as_i64?)
      @config.race_count = Settings.int_field(obj, "race_count")
      apply_stop_on_json(obj)
      @config.follow_redirects = obj["follow"]?.try(&.as_bool?) || false
      @config.auto_calibrate = obj["calibrate"]?.try(&.as_bool?) || false
      # A session persisted before this key existed reads as nil ⇒ keep the ctor default
      # (on). `|| false` here would silently turn keep-alive off for every saved tab.
      @config.keep_alive = obj["keep_alive"]?.try(&.as_bool?) != false
      # Same nil-means-default reading as keep_alive above: a session saved before this
      # key existed must keep the ctor default (on), not silently start sending desyncs.
      @config.update_content_length = obj["update_cl"]?.try(&.as_bool?) != false
      # The OPPOSITE reading to update_cl above, because the default is the opposite: absent
      # (a session saved before this key existed) must mean OFF, the ctor default and the
      # headless one (DESIGN.md §7).
      @config.reframe_grpc = obj["reframe_grpc"]?.try(&.as_bool?) || false
      # Absent (a session saved before this key existed) reads as nil, which IS the default —
      # no override, the destination's own policy. No `!= false` dance is needed here because
      # the field is nilable rather than a boolean with a non-false default.
      @config.tls_preset = Settings.tls_preset_normalize(obj["tls_preset"]?.try(&.as_s?))
      apply_sets_json(obj["sets"]?)
      @matcher.match_status = obj["match_status"]?.try(&.as_s?)
      @matcher.filter_status = obj["filter_status"]?.try(&.as_s?)
      @matcher.match_size = obj["match_size"]?.try(&.as_s?)
      @matcher.filter_size = obj["filter_size"]?.try(&.as_s?)
      @matcher.match_words = obj["match_words"]?.try(&.as_s?)
      @matcher.filter_words = obj["filter_words"]?.try(&.as_s?)
      # Absent (a session saved before this key existed) reads as nil, which IS the default:
      # an unconstrained dimension. Same nilable-string reading as every matcher spec above.
      @matcher.match_time = obj["match_time"]?.try(&.as_s?)
      @matcher.filter_time = obj["filter_time"]?.try(&.as_s?)
      @matcher.match_regex = obj["match_regex"]?.try(&.as_s?).try { |s| Regex.new(s) rescue nil }
      @matcher.filter_regex = obj["filter_regex"]?.try(&.as_s?).try { |s| Regex.new(s) rescue nil }
      @matcher.match_grpc = obj["match_grpc"]?.try(&.as_s?)
      @matcher.filter_grpc = obj["filter_grpc"]?.try(&.as_s?)
      @matcher.match_lines = obj["match_lines"]?.try(&.as_s?)
      @matcher.filter_lines = obj["filter_lines"]?.try(&.as_s?)
      @matcher.match_header = obj["match_header"]?.try(&.as_s?)
      @matcher.filter_header = obj["filter_header"]?.try(&.as_s?)
      apply_extractors_json(obj)
      @grpc_fields = string_knob(obj, "grpc_fields")
      apply_macro_json(obj)
      true
    rescue
      # tolerate a malformed/older config blob — keep defaults
      false
    end

    def options_raw_json : String?
      @options_raw.try(&.to_json)
    end

    def apply_options_raw(raw : String?) : Nil
      @options_raw = raw.try { |value| (JSON.parse(value) rescue JSON::Any.new(value)) }
    end

    private def apply_options_json(obj : Hash(String, JSON::Any)) : Nil
      @options = nil
      @options_error = nil
      @options_raw = obj["plan_options"]?
      return unless raw = @options_raw
      @options = SessionOptions.from_json(raw.to_json)
    rescue ex
      @options_error = "saved Fuzzer options cannot be read: #{ex.message}"
    end

    # Each spec on its own, so one that no longer parses is dropped rather than every other one
    # with it; a pre-#1592 `extract` regex comes back as extractor 0, `extracted`.
    private def apply_extractors_json(obj : Hash(String, JSON::Any)) : Nil
      cols = [] of Store::DisplayColumn
      if (legacy = obj["extract"]?.try(&.as_s?)) && !legacy.empty?
        cols << Store::DisplayColumn.new(0_i64, 0, Fuzz::Extractor::LEGACY_LABEL,
          Gori::MessageSide::Response, Gori::ExtractKind::Regex, legacy)
      end
      (obj["extractors"]?.try(&.as_a?) || [] of JSON::Any).each do |v|
        # `as_h?` first: `JSON::Any#[]?` raises on a non-object, and the method-wide rescue
        # would then drop every key after this one.
        entry = v.as_h? || next
        sp = entry["spec"]?.try(&.as_s?).try { |raw| Gori::DisplayColumns.parse_spec(raw) }
        next unless sp.is_a?(Gori::DisplayColumns::Spec)
        width = entry["width"]?.try(&.as_i64?).try(&.clamp(0, Gori::DisplayColumns::MAX_WIDTH).to_i32) || 0
        cols << Store::DisplayColumn.new(0_i64, cols.size, sp.label, sp.side, sp.kind, sp.selector,
          sp.pos_start, sp.pos_end, width)
      end
      @extractor_columns = cols.map_with_index do |c, i|
        Store::DisplayColumn.new(0_i64, i, c.label, Gori::MessageSide::Response, c.kind,
          c.selector, c.pos_start, c.pos_end, c.width)
      end
    end

    # The `stop_on` knobs (issue #1240), restored together — split out of `apply_config_json`
    # so that method stays under the complexity ceiling. Absent (a session saved before these
    # keys existed) reads as nil / blank / all: no stop condition and an unfiltered archive,
    # which every saved tab was.
    private def apply_stop_on_json(obj : Hash(String, JSON::Any)) : Nil
      @config.stop_after_matches = Settings.int_field(obj, "stop_after_matches")
      @stop_on = string_knob(obj, "stop_on")
      @config.keep = Fuzz::Keep.parse?(obj["keep"]?.try(&.as_s?)) || Fuzz::Keep::All
    end

    # A persisted STRING knob, or "" for a session saved before the key existed (and for a
    # blob that carries something else there). A helper rather than the `?.try(&.as_s?) || ""`
    # chain inline: `apply_config_json` is already at the complexity ceiling, and the next knob
    # to be added has one example to follow instead of a fourth spelling.
    private def string_knob(obj : Hash(String, JSON::Any), key : String) : String
      obj[key]?.try(&.as_s?) || ""
    end

    # The macro rows, restored together — split out of `apply_config_json` so that method stays
    # under the complexity ceiling. Absent (a session saved before the feature) reads as blank,
    # i.e. no macro.
    private def apply_macro_json(obj : Hash(String, JSON::Any)) : Nil
      @macro_steps = string_knob(obj, "macro_steps")
      @macro_every = string_knob(obj, "macro_every")
      @macro_expect = string_knob(obj, "macro_expect")
      @macro_on_failure = string_knob(obj, "macro_on_failure")
    end

    private def apply_sets_json(arr : JSON::Any?) : Nil
      arr.try(&.as_a?).try do |sets|
        @sets = sets.compact_map do |sp|
          h = sp.as_h?
          kind = parse_set_kind(h.try(&.["kind"]?).try(&.as_s?))
          v = h.try(&.["value"]?).try(&.as_s?) || ""
          kind ? SetSpec.new(kind, v) : nil
        end
      end
    end

    private def parse_set_kind(k : String?) : Symbol?
      case k
      when "list"    then :list
      when "bytes"   then :bytes
      when "file"    then :file
      when "preset"  then :preset
      when "project" then :project
      when "numbers" then :numbers
      when "null"    then :null
      when "brute"   then :brute
      end
    end
  end
end
