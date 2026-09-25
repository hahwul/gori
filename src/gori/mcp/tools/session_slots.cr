require "json"
require "../../store"
require "../../session_slots"
require "../../discover/headers"
require "../../session_from_flow"
require "../../session_refresh"

module Gori
  module MCP
    class Tools
      # --- session slots (named identities: a header overlay + a binding namespace) ---
      #
      # The MCP adapter for `Gori::SessionSlots` — the third surface of the list the TUI's
      # Authorize identities card and `gori run session` already edit. One persisted row, three
      # editors: `authorize_start`'s `identities` default is THIS list, and the ACTIVE slot is
      # what `send_request` / `fuzz_start` / `repeater` go out as.
      #
      # Two halves, and they persist differently on purpose (DESIGN.md §7 2026-08-17):
      #
      #   * the LIST is configuration and lives in the project;
      #   * the ACTIVE pointer is per-PROCESS and never written. For this server that means
      #     `set_active_session_slot` holds for the life of the connection and starts over on
      #     the next one — which is the honest lifetime, because a slot's binding VALUES are
      #     memory-only too, and restoring a pointer into an empty table would hand the next
      #     send an overlay whose `$SESSION` is literal.
      #
      # Every handler goes through the LIVE registry (`slot_registry`), never a fresh
      # `SessionSlots.load`: the live object is the one `Env.layer` resolves `$NAME` against
      # and `Env.overlay_slot` applies at the send seam, so a second copy would let this
      # server report an identity it is not actually sending as.

      # The registry `Env.layer` is wired to, so a write here is visible to the very next
      # send. Nil only when the server never bound a project (`bind_binding_layer` is what
      # installs it) — the tools below are not in `UNBOUND_SAFE`, so `call` has already
      # refused by then; the fallback is a compile-time necessity rather than a live path.
      private def slot_registry : Gori::SessionSlots
        @bindings.try(&.slots) || Gori::SessionSlots.load(store)
      end

      # Re-read the persisted list before a read-modify-WRITE. Same reasoning as
      # `ENV_REFRESH_TOOLS`: this surface rewrites the WHOLE list, so acting on a copy made
      # when the server bound would silently delete every slot a TUI or `gori run session add`
      # created since. `reload` keeps the active pointer when the slot it names survived.
      private def fresh_slots : Gori::SessionSlots
        registry = slot_registry
        registry.reload
        registry
      end

      # Header VALUES are [REDACTED] by default — a slot's whole job is carrying a session
      # cookie or a bearer token, and this response can flow through a hosted LLM. The same
      # policy `list_env` states, and the same reason the TUI's identities card renders header
      # NAMES only.
      @[Tool("list_session_slots")]
      private def list_session_slots(h) : Result
        include_sensitive = bool_arg(h, "include_sensitive", false)
        registry = fresh_slots
        active = registry.active_name
        Result.new(JSON.build do |j|
          j.object do
            j.field "active", active
            j.field "active_note", "no slot active — requests go out AS CAPTURED (no header " \
                                   "overlay, global bindings). Pick one with set_active_session_slot." if active.nil?
            j.field("slots") do
              j.array do
                registry.slots.each { |s| emit_session_slot(j, s, include_sensitive, active, refresh_status: true) }
              end
            end
          end
        end)
      end

      @[Tool("create_session_slot", gated: true, agent_action: true)]
      private def create_session_slot(h) : Result
        name = str(h, "name").try(&.strip)
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil? || name.empty?
        registry = fresh_slots
        # Deterministic and un-retryable, so INVALID_ARGUMENT rather than PROJECT_BUSY — the
        # #414 shape: an agent that trusts `retryable` loops forever on a duplicate.
        # Case-INSENSITIVELY (`SessionSlots#name_clash`), which is the comparison Authorize
        # makes: creating both `admin` and `Admin` left every authorize_start in the project
        # refusing with DuplicateIdentity until a human renamed one.
        if taken = registry.name_clash(name)
          return err("a session slot called '#{taken}' already exists (change it with " \
                     "update_session_slot). Names are compared case-insensitively — authorize " \
                     "reads '#{name}' and '#{taken}' as one identity and refuses a set with both",
            "INVALID_ARGUMENT", field: "name")
        end
        built = slot_set_headers_or_flow(h)
        return built if built.is_a?(Result)
        set_headers, sources, literal_headers = built
        refresh = slot_refresh_args(h, [] of Int64, Gori::SessionSlot::RefreshBefore.off)
        return refresh if refresh.is_a?(Result)
        slot = Gori::SessionSlot.new(name, set_headers, str_list(h, "remove_headers").map(&.strip).reject(&.empty?),
          bool_arg(h, "baseline", false), str_list(h, "rules").map(&.strip).reject(&.empty?),
          literal_headers, refresh[0], refresh[1])
        unless registry.add(slot)
          return busy("session slot NOT created (store busy or unwritable); no slot was added")
        end
        # Re-read rather than echo what was built: `SessionSlots` owns the single-baseline
        # rule, so the FIRST slot in a project comes back holding a flag the caller did not
        # ask for — and a reply that denied it would have the agent set it a second time.
        Result.new(JSON.build { |j| emit_session_slot(j, registry.find(slot.name) || slot, false, registry.active_name, sources) })
      end

      # The overlay a `create_session_slot` call asked for, plus one line per SOURCE when it
      # was read off a flow. There are three spellings and they are exclusive: `set_headers` is
      # the caller dictating the overlay, `flow_id` builds it from a captured login response,
      # and `from_request_flow_id` + `copy_headers` copies selected headers from a captured
      # request. Both flow forms use `Gori::SessionFromFlow`, so the surfaces cannot build
      # different identities from one flow.
      #
      # Passing both is refused rather than merged: an agent that sent both has one of the two
      # in mind, and silently picking either is how it ends up sending a credential it did not
      # choose.
      private def slot_set_headers_or_flow(h) : {Array({String, String}), Array(String), Array(String)} | Result
        has_response_flow = present?(h, "flow_id")
        has_request_flow = present?(h, "from_request_flow_id")
        has_copy_headers = present?(h, "copy_headers")
        has_set_headers = present?(h, "set_headers")
        if conflict = slot_source_conflict(has_response_flow, has_request_flow, has_copy_headers, has_set_headers)
          return conflict
        end
        return slot_request_flow(h) if has_request_flow
        slot_response_or_manual(h)
      end

      private def slot_source_conflict(response_flow : Bool, request_flow : Bool,
                                       copy_headers : Bool, set_headers : Bool) : Result?
        return err("pass either 'from_request_flow_id' or 'flow_id', not both — the former " \
                   "copies request headers and the latter builds an overlay from the response",
          "INVALID_ARGUMENT", field: "from_request_flow_id") if request_flow && response_flow
        return err("pass either 'copy_headers' with 'from_request_flow_id' or 'flow_id', not both",
          "INVALID_ARGUMENT", field: "copy_headers") if copy_headers && response_flow
        return err("pass either 'from_request_flow_id' with 'copy_headers' or 'set_headers', not both",
          "INVALID_ARGUMENT", field: "set_headers") if request_flow && set_headers
        return err("pass either 'copy_headers' with 'from_request_flow_id' or 'set_headers', not both",
          "INVALID_ARGUMENT", field: "copy_headers") if copy_headers && set_headers
        return err("'from_request_flow_id' and 'copy_headers' must be supplied together",
          "INVALID_ARGUMENT", field: request_flow ? "copy_headers" : "from_request_flow_id") if request_flow != copy_headers
        nil
      end

      private def slot_request_flow(h) : {Array({String, String}), Array(String), Array(String)} | Result
        flow_id = slot_int_arg(h, "from_request_flow_id")
        return flow_id if flow_id.is_a?(Result)
        return err("'from_request_flow_id' must be an integer", "INVALID_ARGUMENT",
          field: "from_request_flow_id") unless flow_id
        # Preserve blank entries so the shared request-header grammar can refuse the whole
        # selection atomically. Dropping one here would make ["Authorization", ""] succeed
        # with only the first credential, which is a different request than the caller named.
        copy_headers = str_list(h, "copy_headers").map(&.strip)
        detail = store.get_flow(flow_id)
        return not_found("no flow ##{flow_id} in this project (see list_history)") unless detail
        drafted = Gori::SessionFromFlow.draft_request(detail, copy_headers)
        if refusal = drafted.as?(Gori::SessionFromFlow::Refusal)
          # Deterministic: the SAME flow and requested header list refuse the same way next
          # time, so this must not be retryable — the #414 shape again.
          return err("flow ##{flow_id} — #{refusal.message}", refusal.code,
            field: "copy_headers")
        end
        draft = drafted.as(Gori::SessionFromFlow::Draft)
        {draft.set_headers, draft.sources, draft.literal_headers}
      end

      private def slot_response_or_manual(h) : {Array({String, String}), Array(String), Array(String)} | Result
        flow_id = slot_int_arg(h, "flow_id")
        return flow_id if flow_id.is_a?(Result)
        unless flow_id
          headers = session_set_headers(h)
          return headers if headers.is_a?(Result)
          return {headers, [] of String, [] of String}
        end
        if present?(h, "set_headers")
          return err("pass either 'flow_id' or 'set_headers', not both — 'flow_id' BUILDS the " \
                     "overlay from the flow's response",
            "INVALID_ARGUMENT", field: "set_headers")
        end
        detail = store.get_flow(flow_id)
        return not_found("no flow ##{flow_id} in this project (see list_history)") unless detail
        drafted = Gori::SessionFromFlow.draft(detail)
        if refusal = drafted.as?(Gori::SessionFromFlow::Refusal)
          # Deterministic: the SAME flow will refuse the same way next time, so this must not
          # be retryable — the #414 shape again.
          return err("flow ##{flow_id} — #{refusal.message}", refusal.code, field: "flow_id")
        end
        draft = drafted.as(Gori::SessionFromFlow::Draft)
        {draft.set_headers, draft.sources, draft.literal_headers}
      end

      private def slot_int_arg(h, key : String) : Int64? | Result
        optional_int_arg(h, key)
      rescue ex : Gori::Error
        err(ex.message || "invalid '#{key}' (expected an integer)",
          "INVALID_ARGUMENT", field: key)
      end

      # A partial update: an argument left out keeps what the slot already has. That is the
      # shape an agent needs to rotate ONE cookie without having to re-send the rule list it
      # never read (and would blank).
      @[Tool("update_session_slot", gated: true, agent_action: true)]
      private def update_session_slot(h) : Result
        name = str(h, "name").try(&.strip)
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil? || name.empty?
        registry = fresh_slots
        current = registry.find(name)
        return not_found("no session slot named '#{name}' (see list_session_slots)") unless current
        target = update_slot_target(registry, name, h)
        return target if target.is_a?(Result)
        target_name = target[0]
        headers = update_slot_headers(h, current)
        return headers if headers.is_a?(Result)
        set_headers, literal_headers = headers
        refresh = slot_refresh_args(h, current.refresh, current.refresh_before)
        return refresh if refresh.is_a?(Result)
        updated = current.copy_with(name: target_name, set_headers: set_headers,
          remove_headers: slot_names_arg(h, "remove_headers", current.remove_headers),
          baseline: bool_arg(h, "baseline", current.baseline?),
          rules: slot_names_arg(h, "rules", current.rules), literal_headers: literal_headers,
          refresh: refresh[0], refresh_before: refresh[1])
        unless registry.update(name, updated)
          return busy("session slot NOT updated (store busy or unwritable); it is unchanged")
        end
        # Re-read: dropping the baseline hands it to another row (see `create_session_slot`).
        Result.new(JSON.build { |j| emit_session_slot(j, registry.find(updated.name) || updated, false, registry.active_name) })
      end

      private def update_slot_target(registry : Gori::SessionSlots, name : String, h) : {String} | Result
        renamed = (str(h, "new_name").try(&.strip)).presence
        if renamed && renamed != name && (taken = registry.name_clash(renamed, except: name))
          return err("another session slot is already called '#{taken}' (names are compared " \
                     "case-insensitively)", "INVALID_ARGUMENT", field: "new_name")
        end
        {renamed || name}
      end

      private def update_slot_headers(h, current : Gori::SessionSlot) : {Array({String, String}), Array(String)} | Result
        return {current.set_headers, current.literal_headers} unless h.has_key?("set_headers")
        set_headers = session_set_headers(h)
        return set_headers if set_headers.is_a?(Result)
        {set_headers, [] of String}
      end

      @[Tool("delete_session_slot", gated: true, agent_action: true)]
      private def delete_session_slot(h) : Result
        name = str(h, "name").try(&.strip)
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil? || name.empty?
        registry = fresh_slots
        return not_found("no session slot named '#{name}' (see list_session_slots)") unless registry.find(name)
        unless registry.remove(name)
          return busy("session slot NOT deleted (store busy or unwritable); it is unchanged")
        end
        # Deleting the ACTIVE slot deactivates it (`SessionSlots#save`), which is a behaviour
        # change the caller has to see: the next send goes out as captured, not as the slot it
        # last selected.
        Result.new(JSON.build do |j|
          j.object do
            j.field "name", name
            j.field "deleted", true
            j.field "active", registry.active_name
          end
        end)
      end

      # The send context for THIS server process. `name: null` (or omitted) deactivates, which
      # is `as-captured`: no header overlay, `$NAME` out of the global binding table.
      @[Tool("set_active_session_slot", gated: true, agent_action: true)]
      private def set_active_session_slot(h) : Result
        registry = fresh_slots
        raw = str(h, "name").try(&.strip)
        name = (raw.nil? || raw.empty?) ? nil : raw
        unless registry.activate(name)
          known = registry.names
          have = known.empty? ? "this project has no session slots saved" : "it has #{known.join(", ")}"
          return err("no session slot named '#{name}' — #{have}. Create one with create_session_slot",
            "INVALID_ARGUMENT", field: "name")
        end
        slot = registry.active
        Result.new(JSON.build do |j|
          j.object do
            j.field "active", registry.active_name
            j.field "overlay", slot.nil? ? "none — sending as captured" : slot.summary
            # Stated on every activation rather than only in the schema: this is the one fact
            # about the pointer that surprises, and a reconnect silently reverting to
            # as-captured is a send under the wrong identity.
            j.field "note", "the active slot is held by THIS server process and is never " \
                            "persisted — a new connection starts as-captured"
          end
        end)
      end

      # `refresh` (Repeater session ids, in order) and `refresh_before` (`off` | `jwt-exp` |
      # `ttl=10m`), each ABSENT-keeps like the name lists above. Every id must name a Repeater
      # session that exists now: a typo refused here is cheaper than a step that fails at the
      # first automatic refresh in the middle of a sweep. Deterministic, so INVALID_ARGUMENT.
      private def slot_refresh_args(h, ids : Array(Int64),
                                    policy : Gori::SessionSlot::RefreshBefore) : {Array(Int64), Gori::SessionSlot::RefreshBefore} | Result
        if h.has_key?("refresh")
          ids = begin
            id_list_arg(h, "refresh")
          rescue ex : Gori::Error
            return err(ex.message || "invalid 'refresh'", "INVALID_ARGUMENT", field: "refresh")
          end
          if bad = ids.find { |id| id <= 0 || store.get_repeater(id).nil? }
            return err("no Repeater session ##{bad} in this project (see get_repeater_context / " \
                       "create_repeater) — 'refresh' lists the Repeater sessions that re-authenticate " \
                       "the slot, in order", "INVALID_ARGUMENT", field: "refresh")
          end
        end
        if raw = str(h, "refresh_before")
          policy = Gori::SessionSlot::RefreshBefore.parse?(raw) ||
                   return err("'refresh_before' #{raw.inspect} is not a policy — use \"off\", " \
                              "\"jwt-exp\" or \"ttl=<n>[s|m|h]\" (e.g. \"ttl=10m\")",
                     "INVALID_ARGUMENT", field: "refresh_before")
        end
        {ids, policy}
      end

      # Run a slot's refresh steps now (#1233). The values it rebinds live in THIS server
      # process — the same per-process table every other tool here resolves against — and the
      # reply carries binding NAMES, never a value. Every step is recorded in History (source
      # `refresh`) and the outcome in the event log.
      #
      # `allow_unscoped` gates the STEPS, strictly by default (`Outbound.agent`), exactly as it
      # gates `send_request`. A deterministic refusal (no such slot, no steps) is
      # INVALID_ARGUMENT; a refresh that RAN and failed is a normal reply with `ok: false`, since
      # the step's answer is the result the caller asked for.
      @[Tool("refresh_session_slot", gated: true, agent_action: true, env_refresh: true)]
      private def refresh_session_slot(h) : Result
        name = str(h, "name").try(&.strip)
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil? || name.empty?
        registry = fresh_slots
        slot = registry.find(name)
        return not_found("no session slot named '#{name}' (see list_session_slots)") unless slot
        if slot.refresh.empty?
          return err("session slot '#{name}' has no refresh steps — set them with update_session_slot " \
                     "{refresh: [repeater ids, in order]}", "INVALID_ARGUMENT", field: "name")
        end
        runner = @refresher || return err("no project is bound", "INVALID_ARGUMENT")
        outcome = runner.refresh(name, Outbound.agent(Scope.load(store), bool_arg(h, "allow_unscoped", false)))
        Result.new(JSON.build { |j| emit_refresh_outcome(j, outcome) })
      end

      private def emit_refresh_outcome(j : JSON::Builder, o : Gori::SessionRefresh::Outcome) : Nil
        j.object do
          j.field "slot", o.slot
          j.field "ok", o.ok
          j.field "manual", o.manual
          j.field "steps", o.steps
          j.field "failed_step", o.failed_step
          j.field "step", o.step_label
          j.field "status", o.status
          j.field "reason", o.reason
          j.field("rebound") { j.array { o.rebound.each { |n| j.string n } } }
          j.field("flow_ids") { j.array { o.flow_ids.each { |id| j.number id } } }
          j.field "message", o.message
          j.field "at_iso", o.at.to_rfc3339
          j.field "note", "values live in THIS server process only; a TUI or another gori keeps its own"
        end
      end

      # A name-list argument that is ABSENT rather than empty keeps what the slot already has —
      # the difference an agent rotating one cookie depends on, since it never read the rule
      # list it would otherwise blank. An explicit `[]` is a clear.
      private def slot_names_arg(h, key : String, current : Array(String)) : Array(String)
        return current unless h.has_key?(key)
        str_list(h, key).map(&.strip).reject(&.empty?)
      end

      # `set_headers` in either shape a client sends: the `[{name, value}, …]` objects the
      # rest of this surface uses, or `["Name: value", …]` lines. Both go through
      # `Discover::Headers.parse_lines`, the SAME parser the TUI's identity form runs its
      # editor buffer through — a value may not carry CR/LF and a name must be an RFC 7230
      # token, so a slot cannot forge a header boundary into every request it overlays.
      # A rejected line is an ERROR, not a drop: a silently-skipped Cookie is an
      # unauthenticated run that reports "found nothing".
      private def session_set_headers(h) : Array({String, String}) | Result
        raw = h["set_headers"]?
        return [] of {String, String} if raw.nil? || raw.raw.nil?
        lines = [] of String
        if arr = raw.as_a?
          arr.each do |entry|
            if o = entry.as_h?
              # An object entry with no `name` is the OTHER object an agent reaches for — the
              # `{"Cookie": "session=…"}` map, which this surface does not take here. Refused
              # by its own shape rather than folded into `": "`: that empty pair is then what
              # the rejection quotes back, and the caller cannot find in its own call an entry
              # it never wrote.
              # `presence` closes the same hole the guard opens on: an empty or whitespace-only
              # name folds to the very `": value"` this refusal exists to stop quoting back.
              n = o["name"]?.try(&.as_s?).try(&.strip).presence
              unless n
                return err("'set_headers' entry #{entry.to_json} names no header — an object " \
                           "entry is {\"name\": \"Cookie\", \"value\": \"session=…\"}, or pass " \
                           "the line \"Cookie: session=…\" as a string",
                  "INVALID_ARGUMENT", field: "set_headers")
              end
              v = o["value"]?.try(&.as_s?) || ""
              lines << "#{n}: #{v}"
            else
              lines << (entry.as_s? || entry.to_s)
            end
          end
        else
          lines = str_list(h, "set_headers")
        end
        rejected = [] of String
        pairs = Gori::Discover::Headers.parse_lines(lines, rejected)
        if bad = rejected.first?
          return err("'set_headers' entry #{bad.inspect} is not a header — a name must be an " \
                     "RFC 7230 token and a value may not contain CR or LF",
            "INVALID_ARGUMENT", field: "set_headers")
        end
        pairs
      end

      private def emit_session_slot(j : JSON::Builder, slot : Gori::SessionSlot,
                                    include_sensitive : Bool, active : String?,
                                    sources : Array(String) = [] of String,
                                    refresh_status : Bool = false) : Nil
        j.object do
          j.field "name", slot.name
          # Where each header came from, when the overlay was READ off a flow rather than
          # dictated. Provenance only, never a value — this reply can flow through a hosted LLM.
          j.field("sources") { j.array { sources.each { |line| j.string line } } } unless sources.empty?
          j.field "baseline", slot.baseline?
          j.field "active", slot.name == active
          # True = this slot changes no byte; it is the `as-captured` baseline by construction
          # rather than by name, so a caller can find it without matching a string.
          j.field "passthrough", slot.passthrough?
          j.field "summary", slot.summary
          j.field "set_headers" do
            j.array do
              slot.set_headers.each do |(n, v)|
                j.object do
                  j.field "name", n
                  j.field "value", include_sensitive ? v : "[REDACTED]"
                end
              end
            end
          end
          j.field("remove_headers") { j.array { slot.remove_headers.each { |n| j.string n } } }
          j.field("rules") { j.array { slot.rules.each { |n| j.string n } } }
          # The refresh half (#1233). A NEGATIVE id is a step whose Repeater session was
          # deleted — it refuses to run until it is removed.
          j.field("refresh") { j.array { slot.refresh.each { |id| j.number id } } }
          j.field("refresh_steps") { j.array { Gori::SessionRefresh.step_labels(store, slot).each { |l| j.string l } } }
          j.field "refresh_before", slot.refresh_before.to_s
          emit_refresh_status(j, slot) if refresh_status
        end
      end

      # THIS process's refresh state for the slot: refreshing now, the last outcome (names,
      # never values), and whether automatic refresh has switched itself off.
      private def emit_refresh_status(j : JSON::Builder, slot : Gori::SessionSlot) : Nil
        return unless (runner = @refresher) && slot.refreshable?
        st = runner.status(slot.name)
        j.field "refreshing", st.refreshing
        j.field "auto_refresh_off", st.auto_off if st.auto_off
        if last = st.last
          j.field("last_refresh") { emit_refresh_outcome(j, last) }
        end
      end

      # The tools/list schemas for the session-slot tools, kept beside the handlers that
      # implement them. `Tools#list` composes every one of these; the action gate is applied
      # here rather than around one long block, so a new write tool cannot be added on the
      # wrong side of it by landing in the wrong place in a 1,300-line method.
      private def list_session_slots_tools(j : JSON::Builder) : Nil
        tool j, "list_session_slots",
          "List the project's SESSION SLOTS — named identities, each a header overlay (headers to " \
          "set / to strip) plus the extract rules whose bound values belong to it — and which one " \
          "is ACTIVE. The active slot is what send_request/send_websocket/fuzz_start/repeater sends " \
          "go out as; authorize_start replays under the whole list. Header values are [REDACTED] " \
          "by default (a slot carries a session cookie); pass include_sensitive:true to see them." do |s|
          s.field "include_sensitive", boolprop("return actual header values instead of [REDACTED] (default false)")
        end

        return unless @allow_actions

        tool j, "create_session_slot",
          "Create a session slot (a named identity). A slot that sets and strips nothing is " \
          "'as captured' — the no-overlay baseline. Values may reference a binding: " \
          "\"Bearer $BIND.SESSION\" (\"Bearer $SESSION\" under the legacy bare syntax) resolves " \
          "against THIS slot's own table when it claims the rule. " \
          "Pass 'flow_id' instead of 'set_headers' to BUILD the overlay from a captured login " \
          "exchange: gori copies the response's Set-Cookie pairs into one Cookie header and its " \
          "Authorization (or a top-level access_token/token/id_token string in a JSON body, as a " \
          "Bearer token). That overlay is a LITERAL snapshot of the response bytes: it does " \
          "NOT re-authenticate by itself — give the slot 'refresh' steps (Repeater sessions that " \
          "log in) for that. The slot is project-wide and its active overlay " \
          "can affect every outbound request from this server, so consider the blast radius. " \
          "For a token that ROTATES, use the extract-rule path (create_extract_rule) instead. " \
          "Pass 'from_request_flow_id' together with 'copy_headers' to copy selected headers " \
          "from the captured request; that is also a literal snapshot and never auto-reauthenticates." do |s|
          s.field "name", strprop("slot name (unique in the project; how every surface refers to it)"), required: true
          s.field "flow_id", intprop("build a literal overlay from THIS captured flow's login response (see list_history); mutually exclusive with set_headers and the request-source mode")
          s.field "set_headers", session_headers_prop
          s.field "from_request_flow_id", intprop("copy selected request headers from THIS captured flow (see list_history); must be supplied with copy_headers and is mutually exclusive with flow_id and set_headers")
          s.field "copy_headers", strarrprop("request header names to copy verbatim from from_request_flow_id; must be supplied with from_request_flow_id (values stay redacted in replies). Content-Length, Transfer-Encoding and Host are refused — a slot is applied to a message with a different body and target")
          s.field "remove_headers", strarrprop("header names to STRIP before sending (e.g. [\"Cookie\",\"Authorization\"] for an anonymous identity)")
          s.field "rules", strarrprop("extract-rule binding NAMES whose observed values belong to this slot instead of the global table (see list_extract_rules)")
          s.field "baseline", boolprop("make this the authorize BASELINE every other slot is judged against (exactly one slot holds it)")
          s.field "refresh", refresh_ids_prop
          s.field "refresh_before", refresh_before_prop
        end

        tool j, "update_session_slot",
          "Change a session slot. Only the fields you pass change — omit 'rules' and the slot " \
          "keeps the rules it claims. Pass an empty array to clear a collection." do |s|
          s.field "name", strprop("the slot to change (see list_session_slots)"), required: true
          s.field "new_name", strprop("rename the slot")
          s.field "set_headers", session_headers_prop
          s.field "remove_headers", strarrprop("replace the header names this slot strips")
          s.field "rules", strarrprop("replace the extract-rule binding names this slot claims")
          s.field "baseline", boolprop("make this the authorize baseline")
          s.field "refresh", refresh_ids_prop
          s.field "refresh_before", refresh_before_prop
        end

        tool j, "refresh_session_slot",
          "Run a session slot's REFRESH steps now: its Repeater sessions, in order (e.g. csrf-fetch " \
          "then login), each response going through the slot's own extract rules so the slot's " \
          "bindings are rebound. Steps resolve THIS slot's $BIND values and carry no slot header " \
          "overlay. Each step is recorded in History (source refresh) and the outcome in the event " \
          "log. Returns ok/failed_step/status and the binding NAMES rebound — never a value. The " \
          "values live in this server process only. A slot with refresh_before set also refreshes " \
          "on its own before a send that goes out as it; a failed automatic refresh cools down " \
          "#{Gori::SessionRefresh::COOLDOWN.total_seconds.to_i}s and stops after " \
          "#{Gori::SessionRefresh::FAILURE_LIMIT} failures until a manual refresh succeeds." do |s|
          s.field "name", strprop("the slot to refresh (see list_session_slots)"), required: true
          s.field "allow_unscoped", boolprop("send the steps even when their host is outside the project scope (default false)")
        end

        tool j, "delete_session_slot",
          "Delete a session slot. Any extract rule it claimed goes back to writing the GLOBAL " \
          "binding table. If it was active, the next send goes out as captured." do |s|
          s.field "name", strprop("the slot to delete (see list_session_slots)"), required: true
        end

        tool j, "set_active_session_slot",
          "Choose the SEND CONTEXT for this server: the slot whose header overlay is applied to " \
          "every outbound request (send_request, send_websocket, repeater, fuzz/mine/sequence/" \
          "discover) and whose binding table a $BIND.NAME token (bare syntax: $NAME) resolves " \
          "against. Pass name:null for " \
          "as-captured (no overlay). Held in memory by THIS process only — it is never persisted, " \
          "so a new connection starts as-captured." do |s|
          s.field "name", strprop("slot name, or null/omitted for as-captured (no overlay)")
        end
      end

      # `set_headers` accepts both shapes a client reaches for: the {name, value} objects the
      # rest of this surface uses, and the "Name: value" lines an operator copies out of a
      # request. Declaring both beats refusing one an LLM will send anyway.
      private def refresh_ids_prop : JSON::Any
        id_list_prop("Repeater session ids that RE-AUTHENTICATE this slot, in the order they run " \
                     "(e.g. [csrf-fetch id, login id]). Omit to keep the current list; [] clears it")
      end

      private def refresh_before_prop : JSON::Any
        strprop("when the slot refreshes on its own before a send: \"off\" (default), \"jwt-exp\" " \
                "(a JWT bound in the slot is within #{Gori::SessionSlot::RefreshBefore::SKEW.total_seconds.to_i}s " \
                "of its exp) or \"ttl=10m\" (its newest binding is older than that). Acts before a " \
                "send, never on a response: a 401 is never retried")
      end

      private def session_headers_prop : JSON::Any
        desc = "headers this slot UPSERTS (replace if present, append if absent). Either " \
               "[{\"name\":\"Cookie\",\"value\":\"session=…\"}] or [\"Cookie: session=…\"]. " \
               "Header-only by design: Content-Length never moves and the body is byte-exact."
        JSON.parse(%({"type":"array","description":#{desc.to_json},) +
                   %("items":{"oneOf":[{"type":"object"},{"type":"string"}]}}))
      end
    end
  end
end
