require "../env"
require "../session_slot"

module Gori
  # Authorization / access-control testing (Burp Autorize / Auth Analyzer shape): replay a
  # captured request under several IDENTITIES — an admin session, a low-privilege user, an
  # anonymous client — and read the responses against a baseline to spot broken access
  # control (a resource that answers a low-priv identity the same as the baseline).
  #
  # An identity IS a `Gori::SessionSlot` (DESIGN.md §7, 2026-08-17). It was a private little
  # header-overlay struct here first, because gori had no multi-session primitive to borrow;
  # session slots are that primitive, and they were built out of this one rather than beside
  # it. So this file is now an ALIAS plus the five delegating module functions the surfaces
  # already call — `Authorize::Identity` and `Gori::SessionSlot` are the same type, and an
  # operator who configures "admin" in the Authorize tab has configured the slot every send
  # seam resolves `$NAME` against.
  #
  # The send path, the diff and the verdict all reuse existing engines (`Fuzz::Sender`,
  # `Repeater::ExchangeMeta`, `Discover::Fingerprint`); the identities themselves persist per
  # project under `Store::SESSION_SLOTS_KEY`.
  module Authorize
    alias Identity = ::Gori::SessionSlot

    # Why an EXPLICIT identity set — a `--identities` file, an MCP `identities` array — cannot
    # be read as written, or nil when it can. `parse_json` is tolerant on purpose (a project
    # row must never fail a project open), so there a known field of the wrong type is simply
    # dropped: `"set": {"Authorization": "Bearer low"}` lost its overlay, the identity went out
    # AS CAPTURED with the baseline's own credentials, and the row read back as a BYPASS. An
    # operator's own input is refused instead, naming the entry and the field.
    def self.explicit_json_error(raw : String) : String?
      arr = begin
        JSON.parse(raw).as_a?
      rescue JSON::ParseException
        nil
      end
      return "expected a JSON array of identity objects, e.g. [{\"name\":\"anonymous\",\"remove\":[\"Cookie\"]}]" unless arr
      arr.each_with_index do |e, i|
        o = e.as_h?
        return "entry #{i + 1} is not an object" unless o
        if why = entry_field_error(o)
          where = o["name"]?.try(&.as_s?).try { |n| "#{n.inspect} (entry #{i + 1})" } || "entry #{i + 1}"
          return "#{where}: #{why}"
        end
      end
      nil
    end

    # The first known field of one entry whose type `parse_json` would drop, or nil. A field
    # given as JSON `null` is absent, as `parse_json` reads it.
    private def self.entry_field_error(o : Hash(String, JSON::Any)) : String?
      given = ->(key : String) { o[key]?.try { |v| v.raw.nil? ? nil : v } }
      return %("name" must be a string) if given.call("name").try(&.as_s?.nil?)
      return %("baseline" must be true or false) if given.call("baseline").try(&.raw.as?(Bool).nil?)
      {"remove", "rules", "literal"}.each do |key|
        next unless v = given.call(key)
        return %("#{key}" must be a list of strings) unless v.as_a?.try(&.all?(&.as_s?))
      end
      if (v = given.call("set")) && !v.as_a?.try(&.all? { |p| set_pair?(p) })
        return %("set" must be a list of {"name": …, "value": …} objects)
      end
      nil
    end

    private def self.set_pair?(p : JSON::Any) : Bool
      h = p.as_h?
      !h.nil? && !h["name"]?.try(&.as_s?).nil? && !h["value"]?.try(&.as_s?).nil?
    end

    # `id` with every `$NAME` in its header VALUES resolved out of THAT identity's own binding
    # table — the step `Env.overlay_slot` performs for the active slot at every other send seam
    # (`SessionSlots#overlay`), which this one has to perform for itself.
    #
    # Authorize applies the overlay directly (`Engine#send_one`), so nothing downstream resolves
    # it, and until this existed an identity written the way `SessionSlot#rules` is FOR —
    # `Authorization: Bearer $SESSION` on a slot claiming the `SESSION` extract rule, one token
    # per identity, which is the documented multi-identity story — shipped the four literal
    # bytes `$SES…` on the wire. The identity then went out unauthenticated: against a protected
    # resource it drew the same 401 as anonymous, the verdict came back `Different`, and the row
    # aggregated to `enforced`. A bypass the operator was looking straight at reads as a target
    # that held.
    #
    # `guard_boundary: true`, matching `Bindings#overlay`: a resolved value is the ORIGIN's
    # bytes, not the operator's, and a CR/LF inside one forges a header boundary
    # (`Bindings.boundary_forging?`). The literal value an operator typed stays verbatim — that
    # provenance split is `SessionSlot.overlay_head`'s, and this changes only what a `$NAME`
    # expands to.
    #
    # A no-op with no `$` in any value, with no binding table, and for a passthrough identity,
    # so the built-in as-captured/anonymous pair costs nothing.
    # `report_unbound_overlay` runs FIRST, and it is the half this method was still missing.
    # Resolving is only half of "the identity carries its own session": with nothing bound —
    # which is EVERY headless run that has not replayed a login first, because a binding value
    # is memory-only — the `$SESSION` goes out literal and the run reports `enforced` on a
    # resource that is wide open. The failure this method's doc names is the one it could not
    # SEE, so the report is where the resolution happens. Not a refusal: an Authorize run that
    # dies on a half-configured identity is worse than one that says which identity went out
    # unauthenticated (`Env.take_unbound_overlay` is what a run summary drains).
    def self.resolve(id : Identity, generation : Env::Generation) : Identity
      Env.report_unbound_overlay(id)
      resolve_without_report(id, generation)
    end

    # The RESOLUTION with NO report — for a caller that is not putting these bytes on a wire.
    #
    # `resolve` above is the SEND seam's door and the report is half of it. `Passive
    # .any_identity_changes?` is not a send: it decides whether a flow is worth replaying AT
    # ALL, it runs on every flow the passive watcher sees, and it applies its overlays to a
    # `String` it throws away. Reporting from there put `CLI::Run.unbound_overlay_note`'s
    # sentence — "session values went out LITERALLY … their responses are NOT evidence about
    # the identity they name" — into the summary of a run that DECLINED the flow and sent
    # nothing, which is the report inventing the requests it warns about. Worse, the shape that
    # triggers it is the shape the predicate DECLINES: two slots both carrying `Cookie:
    # sid=$SESSION` with nothing bound resolve identically, so the flow is skipped as
    # `:no_effect` and the run still says both identities went out.
    #
    # The record is also throttled per {slot, name} until a surface drains it, so a predicate
    # that got there first would have SILENCED the log line at the seam that really sends.
    # ONE generation for the whole identity, for `Bindings#overlay`'s reason: an identity whose
    # SET headers use `$GEN.UUID` twice is one identity on one request, so it sends one value.
    # The caller supplies it, because only the caller knows the dial it will go out on (#1153).
    def self.resolve_without_report(id : Identity, generation : Env::Generation) : Identity
      id.resolve_values { |v| Env.expand_bindings_as(v, id.name, guard_boundary: true, generation: generation) }
    end
  end
end
