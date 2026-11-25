require "./session_config"
require "./plan"

module Gori::Fuzz
  # An authored tab is project data. Building validates and reads payload sources, but never
  # calls Engine#run, calibration, or a binding replay; only the operator can start the sweep.
  class PreparedSession
    getter plan : Plan
    getter target : String
    getter template : String
    getter state : SessionConfig

    def self.build(options : PlanOptions, outbound : Gori::Outbound) : PreparedSession
      # Validation only: a chain's `exec:` step is withheld from the plan's baseline render.
      validate = options
      validate.run_hooks = false
      plan = Plan.build(validate, outbound)
      # The PLAN's config and matcher, which `Plan.build` copied off `options` and then settled
      # (`--verbatim` turns auto Content-Length off on the copy), so the stored tab says that.
      state = SessionConfig.new(plan.config, plan.matcher, options.http2?, options.sni || "",
        options.sources.map { |source| SetSpec.from_source(source) })
      state.options = SessionOptions.capture(options)
      state.evidence = options.evidence?
      state.grpc_fields = options.grpc_fields.empty? ? "" : options.grpc_fields.to_json
      state.extractor_columns = plan.matcher.extractors.map_with_index do |extractor, i|
        loc = extractor.loc
        Store::DisplayColumn.new(0_i64, i, extractor.label, Gori::MessageSide::Response,
          loc.kind, loc.selector, loc.pos_start, loc.pos_end)
      end
      if condition = plan.matcher.stop_condition
        state.stop_on = SavedMatcher.capture(condition).to_json
      end
      if macro_spec = plan.config.request_macro
        state.macro_steps = macro_spec.steps.join(",")
        state.macro_every = macro_spec.cadence.token
        state.macro_expect = macro_spec.expect.join(",")
        state.macro_on_failure = macro_spec.on_failure.token
      end
      target = options.target.try(&.presence) || options.default_target || raise Gori::Error.new("no target for prepared Fuzzer tab")
      new(plan, target, options.template, state)
    end

    def initialize(@plan, @target, @template, @state)
    end

    def insert(store : Store, name : String?, flow_id : Int64?) : Int64
      position = (store.fuzz_sessions.max_of?(&.position) || -1) + 1
      store.insert_fuzz_session(@target, @template, @state.http2?, @state.sni.presence,
        @state.to_json, flow_id, position, name)
    end
  end
end
