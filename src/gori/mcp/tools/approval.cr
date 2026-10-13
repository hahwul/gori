require "json"
require "digest/sha256"
require "../../store"
require "../../outbound"

module Gori
  module MCP
    class Tools
      # #1585: a Preferences group in `ask` is served, and each call in it waits on the
      # operator's approval — a card in the TUI, the `ask_operator` card with gori's own facts
      # on it. The server runs one call at a time (`Server`), so nothing here waits: the call
      # returns APPROVAL_PENDING at once, the answer reaches the agent as an operator message
      # with `in_reply_to` set to the approval id, and the agent retries the SAME call, which
      # reads the answer from the store (`settle_approvals`).
      #
      # Two places ask. A `send` tool that gates its target through `Outbound` asks per HOST at
      # Layer 1 (`agent_outbound` → `Outbound::Approval`, answered in `scope_blocked`), so a
      # grant can name the host; every other call asks here, per call, before dispatch.
      APPROVAL_ONCE      = "Allow once"
      APPROVAL_HOST      = "Always this host"
      APPROVAL_HOST_PORT = "Always host:port"
      APPROVAL_ALWAYS    = "Always (this server)"
      APPROVAL_DENY      = "Deny"

      # The `send` tools whose every target passes `Outbound#check` and, when held, comes back
      # through `scope_blocked` before a byte goes out: they ask per host. Any other send tool
      # asks per call, so a tool missing here still asks, only without a host to grant.
      # `discover_start` is per call on purpose: a crawl reaches more than its seed, and its
      # plan reads a waiver off `Outbound#reason`, which a held waiver does not set.
      HOST_APPROVED_TOOLS = Set{"send_request", "race_requests", "timing_requests", "send_websocket",
                                "fuzz_start", "mine_start", "sequence_start",
                                "minimize_repeater", "cache_deception_check", "grpc_reflect"}

      # Calls that follow up on something an approval already started, and never ask: the
      # read-only pollers, and stopping a job or a listener — refusing a stop until the
      # operator answers would be the wrong way round.
      APPROVAL_FREE_TOOLS = Set{"stop_job", "oast_poll", "oast_payload", "oast_release"} +
                            TOOL_NAMES.select(&.ends_with?("_stop")).to_set

      # One approval this server put to the operator: the call it holds, the groups it asks
      # for, and the host:port for a per-host one.
      record PendingApproval, id : Int64, tool : String, digest : String, groups : Array(String),
        host : String?, port : Int32?, expires_at : Int64

      @asked_permissions = Set(String).new
      @approvals = {} of Int64 => PendingApproval
      # Answers waiting for their retry, by (tool, args digest): the groups an "Allow once"
      # grants that call, the host:port one on a host card grants it (never the whole group:
      # the same arguments can dial elsewhere next time, through an env var or an edited
      # repeater), and the calls a "Deny" refuses once. Per project: cleared on a rebind.
      @once_grants = {} of {String, String} => Set(String)
      @once_hosts = {} of {String, String} => Set(String)
      @deny_once = Set({String, String}).new
      # "Always (this server)": memory only, so it ends with this process.
      @always_groups = Set(String).new
      # For the call in flight: its digest, and the groups an "Allow once" lifted for it.
      @calling_digest = nil.as(String?)
      @call_approved = Set(String).new
      @call_hosts = Set(String).new

      # The groups in `ask` on this server, in Preferences order — for `instructions`.
      def asked_groups : Array(Settings::McpPermission)
        Settings.mcp_permission_groups(@asked_permissions)
      end

      # The groups that still ask for the call in flight.
      private def approval_asks : Set(String)
        @asked_permissions - @always_groups - @call_approved
      end

      # The per-call half, from `call` just before dispatch: nil to run the call, or the
      # refusal / APPROVAL_PENDING to return instead.
      private def approval_gate(name : String, h) : Result?
        return nil if @asked_permissions.empty?
        digest = call_digest(name, h)
        @calling_digest = digest
        settle_approvals
        key = {name, digest}
        return approval_denied(name) if @deny_once.delete(key)
        @call_approved = @once_grants.delete(key) || Set(String).new
        @call_hosts = @once_hosts.delete(key) || Set(String).new
        return nil if APPROVAL_FREE_TOOLS.includes?(name) || READ_ONLY_TOOLS.includes?(name)
        groups = call_approval_groups(name, h)
        groups.empty? ? nil : pending_approval(groups)
      end

      # The groups this call asks for before dispatch. A per-host tool leaves `send`, and its
      # waiver, to Layer 1.
      private def call_approval_groups(name : String, h) : Array(String)
        asks = approval_asks
        per_host = HOST_APPROVED_TOOLS.includes?(name)
        groups = [] of String
        if (g = call_permission(name, h, asks)) && !(g == "send" && per_host)
          groups << g
        end
        # `unknown_args` already refused the flag on a tool that does not take it.
        waives = !per_host && bool_arg(h, "allow_unscoped", false)
        groups << "scope" if waives && asks.includes?("scope") && !groups.includes?("scope")
        groups
      end

      # `exec`'s half: asked from `exec_refusal`, inside the handler that is about to accept a
      # command.
      private def exec_approval : Result?
        approval_asks.includes?("exec") ? pending_approval(["exec"]) : nil
      end

      # A Layer-1 refusal the operator could lift (`Outbound::Verdict#pending`), from
      # `scope_blocked`.
      private def host_approval(sc : ScopeCheck) : Result
        groups = sc.pending == Outbound::PENDING_WAIVER ? ["scope"] : [] of String
        groups << "send" if approval_asks.includes?("send")
        pending_approval(groups, sc.host.downcase, sc.port)
      end

      # Hand the operator a card for the call in flight, or the open one already asking for
      # it, and answer APPROVAL_PENDING.
      private def pending_approval(groups : Array(String), host : String? = nil, port : Int32? = nil) : Result
        tool = @calling || ""
        digest = @calling_digest || ""
        key = {tool, digest}
        # This call did not run, so what an "Allow once" already lifted for it waits for the
        # retry beside the new answer (a `write` card, then an `exec` one, for one rule).
        (@once_grants[key] ||= Set(String).new).concat(@call_approved) unless @call_approved.empty?
        (@once_hosts[key] ||= Set(String).new).concat(@call_hosts) unless @call_hosts.empty?
        titles = Settings.mcp_permission_groups(groups).join(", ", &.title)
        st = @store
        unless st && @allow_actions && !st.read_only?
          return err("this '#{tool}' call needs the operator's approval (\"#{titles}\" is set to ask in gori " \
                     "Preferences › AI › MCP permissions), but this server has no writable project to put " \
                     "the approval card on", "TOOL_DISABLED")
        end
        now = Time.utc.to_unix_ms * 1000
        approval = @approvals.each_value.find { |a| a.tool == tool && a.digest == digest && a.expires_at > now } ||
                   approval_card(st, PendingApproval.new(0_i64, tool, digest, groups, host, port, 0_i64), titles, now)
        return approval if approval.is_a?(Result)
        err("this '#{tool}' call is waiting for the operator's approval in gori (approval id #{approval.id}; " \
            "\"#{titles}\" is set to ask). Do not wait on it: carry on, and when the operator's answer arrives " \
            "as an operator message with in_reply_to = #{approval.id}, retry this same call unchanged.",
          "APPROVAL_PENDING", retryable: true, details: approval_details(approval))
      end

      private def approval_details(a : PendingApproval) : JSON::Any
        JSON.parse({"approval_id" => a.id, "expires_at" => a.expires_at, "expires_at_iso" => Gori.iso_micros(a.expires_at),
                    "key" => a.groups.join(","), "host" => a.host, "port" => a.port}.compact.to_json)
      end

      # Write the card for `want` (its id and expiry not yet set) and track it, or the refusal.
      private def approval_card(st : Store, want : PendingApproval, titles : String, now : Int64) : PendingApproval | Result
        expires_at = (Time.utc + AgentQuestion::EXPIRES_DEFAULT_MINUTES.minutes).to_unix_ms * 1000
        host, port, tool = want.host, want.port, want.tool
        target = host ? " to #{host}#{":#{port}" if port}" : ""
        question = "Allow #{tool}#{target}?"
        detail = "#{session_label} asked gori mcp to run #{tool}#{target}. #{titles} is set to ask in " \
                 "Preferences › AI › MCP permissions."
        # Every per-host tool passes the dialled port, so a host card always offers host:port.
        choices = host ? [APPROVAL_ONCE, APPROVAL_HOST, APPROVAL_HOST_PORT, APPROVAL_DENY] : [APPROVAL_ONCE, APPROVAL_ALWAYS, APPROVAL_DENY]
        label = session_label
        pid = Process.pid.to_i64
        id = st.record_agent_question(question, detail, choices, APPROVAL_DENY, label, pid, expires_at, approval: true)
        return busy("the approval card for '#{tool}' was not written (project busy or unwritable); retry the call") if id <= 0
        # Expired by the courier like an `ask_operator` question, so the agent hears it.
        @asked_questions[{question_key, id}] = AgentQuestion.new(id, question, nil, choices, APPROVAL_DENY,
          label, pid, expires_at, now, approval: true)
        @approvals[id] = want.copy_with(id: id, expires_at: expires_at)
      end

      private def approval_denied(name : String) : Result
        err("the operator denied this '#{name}' call in gori. Do not retry it unless they ask you to; a retry " \
            "puts the question to them again.", "TOOL_DISABLED")
      end

      # Read the operator's answers to this server's open approvals and turn each into the
      # grant its retry will find. Never waits: an approval nobody answered stays open until
      # it expires, and an expired one is dropped, so its next retry asks again.
      private def settle_approvals : Nil
        return if @approvals.empty?
        return unless st = @store
        now = Time.utc.to_unix_ms * 1000
        answers = st.agent_question_answers(@approvals.keys)
        @approvals.values.each do |a|
          m = answers[a.id]?
          unless m
            @approvals.delete(a.id) if a.expires_at <= now
            next
          end
          @approvals.delete(a.id)
          key = {a.tool, a.digest}
          answer = m.outcome == AgentQuestion::OUTCOME_ANSWERED ? m.text : APPROVAL_DENY
          case answer
          when APPROVAL_ONCE   then allow_once(key, a)
          when APPROVAL_ALWAYS then @always_groups.concat(a.groups)
          when APPROVAL_HOST
            grant_host(st, key, a, a.host)
          when APPROVAL_HOST_PORT
            grant_host(st, key, a, a.host.try { |h| "#{h}:#{a.port}" })
          else @deny_once << key
          end
        end
      end

      # A host grant, persisted for the project. One that did not commit still lets the call
      # it answered run once, rather than turning the operator's yes into a second question.
      private def grant_host(st : Store, key : {String, String}, a : PendingApproval, grant : String?) : Nil
        return unless grant
        ok = st.add_mcp_host_grant(grant)
        allow_once(key, a) unless ok
      end

      private def allow_once(key : {String, String}, a : PendingApproval) : Nil
        if h = a.host
          (@once_hosts[key] ||= Set(String).new) << "#{h}:#{a.port}"
        else
          (@once_grants[key] ||= Set(String).new).concat(a.groups)
        end
      end

      # A host override now repoints `host` (#1585): an "Allow once" for it, and a card still
      # open for it, named the server it dialled before. Its persisted grants are dropped by
      # `HostOverrides`; these live only here. A dropped card's answer is never read, so the
      # retry asks again, under the new override.
      private def forget_host_approvals(host : String) : Nil
        key = OverrideHost.key(host)
        names = ->(g : String) { OverrideHost.key(Store.grant_host(g)) == key }
        @once_hosts.each_value { |set| set.subtract(set.select(&names)) }
        @approvals.reject! { |_, a| a.host.try(&names) || false }
      end

      # A rebind to another project: an answer given there is not one for this project.
      def forget_approvals : Nil
        @approvals.clear
        @once_grants.clear
        @once_hosts.clear
        @deny_once.clear
      end

      # The tool and its arguments, with object keys sorted so a retry that spells the same
      # call in another key order is the same call.
      private def call_digest(name : String, h : Hash(String, JSON::Any)) : String
        canonical = JSON.build do |j|
          j.array do
            j.string name
            canonical_json(JSON::Any.new(h), j)
          end
        end
        Digest::SHA256.hexdigest(canonical)
      end

      private def canonical_json(v : JSON::Any, j : JSON::Builder) : Nil
        if o = v.as_h?
          j.object { o.keys.sort!.each { |k| j.field(k) { canonical_json(o[k], j) } } }
        elsif a = v.as_a?
          j.array { a.each { |x| canonical_json(x, j) } }
        else
          v.to_json(j)
        end
      end

      # The `Outbound::Approval` an agent send is held to, or nil when nothing asks.
      private def outbound_approval(allow_unscoped : Bool) : Outbound::Approval?
        asks = approval_asks
        waiver = allow_unscoped && asks.includes?("scope")
        every = asks.includes?("send")
        return nil unless waiver || every
        Outbound::Approval.new(every_send: every, waiver: waiver, hosts: (@store.try(&.mcp_host_grants) || [] of String) + @call_hosts.to_a)
      end
    end
  end
end
