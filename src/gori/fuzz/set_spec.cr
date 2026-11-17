require "json"
require "base64"
require "../payload_from"

module Gori::Fuzz
  # One payload set: a source kind + a value string in the compact grammar the Fuzz
  # engine consumes (list="a,b,c", numbers="from-to:step", file="path", null="N",
  # brute="charset:min-max"). Shared by FuzzerView (@sets, persistence, engine
  # assembly) and FuzzSetOverlay (the editor that produces one). Hoisted to module
  # scope so the overlay can build one without depending on FuzzerView.
  record SetSpec, kind : Symbol, value : String do
    # A `:list` value is NEWLINE-separated with a trailing newline — the overlay's own grammar
    # ("one value per line") — because a comma is ordinary payload text: `{"id":1,"role":"x"}`
    # or `' OR 1=1,--` stored comma-joined came back as two payloads, and the run count said
    # so while the operator read it as one. The trailing newline is the format marker: a value
    # with no newline at all is a session saved under the old comma grammar and is still
    # split on `,`, so nothing already on disk changes meaning.
    LIST_SEP = '\n'

    def self.list(values : Array(String)) : SetSpec
      new(:list, values.join(LIST_SEP) + LIST_SEP)
    end

    def self.list_values(value : String) : Array(String)
      return value.split(',') unless value.includes?(LIST_SEP)
      value.chomp(LIST_SEP).split(LIST_SEP)
    end

    # Binary or newline-bearing values use an explicit base64 list, editable in the same
    # payload card without losing a byte to line splitting or UTF-8 replacement.
    def self.persisted_list(values : Array(String)) : SetSpec
      if values.any? { |v| !v.valid_encoding? || v.includes?('\n') || v.empty? || v != v.strip }
        new(:bytes, values.map { |v| Base64.strict_encode(v.to_slice) }.to_json)
      else
        list(values)
      end
    end

    def self.from_source(source : PayloadSource) : SetSpec
      case source
      when InlineList then persisted_list(source.values)
      when WordlistFile
        return new(:file, File.expand_path(source.path)) if File.info(source.path).file?
        values = [] of String
        source.each { |v| values << v }
        persisted_list(values)
      when NumberRange  then new(:numbers, "#{source.from}-#{source.to}:#{source.step}")
      when NullPayloads then new(:null, source.size.to_s)
      when BruteForce   then new(:brute, "#{source.charset}:#{source.min}-#{source.max}")
      when PresetSource
        return new(:preset, source.name) unless source.user_path
        values = [] of String
        source.each { |v| values << v }
        persisted_list(values)
      when ProjectSource
        # Plan.build already resolved this bounded source. Freeze its reviewed values, so
        # a later capture cannot silently change the sweep the operator was handed.
        values = [] of String
        source.each { |v| values << v }
        persisted_list(values)
      else
        raise Gori::Error.new("payload source cannot be saved in a Fuzzer tab")
      end
    end

    # A `:project` set (#1352) keeps its source as JSON in `value` — a query, a projection, the
    # sensitive opt-in — because it is a structured thing and a session persists `kind` and `value`
    # as two strings. Read back through `project_spec`, which is nil for a value that no longer
    # parses (a session written by a later gori), so a set row never raises.
    def self.project(query : String, projection : PayloadFrom::Projection, sensitive : Bool,
                     rule : String? = nil) : SetSpec
      new(:project, JSON.build do |j|
        j.object do
          j.field "query", query
          j.field "projection", projection.label
          j.field "rule", rule if rule
          j.field "sensitive", sensitive
        end
      end)
    end

    def project_spec : PayloadFrom::Spec?
      return nil unless kind == :project
      obj = JSON.parse(value).as_h? || return nil
      projection = PayloadFrom::Projection.parse?(obj["projection"]?.try(&.as_s?) || "") || return nil
      PayloadFrom::Spec.new((obj["query"]?.try(&.as_s?) || "").strip, projection,
        obj["rule"]?.try(&.as_s?), include_sensitive: obj["sensitive"]?.try(&.as_bool?) || false)
    rescue JSON::ParseException
      nil
    end

    def build_source : PayloadSource
      case kind
      when :list    then InlineList.new(SetSpec.list_values(value))
      when :bytes   then InlineList.new(JSON.parse(value).as_a.map { |v| String.new(Base64.decode(v.as_s)) })
      when :file    then WordlistFile.new(value)
      when :preset  then PresetSource.new(value)
      when :project then build_project_source
      when :null    then NullPayloads.new(value.to_i? || 1)
      when :numbers then build_numbers(value)
      when :brute   then build_brute(value)
      else               InlineList.new([value])
      end
    end

    # A `:project` set as the source the plan builder reads (#1352). Nothing is read here.
    private def build_project_source : PayloadSource
      spec = project_spec || raise Gori::Error.new("a project payload set could not be read back — edit it and choose its source again")
      ProjectSource.new(spec)
    end

    private def build_numbers(value : String) : NumberRange
      range, _, step = value.partition(':')
      # Match two (possibly negative) integers, so a leading '-' on From isn't mistaken
      # for the from/to separator (partition('-') would split "-5-5" as "" / "5-5").
      m = range.match(/\A(-?\d+)-(-?\d+)\z/)
      from = (m.try(&.[1].to_i64?)) || 0_i64
      to = (m.try(&.[2].to_i64?)) || 0_i64
      NumberRange.new(from, to, step.to_i64? || 1_i64)
    end

    private def build_brute(value : String) : BruteForce
      charset, _, lens = value.rpartition(':')
      lo, _, hi = lens.partition('-')
      BruteForce.new(charset, lo.to_i? || 1, hi.to_i? || (lo.to_i? || 1))
    end

    # ONE line, for a set row and a signature. The stored form of a list carries newlines.
    def display : String
      case kind
      when :list    then SetSpec.list_values(value).join(',')
      when :project then project_display
      else               value
      end
    end

    private def project_display : String
      spec = project_spec || return "(unreadable project source)"
      "#{spec.label}#{spec.include_sensitive ? " · SENSITIVE" : ""}"
    end
  end
end
