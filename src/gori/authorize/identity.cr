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

    def self.serialize(identities : Array(Identity)) : String
      SessionSlot.serialize(identities)
    end

    def self.parse_json(raw : String?) : Array(Identity)
      SessionSlot.parse_json(raw)
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
    def self.resolve(id : Identity) : Identity
      id.resolve_values { |v| Env.expand_bindings_as(v, id.name, guard_boundary: true) }
    end

    def self.overlay_request(head : Bytes, body : Bytes?, id : Identity) : Bytes
      SessionSlot.overlay_request(head, body, id)
    end

    def self.overlay_wire(wire : Bytes, id : Identity) : Bytes
      SessionSlot.overlay_wire(wire, id)
    end

    def self.overlay_head(head : Bytes, id : Identity) : Bytes
      SessionSlot.overlay_head(head, id)
    end
  end
end
