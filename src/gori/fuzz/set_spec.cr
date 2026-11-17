require "json"
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
