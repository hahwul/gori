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
