require "json"
require "../../protobuf/reflection"
require "../../protobuf/schemas"
require "../../discover/url"

module Gori
  module MCP
    class Tools
      # --- gRPC schema: server reflection + what is loaded (#823/#827) ----------
      #
      # `grpc_reflect` is an ACTIVE tool: it opens one h2 connection per discovery round to
      # the target and asks its reflection service for descriptors. It therefore sits behind
      # the same two gates every other active tool does — `gated` (an MCP server started
      # `--read-only` has no active tools at all) and `Outbound.agent`, whose Layer 1 refuses
      # anything the project scope does not explicitly include unless the caller passes
      # `allow_unscoped:true`. Neither is advisory: no socket is opened before both answer.
      #
      # It never fires on its own. An agent reading a captured gRPC flow gets the schema-less
      # tree (or a file-loaded lens) until it asks for this, which is P4 in the one place an
      # agent could most easily be surprised by an outbound request.

      private def grpc_reflect(h) : Result
        raw = str(h, "url")
        return err("missing required 'url'", "INVALID_ARGUMENT", field: "url") if raw.nil? || raw.empty?
        parts = Gori::Discover::Url.parse(raw)
        return err("'#{raw}' is not an http(s) URL with a host", "INVALID_ARGUMENT", field: "url") unless parts

        ob = outbound(bool_arg(h, "allow_unscoped", false))
        client = Gori::Protobuf::Reflection::Client.new(ob,
          scheme: parts.scheme, host: parts.host, port: parts.port,
          verify: !bool_arg(h, "insecure", false) && @verify_upstream,
          timeout: reflect_timeout(h),
          overrides: Gori::HostOverrides.load(store))
        # Layer 1, read through the client so this surface and the gate cannot disagree about
        # WHICH paths are asked about (both, see `Client#blocked_verdict`) — and read here so
        # the refusal carries MCP's own SCOPE_BLOCKED shape, whose remedy names
        # `allow_unscoped:true`. `fetch` re-checks both layers regardless, so this is the
        # message, not the gate.
        if blocked = client.blocked_verdict
          return scope_blocked(blocked)
        end
        # The in-scope verdict that rides on the result, for the audit trail.
        sc = ob.check_request(parts.scheme, parts.host,
          Gori::Protobuf::Reflection.path(Gori::Protobuf::Reflection::SERVICE_V1), parts.port)
        outcome = client.fetch

        if outcome.refused?
          # Layer 1 already answered above, so anything refused HERE is Layer 2 — Sandbox,
          # which `allow_unscoped` deliberately does not lift, so the remedy must not offer
          # the flag. Same split `send_request` draws.
          return sandbox_blocked(outcome.error || "refused", parts.host, "url")
        end
        if err_text = outcome.error
          # Two different failures, and an agent acts on them differently. A CONNECTION that
          # did not come up says nothing about the target's reflection service and may well
          # work on the next try; a service that answered UNIMPLEMENTED (or NOT_FOUND, or
          # "no descriptors") is a stable answer, and re-asking spends a request for a
          # sentence that is already fixed.
          code = outcome.transport? ? "NETWORK_ERROR" : "REFLECTION_FAILED"
          return err(err_text, code, field: "url", retryable: outcome.transport?,
            details: JSON.parse({"target" => client.target, "service" => outcome.service}.to_json))
        end

        set = outcome.descriptor_set
        saved = false
        if set && outcome.ok?
          saved = Gori::Protobuf::Schemas.adopt(store, client.target, outcome.service,
            outcome.services.size, outcome.files, set)
        end
        Result.new(JSON.build do |j|
          j.object do
            j.field "target", client.target
            j.field "service", outcome.service
            j.field "version", outcome.version
            j.field "files", outcome.files
            # false means the write did not commit (another gori holds the writer). The lens
            # is live in THIS process either way; it will not survive a reopen.
            j.field "persisted", saved
            j.field "services" { j.array { outcome.services.each { |s| j.string s } } }
            j.field "notes" { j.array { outcome.notes.each { |n| j.string n } } }
            j.field "schema", Gori::Protobuf::Schemas.status
            emit_scope(j, sc)
          end
        end)
      end

      # Read-only: what schema this project has loaded and where each piece came from.
      # No network, no gate — a file path and a cache row.
      private def grpc_schema(h) : Result
        reflections = store.grpc_reflections
        Result.new(JSON.build do |j|
          j.object do
            j.field "spec", Gori::Protobuf::Schemas.spec
            j.field "status", Gori::Protobuf::Schemas.status
            j.field "sources" do
              j.array do
                Gori::Protobuf::Schemas.sources.each do |src|
                  j.object do
                    j.field "origin", src.origin.to_s.downcase
                    j.field "path", src.path
                    j.field "messages", src.messages
                    j.field "methods", src.methods
                    j.field "error", src.error
                  end
                end
              end
            end
            j.field "reflections" do
              j.array do
                reflections.each do |r|
                  j.object do
                    j.field "target", r.target
                    j.field "service", r.service
                    j.field "fetched_at", r.fetched_at
                    j.field "services", r.services
                    j.field "files", r.files
                    j.field "bytes", r.descriptor.size
                  end
                end
              end
            end
          end
        end)
      end

      # Drop one cached reflection target (or all of them). The operator's/agent's exit from
      # a schema fetched earlier — nothing here expires on its own.
      private def grpc_forget(h) : Result
        target = str(h, "target")
        all = bool_arg(h, "all", false)
        if all
          return err("pass 'target' or all:true, not both", "INVALID_ARGUMENT", field: "target") if target && !target.empty?
        else
          return err("missing required 'target' (or all:true)", "INVALID_ARGUMENT", field: "target") if target.nil? || target.empty?
        end
        known = store.grpc_reflections.map(&.target)
        if (t = target) && !all && !known.includes?(t)
          return not_found("no cached reflection for '#{t}'")
        end
        committed = Gori::Protobuf::Schemas.forget(store, all ? nil : target)
        Result.new(JSON.build do |j|
          j.object do
            j.field "forgotten", all ? known.size : 1
            j.field "persisted", committed
            j.field "schema", Gori::Protobuf::Schemas.status
          end
        end)
      end

      # Per-operation timeout in milliseconds, or nil for the project's io timeout. Clamped
      # the way every other MCP timeout is: a caller cannot hold this server's fiber for an
      # arbitrary span.
      private def reflect_timeout(h) : Time::Span?
        optional_int_arg(h, "timeout_ms").try(&.clamp(1_i64, 600_000_i64).milliseconds)
      end

      private def list_grpc_tools(j : JSON::Builder) : Nil
        # READ-ONLY tools first: they stay available on a `--read-only` server, because
        # naming the schema a body was rendered through is part of reading the body.
        tool j, "grpc_schema",
          "What .proto schema this project renders captured gRPC through, and where each piece " \
          "came from — a descriptor-set FILE (Project settings → Proto schema) or a server " \
          "REFLECTION fetch against a target. Read-only; sends nothing." do |_s|
        end

        return unless @allow_actions

        tool j, "grpc_reflect",
          "Ask a gRPC target's server-reflection service (grpc.reflection.v1, falling back to " \
          "v1alpha) for its descriptors, and cache them in the project so every flow on that " \
          "target renders as named, typed fields instead of the schema-less 'every reading that " \
          "fits' tree. ACTIVE: opens a real h2 connection to the target — one per discovery " \
          "round (list_services, then the symbols, then their imports). Nothing re-fetches on " \
          "its own; run this again to refresh, grpc_forget to drop it. The raw wire bytes stay " \
          "authoritative: an undeclared field number is still shown, and a schema/wire " \
          "disagreement is reported as a disagreement." do |s|
          s.field "url", strprop("target origin, e.g. https://api.test:443 (the path is ignored)"), required: true
          s.field "insecure", boolprop("skip upstream TLS verification (default false)")
          s.field "timeout_ms", intprop("per-operation connect + idle timeout in ms (default: the project's io timeout)")
          s.field "allow_unscoped", boolprop("reflect even when the target host is outside the project's configured scope — REQUIRED for an out-of-scope target, or when no scope is configured")
        end

        tool j, "grpc_forget",
          "Drop a cached reflection result, by target (as grpc_schema prints it) or all:true. " \
          "A descriptor-set FILE is unloaded by clearing the path in Project settings instead." do |s|
          s.field "target", strprop("scheme://host:port, as grpc_schema reports it")
          s.field "all", boolprop("forget every cached reflection target")
        end
      end
    end
  end
end
