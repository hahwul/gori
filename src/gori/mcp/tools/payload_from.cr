require "json"
require "../../payload_from"

module Gori
  module MCP
    class Tools
      # `payload_from` (#1352): payload values read from the project's captured data, on
      # `fuzz_start` (a payload set), `mine_start` (candidate names) and `save_wordlist` (a saved
      # list). What a source means is `Gori::PayloadFrom`, read by the plan builders; this file is
      # only the MCP spelling of it and the report an agent gets back — which carries counts and the
      # policy that applied, and NEVER a value (an agent that wants the values reads the run's own
      # results, and a sensitive one only ever appears there under the explicit opt-in).

      # The knobs a source takes, as an agent writes them beside `payload_from`: `include_sensitive`,
      # `locations` (an array, or a comma list), `max_flows`, `max_values`. `prefix` is "" inside a
      # `fuzz_start` payload-set object (each source carries its own) and `payload_from_` on the
      # tools that take a LIST of descriptors and so one shared policy.
      private def payload_policy_arg(obj : Hash(String, JSON::Any), prefix : String = "") : PayloadFrom::Policy
        names = str_list(obj, "#{prefix}locations").flat_map(&.split(',')).map(&.strip).reject(&.empty?)
        locations = names.empty? ? nil : payload_locations(names, prefix)
        PayloadFrom::Policy.new(
          locations: locations,
          include_sensitive: bool_arg(obj, "#{prefix}include_sensitive", false),
          max_flows: bounded_int_arg(obj, "#{prefix}max_flows", PayloadFrom::DEFAULT_MAX_FLOWS.to_i64,
            min: 1_i64, max: PayloadFrom::MAX_FLOWS.to_i64).to_i,
          max_values: bounded_int_arg(obj, "#{prefix}max_values", PayloadFrom::DEFAULT_MAX_VALUES.to_i64,
            min: 1_i64, max: PayloadFrom::MAX_VALUES.to_i64).to_i)
      end

      private def payload_locations(names : Array(String), prefix : String) : Array(Miner::Location)
        names.map do |n|
          Miner::Location.parse?(n) ||
            raise Gori::Error.new("unknown '#{prefix}locations' entry #{n.inspect} (query|form|multipart|json|headers|cookies)")
        end.uniq!
      end

      # A descriptor string → its normalized source, the builder's sentence as the refusal.
      private def payload_spec_arg(descriptor : String, key : String) : PayloadFrom::Spec
        PayloadFrom.parse(descriptor)
      rescue ex : PayloadFrom::Error
        raise Gori::Error.new("invalid '#{key}': #{ex.message}")
      end

      # One source's report as JSON. No value, ever.
      private def payload_report_json(j : JSON::Builder, r : PayloadFrom::Report) : Nil
        j.object do
          j.field "source", Serialize.text(r.source)
          j.field "projection", r.projection.label
          j.field "values", r.values
          j.field "flows_scanned", r.flows_scanned
          j.field "policy", r.policy
          j.field "locations", r.locations
          j.field "truncated", r.truncated?
          j.field("capped_by", r.capped_by.to_s.downcase) if r.capped_by
          j.field "skipped_sensitive", r.skipped_sensitive
          j.field "skipped_oversize", r.skipped_oversize
          j.field "framing_values", r.framing_values
          j.field("index_backlog", r.fts_backlog) if r.fts_backlog > 0
          j.field("note", r.note) if r.note
          j.field "summary", Serialize.text(r.summary)
        end
      end

      private def payload_reports_json(j : JSON::Builder, reports : Array(PayloadFrom::Report)) : Nil
        j.array { reports.each { |r| payload_report_json(j, r) } }
      end
    end
  end
end
