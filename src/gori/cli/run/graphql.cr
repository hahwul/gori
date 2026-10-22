require "../../graphql/schema"
require "../../host_overrides"

# `gori run graphql schema` — a GraphQL endpoint's schema as compact SDL, the headless
# counterpart of MCP `graphql_schema`. It reads a captured flow whose response already is an
# introspection result; `--send` instead re-sends the flow's request rewritten into the
# introspection query, through the same scope gate `gori run repeater send` uses (ACTIVE).
module Gori
  module CLI
    module Run
      @[Subcommand("graphql", help: [
        {"graphql schema <flow-id>", "A GraphQL schema as compact SDL, from a captured introspection result (or --send)"},
      ])]
      private def self.cmd_graphql(args : Array(String)) : Nil
        case sub = args.first?
        when "schema" then cmd_graphql_schema(args[1..])
        else               abort "gori run graphql: #{sub ? "unknown subcommand '#{sub}'" : "a subcommand is required"} (schema)"
        end
      end

      private def self.cmd_graphql_schema(args : Array(String)) : Nil
        prefix = "gori run graphql schema"
        proj = ProjectFlags.new
        send = false
        legacy = false
        filter : String? = nil
        max_bytes = 64 * 1024
        allow_unscoped = false
        insecure = false
        timeout : Time::Span? = nil
        format = :text

        id = one_positional(args, prefix, "flow id") do |p|
          p.banner = "Usage: gori run graphql schema <flow-id> [options]\n\n" \
                     "Print a GraphQL schema as compact SDL: the root operations with their arguments\n" \
                     "and return types, then every type reachable from them (builtins omitted).\n" \
                     "The flow's response must already be an introspection result, unless --send\n" \
                     "re-sends the flow's request rewritten into the introspection query (ACTIVE,\n" \
                     "scope-gated, with the flow's headers)."
          project_options(p, proj, "read")
          p.on("--send", "Re-send the flow's request as an introspection query (ACTIVE)") { send = true }
          p.on("--legacy", "With --send: the query without subscriptionType/directives, for an older server") { legacy = true }
          p.on("--filter=TEXT", "Only root fields, and types, whose name (or a field name) contains TEXT") { |v| filter = v }
          p.on("--max-bytes=N", "Cap on the SDL text (default 65536)") { |v| max_bytes = parse_count(v, "--max-bytes") }
          p.on("--allow-unscoped", "With --send: send even if the target is outside the project scope") { allow_unscoped = true }
          p.on("-k", "--insecure-upstream", "With --send: do not verify the upstream TLS certificate") { insecure = true }
          p.on("--timeout=SECONDS", "With --send: connect + idle timeout") do |v|
            timeout = grpc_timeout(v) || abort("#{prefix}: invalid --timeout '#{v}'")
          end
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
        end
        abort "#{prefix}: a flow id is required" unless id
        flow_id = parse_flow_id(id, prefix)
        refresh_verify_upstream(!insecure)

        project = resolve_read_project(proj.name, proj.db)
        detail, overrides = with_store(project, read_only: true) do |store|
          {store.get_flow(flow_id), Gori::HostOverrides.load(store)}
        end
        abort "#{prefix}: no flow with id #{flow_id}" unless detail

        status = nil.as(Int32?)
        schema =
          if send
            parsed, status = graphql_fetch(prefix, project, detail, legacy, allow_unscoped, !insecure, timeout, overrides)
            parsed
          else
            if detail.response_body_truncated?
              abort "#{prefix}: flow #{flow_id}'s captured response was cut at the capture cap — pass --send to ask the endpoint again"
            end
            parsed = Graphql::Schema.parse(detail.response_head, detail.response_body)
            if parsed.is_a?(String)
              abort "#{prefix}: flow #{flow_id} is not an introspection result: #{CLI::Output.term_line(parsed)} — pass --send to re-send it as one"
            end
            parsed
          end

        s = Graphql::Schema.summarize(schema, filter, max_bytes)
        if format == :json
          puts graphql_schema_json(flow_id, send, status, s)
        else
          STDERR.puts "#{s.types_shown} of #{s.types_total} type(s)#{s.truncated ? " — cut at --max-bytes #{max_bytes}" : ""}"
          puts CLI::Output.term_safe_multiline(s.sdl)
        end
      end

      # `--format json`: the object MCP `graphql_schema` answers with, minus its scope verdict.
      def self.graphql_schema_json(flow_id : Int64, sent : Bool, status : Int32?, s : Graphql::Schema::Summary) : String
        JSON.build do |j|
          j.object do
            j.field "flow_id", flow_id
            j.field "source", sent ? "sent" : "captured"
            j.field "status", status if status
            s.emit(j)
          end
        end
      end

      # The introspection result from the endpoint `detail` captured, and the response status.
      # Aborts on a refusal, a failed send, or an answer that is not a schema.
      private def self.graphql_fetch(prefix : String, project : Project, detail : Store::FlowDetail,
                                     legacy : Bool, allow_unscoped : Bool, verify : Bool,
                                     timeout : Time::Span?, overrides : Gori::HostOverrides?) : {JSON::Any, Int32?}
        outbound = project_outbound(project, allow_unscoped)
        plan = begin
          Repeater::Plan.build(Graphql::Schema.plan_options(detail, legacy: legacy, verify: verify,
            timeout: timeout, overrides: overrides), outbound)
        rescue ex : Repeater::PlanError
          outbound.close
          repeater_plan_abort(prefix, ex)
        rescue ex : Gori::Error
          outbound.close
          abort "#{prefix}: #{ex.message}"
        end
        abort_if_out_of_scope!(outbound, plan, prefix)
        abort_if_blocked!(plan, prefix)
        result = begin
          plan.send
        ensure
          outbound.close
        end
        status = result.response.try(&.status)
        if e = result.error
          abort "#{prefix}: #{CLI::Output.term_line(e)}"
        end
        if result.incomplete?
          abort "#{prefix}: the endpoint's response was cut short (closed early or past the read cap, " \
                "status #{status || "?"}), so the schema is incomplete"
        end
        parsed = Graphql::Schema.parse(result.head, result.body)
        if parsed.is_a?(String)
          abort "#{prefix}: the endpoint did not return a schema (status #{status || "?"}): " \
                "#{CLI::Output.term_line(parsed)}#{legacy ? "" : " — an older server may take --legacy"}"
        end
        {parsed, status}
      end
    end
  end
end
