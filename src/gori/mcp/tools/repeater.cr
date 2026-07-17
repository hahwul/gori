require "json"
require "../../env"
require "../../store"

module Gori
  module MCP
    class Tools
      private def create_repeater(h) : Result
        issue_id = int(h, "issue_id")
        return Result.new(id_error(h, "issue_id"), is_error: true) if issue_id.nil? && present?(h, "issue_id")
        flow_id = int(h, "flow_id")
        return Result.new(id_error(h, "flow_id"), is_error: true) if flow_id.nil? && present?(h, "flow_id")

        target = str(h, "target")
        request = str(h, "request")

        if issue_id
          issue = @store.get_issue(issue_id)
          return not_found("no issue with id #{issue_id}") unless issue
          if fid = issue.flow_id
            flow_id = fid
          elsif target.nil? || target.empty? || request.nil? || request.empty?
            return Result.new("issue #{issue_id} has no associated flow_id", is_error: true)
          end
        end

        http2_val = bool(h, "http2")
        http2 = http2_val || false
        auto_cl_val = bool(h, "auto_content_length")
        auto_cl = (auto_cl_val.nil? && !present?(h, "auto_content_length")) ? true : !!auto_cl_val
        ws_messages_override = nil.as(Array(String)?)

        if flow_id
          flow = @store.get_flow(flow_id)
          return not_found("no flow with id #{flow_id}") unless flow

          if target.nil? || target.empty?
            scheme = flow.row.scheme
            host = flow.row.host
            port = flow.row.port
            default_port = (scheme == "https" ? 443 : 80)
            target = port == default_port ? "#{scheme}://#{host}" : "#{scheme}://#{host}:#{port}"
          end

          if request.nil? || request.empty?
            req_str = String.new(flow.request_head)
            if body = flow.request_body
              req_str += String.new(body)
            end
            request = req_str
          end

          if http2_val.nil?
            http2 = (flow.http_version == "HTTP/2")
          end

          if flow.row.status == 101 && !present?(h, "ws_out_messages")
            ws_messages_override = @store.ws_messages(flow_id).select { |m| m.direction == "out" && m.text? }.map { |m| String.new(m.payload).scrub }
          end
        end

        return Result.new("missing required 'target'", is_error: true) if target.nil? || target.empty?
        return Result.new("missing required 'request'", is_error: true) if request.nil? || request.empty?

        sni = str(h, "sni")

        position = int(h, "position")
        if position.nil?
          return Result.new(id_error(h, "position"), is_error: true) if present?(h, "position") # present but non-integer
          position = @store.repeaters_meta.size.to_i64
        elsif position < Int32::MIN || position > Int32::MAX
          return Result.new("'position' out of range", is_error: true)
        end

        # Apply Env.mask_secrets
        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        masked_sni = sni.try { |s| Env.mask_secrets(s) }
        name = str(h, "name").try { |n| Env.mask_secrets(n) }

        # WebSocket mode check
        is_ws = Repeater::WsEngine.upgrade_request?(masked_request)

        id = @store.insert_repeater(
          target: masked_target,
          request: masked_request,
          http2: http2,
          auto_cl: auto_cl,
          flow_id: flow_id,
          position: position.to_i32,
          sni: masked_sni
        )

        return busy("failed to persist repeater (store busy or unwritable)") if id == 0

        if issue_id
          @store.add_link(Store::LinkOwnerKind::Issue, issue_id,
            Store::LinkRefKind::Repeater, id)
        end

        if name && !name.empty?
          @store.set_repeater_name(id, name)
        end

        # WebSocket messages handling
        if is_ws
          messages = [] of String
          if present?(h, "ws_out_messages")
            if arr = h["ws_out_messages"]?.try(&.as_a?)
              messages = arr.compact_map(&.as_s?)
            elsif str_val = str(h, "ws_out_messages")
              messages = str_val.split('\n').compact_map { |l| l.strip.empty? ? nil : l }
            end
          elsif ws_messages_override
            messages = ws_messages_override
          end

          unless messages.empty?
            @store.update_repeater_ws_messages(id, messages)
          end
        end

        # Derive summary from the MASKED request — the raw request may carry a secret
        # in the request-target (e.g. ?token=…), and this field is returned to the LLM.
        line = masked_request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", position
          end
        })
      end

      private def update_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = @store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless existing

        target = str(h, "target") || existing.target
        request = str(h, "request") || existing.request
        # An explicitly-passed empty string is truthy in Crystal, so guard it here to
        # mirror create_repeater's invariant — a blank target/request can't be sent.
        return Result.new("target must not be empty", is_error: true) if target.empty?
        return Result.new("request must not be empty", is_error: true) if request.empty?

        http2 = if present?(h, "http2")
                  bool(h, "http2") || false
                else
                  existing.http2?
                end

        auto_cl = if present?(h, "auto_content_length")
                    bool(h, "auto_content_length") || false
                  else
                    existing.auto_content_length?
                  end

        sni = present?(h, "sni") ? str(h, "sni") : existing.sni

        masked_target = Env.mask_secrets(target)
        masked_request = Env.mask_secrets(request)
        masked_sni = sni.try { |s| Env.mask_secrets(s) }
        name = present?(h, "name") ? str(h, "name").try { |n| Env.mask_secrets(n) } : existing.name

        @store.update_repeater(
          id: id,
          target: masked_target,
          request: masked_request,
          http2: http2,
          auto_cl: auto_cl,
          sni: masked_sni
        )

        if present?(h, "name")
          @store.set_repeater_name(id, name)
        end

        # WebSocket messages handling
        if present?(h, "ws_out_messages")
          messages = [] of String
          if arr = h["ws_out_messages"]?.try(&.as_a?)
            messages = arr.compact_map(&.as_s?)
          elsif str_val = str(h, "ws_out_messages")
            messages = str_val.split('\n').compact_map { |l| l.strip.empty? ? nil : l }
          end

          @store.update_repeater_ws_messages(id, messages)
        end

        # Derive summary
        line = request.each_line.first?.try(&.strip) || ""
        parts = line.split(' ')
        s = "#{parts[0]?} #{parts[1]?}".strip
        s = line if s.empty?
        summary = s.size > 80 ? "#{s[0, 79]}…" : s

        Result.new(JSON.build { |j|
          j.object do
            j.field "id", id
            j.field "name", name || ""
            j.field "target", masked_target
            j.field "summary", summary
            j.field "position", existing.position
          end
        })
      end

      private def delete_repeater(h) : Result
        id = int(h, "id")
        return Result.new("missing or invalid required 'id'", is_error: true) unless id

        existing = @store.get_repeater(id)
        return not_found("no repeater with id #{id}") unless existing

        @store.delete_repeater(id)
        Result.new(JSON.build { |j| j.object { j.field "success", true } })
      end
    end
  end
end
