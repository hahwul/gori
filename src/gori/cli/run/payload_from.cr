# `--payload-from` (#1352): payload values read from data the project already captured, shared by
# `gori run fuzz`, `gori run mine` and `gori run wordlist save`. The flag parsing lives here; what a
# source MEANS — the query, the projections, the caps, the secret policy, the empty-source refusal
# — is `Gori::PayloadFrom`, and it is read by the plan builders, so the three surfaces cannot come
# to disagree about it.
module Gori
  module CLI
    module Run
      # The run-wide companions of `--payload-from`, collected while the parser walks argv and
      # applied to EVERY source once it is done — so `--payload-from-sensitive` means the same
      # wherever it sits relative to the flag it modifies.
      class PayloadFromFlags
        property? sensitive = false
        property locations : Array(Miner::Location)? = nil
        property max_flows = PayloadFrom::DEFAULT_MAX_FLOWS
        property max_values = PayloadFrom::DEFAULT_MAX_VALUES

        def policy : PayloadFrom::Policy
          PayloadFrom::Policy.new(locations: @locations, include_sensitive: @sensitive,
            max_flows: @max_flows, max_values: @max_values)
        end
      end

      # Register `--payload-from` and its companions on `p`. `on_spec` receives each parsed
      # source in argv order; a malformed descriptor aborts with the builder's sentence, naming
      # the flag, before anything is read.
      private def self.payload_from_flags(p : OptionParser, cmd : String, flags : PayloadFromFlags,
                                          what : String, &on_spec : PayloadFrom::Spec ->) : Nil
        p.on("--payload-from=DESC", "#{what}: values read from the project's captured data, DESC = '<QL> <projection>' " \
                                    "(#{PayloadFrom::Projection.labels.join(" | ")}; e.g. 'host:api.example param-names'). " \
                                    "Reads the project, sends nothing. Repeatable") do |v|
          spec = begin
            PayloadFrom.parse(v)
          rescue ex : PayloadFrom::Error
            abort "#{cmd}: --payload-from: #{ex.message}"
          end
          on_spec.call(spec)
        end
        p.on("--payload-from-sensitive", "Let --payload-from read values that are credential material (cookies, credential headers " \
                                         "and fields, JWT/key-shaped values) and the extracted projection — withheld by default; reported when on") do
          flags.sensitive = true
        end
        p.on("--payload-from-locations=LIST", "Locations param-names / param-values read: query,form,multipart,json,headers,cookies " \
                                              "(default query,form,multipart,json)") do |v|
          flags.locations = parse_mine_locations(v, cmd)
        end
        p.on("--payload-from-max-flows=N", "Newest flows a --payload-from source reads (default #{PayloadFrom::DEFAULT_MAX_FLOWS}, max #{PayloadFrom::MAX_FLOWS})") do |v|
          flags.max_flows = parse_count(v, "--payload-from-max-flows")
        end
        p.on("--payload-from-max-values=N", "Distinct values a --payload-from source keeps (default #{PayloadFrom::DEFAULT_MAX_VALUES}, max #{PayloadFrom::MAX_VALUES})") do |v|
          flags.max_values = parse_count(v, "--payload-from-max-values")
        end
      end

      # A `--payload-from-*` companion with no `--payload-from` to modify is a knob that silently
      # did nothing. Refused rather than ignored.
      private def self.refuse_orphan_payload_from_flags(cmd : String, flags : PayloadFromFlags, any_source : Bool) : Nil
        return if any_source
        stray = [] of String
        stray << "--payload-from-sensitive" if flags.sensitive?
        stray << "--payload-from-locations" if flags.locations
        stray << "--payload-from-max-flows" if flags.max_flows != PayloadFrom::DEFAULT_MAX_FLOWS
        stray << "--payload-from-max-values" if flags.max_values != PayloadFrom::DEFAULT_MAX_VALUES
        return if stray.empty?
        abort "#{cmd}: #{stray.join(", ")} modif#{stray.size == 1 ? "ies" : "y"} --payload-from, and none was given"
      end

      # The project a source is read from, opened for the lifetime of one plan build. A source
      # reads captured data, so it needs a project the operator NAMED: a `--flow` / `--repeater`
      # seed and `--project` / `--db` all name one, and a bare `--request` / stdin run
      # (deliberately outside any project) does not — reading the ambient default there would put
      # another engagement's values into this run, silently. `read_only` unless a source's query
      # reads the search index (a `body:` term drains it, which is a write).
      private def self.open_payload_from_store(cmd : String, specs : Array(PayloadFrom::Spec),
                                               named_project : Bool, project_name : String?, db_path : String?) : Store?
        return nil if specs.empty?
        unless named_project
          abort "#{cmd}: --payload-from reads a project's captured data and none was named — reading the default " \
                "project's data in silently is not something it will do (a --request/stdin run is deliberately outside " \
                "any project). Pass --project NAME or --db PATH."
        end
        open_store(resolve_read_project(project_name, db_path), read_only: specs.none? { |s| PayloadFrom.uses_fts?(s) })
      end

      # What a source read, one line each, with the flag that lifts the cap that ended it. Never a
      # value. Public so a spec can pin the wording: the printing below cannot be observed.
      def self.payload_from_note_lines(cmd : String, reports : Array(PayloadFrom::Report)) : Array(String)
        reports.map do |r|
          line = "#{cmd}: payload-from: #{r.summary}"
          if cap = r.capped_by
            hint = cap.flows? ? "raise --payload-from-max-flows" : (cap.values? ? "raise --payload-from-max-values" : "narrow the query")
            line += " (#{hint})"
          end
          line
        end
      end

      # On STDERR — STDOUT is data.
      private def self.note_payload_from(cmd : String, reports : Array(PayloadFrom::Report)) : Nil
        payload_from_note_lines(cmd, reports).each { |line| STDERR.puts line }
      end
    end
  end
end
