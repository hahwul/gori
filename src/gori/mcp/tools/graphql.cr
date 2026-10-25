require "json"
require "../../graphql/schema"
require "../../host_overrides"
require "../../repeater/plan"

module Gori
  module MCP
    class Tools
      # --- graphql_schema: a GraphQL endpoint's schema, compact -----------------
      #
      # The MCP adapter for `Graphql::Schema`. A READ by default: the flow's own response, when
      # it already is an introspection result. `send:true` is the one mode that dials — the
      # flow's request rewritten into the introspection query (`Introspection.rewrite_request`,
      # what the TUI's Repeater inserts) and sent through `send_request`'s gate: `Outbound.agent`
      # Layer 1, Sandbox, the project budget. So it sits with `probe_scan`: ungated, refused per
      # call under `--read-only` and under the `send` permission (`Tools#call_permission`).
      @[Tool("graphql_schema", read_only: false, env_refresh: true)]
      private def graphql_schema(h) : Result
        flow_id = required_id(h, "flow_id")
        detail = store.get_flow(flow_id)
        return not_found("no flow with id #{flow_id}") unless detail
        # Every argument read before the send, so a bad one never costs a request.
        send = bool_arg(h, "send", false)
        legacy = bool_arg(h, "legacy", false)
        allow_unscoped = bool_arg(h, "allow_unscoped", false)
        verify = !bool_arg(h, "insecure", false) && @verify_upstream
        timeout = fuzz_timeout(h)
        filter = str(h, "filter")
        max_bytes = graphql_max_bytes(h)
        if !send && (orphan = graphql_send_only_arg(h, timeout))
          return err("'#{orphan}' applies only with send:true", "INVALID_ARGUMENT", field: orphan)
        end

        sc = nil.as(ScopeCheck?)
        status = nil.as(Int32?)
        schema =
          if send
            return err("graphql_schema send:true is disabled (gori mcp --read-only); omit send to read the captured response", "TOOL_DISABLED") unless @allow_actions
            fetched = graphql_fetch(detail, legacy, allow_unscoped, verify, timeout)
            return fetched if fetched.is_a?(Result)
            sent, sc, status = fetched
            sent
          else
            if detail.response_body_truncated?
              return err("flow #{flow_id}'s captured response was cut at the capture cap, so its schema is " \
                         "incomplete; pass send:true to ask the endpoint again (ACTIVE)", "INVALID_ARGUMENT", field: "flow_id")
            end
            parsed = Graphql::Schema.parse(detail.response_head, detail.response_body)
            if parsed.is_a?(String)
              return err("flow #{flow_id} is not an introspection result: #{parsed}; pass send:true to " \
                         "re-send its request as an introspection query (ACTIVE)", "INVALID_ARGUMENT", field: "flow_id")
            end
            parsed
          end

        s = Graphql::Schema.summarize(schema, filter, max_bytes, sent: send)
        Result.new(JSON.build do |j|
          j.object do
            j.field "flow_id", flow_id
            j.field "source", send ? "sent" : "captured"
            j.field "status", status if status
            s.emit(j)
            sc.try { |v| emit_scope(j, v) }
          end
        end)
      end

      # Honoured down to 1 byte, as the CLI's --max-bytes is; a 0 (a schema-filling client's
      # placeholder) is the default, not "nothing".
      private def graphql_max_bytes(h) : Int32
        n = optional_int_arg(h, "max_bytes")
        (n && n > 0 ? n : REPLY_ROWS_BUDGET.to_i64).clamp(1_i64, REPLY_ROWS_BUDGET.to_i64).to_i
      end

      # The first send-only argument given, refused without send:true as the CLI refuses its
      # flags: ignored, they read like they took effect.
      private def graphql_send_only_arg(h, timeout : Time::Span?) : String?
        return "timeout_ms" if timeout
        {"legacy", "allow_unscoped", "insecure"}.find { |k| bool_arg(h, k, false) }
      end

      # The introspection result from the endpoint `detail` captured, with the scope verdict and
      # the response status — or the Result to return as-is.
      private def graphql_fetch(detail : Store::FlowDetail, legacy : Bool, allow_unscoped : Bool,
                                verify : Bool, timeout : Time::Span?) : {JSON::Any, ScopeCheck, Int32?} | Result
        ob = outbound(allow_unscoped)
        ob.halt = cancel_signal # a cancel also ends a wait for the project budget
        begin
          opts = Graphql::Schema.plan_options(detail, legacy: legacy, verify: verify, timeout: timeout,
            overrides: HostOverrides.load(store))
          plan = Repeater::Plan.build(opts, ob)
          gate = send_gate(ob, plan)
          return gate if gate.is_a?(Result)
          # The budget's slot before the wire pass, as `send_request` takes it.
          if reason = plan.admit(cancel_signal)
            return err("request cancelled", "CANCELLED") if cancelled?
            return budget_refused(reason)
          end
          result = plan.send_wire(plan.wire_bytes, cancel_signal, admitted: true)
          return err("request cancelled", "CANCELLED") if cancelled?
          status = result.response.try(&.status)
          answered = graphql_answer(result, status, legacy)
          return answered if answered.is_a?(Result)
          {answered, gate, status}
        rescue ex : Repeater::PlanError
          send_plan_error(ex, "flow_id")
        rescue ex : Gori::Error
          err("flow #{detail.row.id} cannot be rewritten into an introspection query: #{ex.message}", "INVALID_ARGUMENT", field: "flow_id")
        ensure
          ob.close
        end
      end

      # The schema in one introspection send's result, or why there is none.
      private def graphql_answer(result : Repeater::Result, status : Int32?, legacy : Bool) : JSON::Any | Result
        if e = result.error
          return err("introspection request failed: #{e}", "NETWORK_ERROR", field: "flow_id", retryable: true)
        end
        # A body cut short (closed early, or past the read cap) is no schema, and no reason to
        # suggest the legacy query: say what happened instead of "not JSON".
        if result.incomplete?
          return err("the endpoint's response was cut short (closed early or past the read cap, status " \
                     "#{status || "?"}), so the schema is incomplete", "INTROSPECTION_FAILED", field: "flow_id")
        end
        parsed = Graphql::Schema.parse(result.head, result.body)
        return parsed unless parsed.is_a?(String)
        hint = legacy || !Graphql::Schema.rejected?(parsed) ? "" : " (an older server may take legacy:true)"
        err("the endpoint did not return a schema (status #{status || "?"}): #{parsed}#{hint}",
          "INTROSPECTION_FAILED", field: "flow_id")
      end

      private def list_graphql_tools(j : JSON::Builder) : Nil
        tool j, "graphql_schema",
          "A GraphQL endpoint's schema as compact SDL: root operations with args and return " \
          "types, then the types reachable from them (builtins omitted). Reads a flow whose " \
          "response is an introspection result; send:true instead re-sends the flow's request " \
          "rewritten as the introspection query (ACTIVE, scope-gated, same headers)." do |s|
          s.field "flow_id", intprop("captured GraphQL flow (its response, or its request with send:true)"), required: true
          s.field "filter", strprop("case-insensitive name filter: root fields, and types by name or field name")
          s.field "max_bytes", intprop("cap on the sdl text (default and max 65536)")
          s.field "send", boolprop("re-send the request as an introspection query (ACTIVE)")
          s.field "legacy", boolprop("send:true only: the query without subscriptionType/directives, for an older server")
          s.field "insecure", boolprop("send:true only: skip upstream TLS verification")
          s.field "timeout_ms", intprop("send:true only: connect + idle timeout (ms)")
          s.field "allow_unscoped", boolprop("send:true only: send outside the configured scope, or when none is configured (else refused)")
        end
      end
    end
  end
end
