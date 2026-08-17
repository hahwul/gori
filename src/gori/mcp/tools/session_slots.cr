require "json"
require "../../store"
require "../../session_slots"
require "../../discover/headers"

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
                registry.slots.each { |s| emit_session_slot(j, s, include_sensitive, active) }
              end
            end
          end
        end)
      end

      private def create_session_slot(h) : Result
        name = str(h, "name").try(&.strip)
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil? || name.empty?
        registry = fresh_slots
        # Deterministic and un-retryable, so INVALID_ARGUMENT rather than PROJECT_BUSY — the
        # #414 shape: an agent that trusts `retryable` loops forever on a duplicate.
        if registry.find(name)
          return err("a session slot called '#{name}' already exists (change it with update_session_slot)",
            "INVALID_ARGUMENT", field: "name")
        end
        set_headers = session_set_headers(h)
        return set_headers if set_headers.is_a?(Result)
        slot = Gori::SessionSlot.new(name, set_headers, str_list(h, "remove_headers").map(&.strip).reject(&.empty?),
          bool_arg(h, "baseline", false), str_list(h, "rules").map(&.strip).reject(&.empty?))
        unless registry.add(slot)
          return busy("session slot NOT created (store busy or unwritable); no slot was added")
        end
        # Re-read rather than echo what was built: `SessionSlots` owns the single-baseline
        # rule, so the FIRST slot in a project comes back holding a flag the caller did not
        # ask for — and a reply that denied it would have the agent set it a second time.
        Result.new(JSON.build { |j| emit_session_slot(j, registry.find(slot.name) || slot, false, registry.active_name) })
      end

      # A partial update: an argument left out keeps what the slot already has. That is the
      # shape an agent needs to rotate ONE cookie without having to re-send the rule list it
      # never read (and would blank).
      private def update_session_slot(h) : Result
        name = str(h, "name").try(&.strip)
        return err("missing required 'name'", "INVALID_ARGUMENT", field: "name") if name.nil? || name.empty?
        registry = fresh_slots
        current = registry.find(name)
        return not_found("no session slot named '#{name}' (see list_session_slots)") unless current
        renamed = (str(h, "new_name").try(&.strip)).presence
        if renamed && renamed != name && registry.find(renamed)
          return err("another session slot is already called '#{renamed}'", "INVALID_ARGUMENT", field: "new_name")
        end
        set_headers = h.has_key?("set_headers") ? session_set_headers(h) : current.set_headers
        return set_headers if set_headers.is_a?(Result)
        updated = Gori::SessionSlot.new(renamed || name, set_headers,
          slot_names_arg(h, "remove_headers", current.remove_headers),
          bool_arg(h, "baseline", current.baseline?),
          slot_names_arg(h, "rules", current.rules))
        unless registry.update(name, updated)
          return busy("session slot NOT updated (store busy or unwritable); it is unchanged")
        end
        # Re-read: dropping the baseline hands it to another row (see `create_session_slot`).
        Result.new(JSON.build { |j| emit_session_slot(j, registry.find(updated.name) || updated, false, registry.active_name) })
      end

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
              n = o["name"]?.try(&.as_s?).try(&.strip) || ""
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
                                    include_sensitive : Bool, active : String?) : Nil
        j.object do
          j.field "name", slot.name
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
          "\"Bearer $SESSION\" resolves against THIS slot's own table when it claims the rule." do |s|
          s.field "name", strprop("slot name (unique in the project; how every surface refers to it)"), required: true
          s.field "set_headers", session_headers_prop
          s.field "remove_headers", strarrprop("header names to STRIP before sending (e.g. [\"Cookie\",\"Authorization\"] for an anonymous identity)")
          s.field "rules", strarrprop("extract-rule binding NAMES whose observed values belong to this slot instead of the global table (see list_extract_rules)")
          s.field "baseline", boolprop("make this the authorize BASELINE every other slot is judged against (exactly one slot holds it)")
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
        end

        tool j, "delete_session_slot",
          "Delete a session slot. Any extract rule it claimed goes back to writing the GLOBAL " \
          "binding table. If it was active, the next send goes out as captured." do |s|
          s.field "name", strprop("the slot to delete (see list_session_slots)"), required: true
        end

        tool j, "set_active_session_slot",
          "Choose the SEND CONTEXT for this server: the slot whose header overlay is applied to " \
          "every outbound request (send_request, send_websocket, repeater, fuzz/mine/sequence/" \
          "discover) and whose binding table $NAME resolves against. Pass name:null for " \
          "as-captured (no overlay). Held in memory by THIS process only — it is never persisted, " \
          "so a new connection starts as-captured." do |s|
          s.field "name", strprop("slot name, or null/omitted for as-captured (no overlay)")
        end
      end

      # `set_headers` accepts both shapes a client reaches for: the {name, value} objects the
      # rest of this surface uses, and the "Name: value" lines an operator copies out of a
      # request. Declaring both beats refusing one an LLM will send anyway.
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
