require "json"
require "../store"

# RETENTION section (settings.json "retention"): how much captured history a project keeps.
# See settings.cr for the load/save/serialize orchestration.
#
# Retention itself is NOT new — Store has swept flows since long before this section existed
# (Store::RETENTION_DEFAULT, every Store::PRUNE_INTERVAL inserts). What was missing is any way
# to SEE or CHANGE the cap: it was a `Store.open` parameter with no path from settings.json or
# any UI, so an operator on a long engagement could not raise it, one on a small disk could not
# lower it, and neither could discover the number without reading the source.
module Gori::Settings
  # The factory cap, taken from Store rather than restated, so the number lives in exactly one
  # place. `Store` deliberately does not depend on `Settings` (it is the lower layer), so the
  # reference goes this way round.
  DEFAULT_RETENTION_FLOWS = Store::RETENTION_DEFAULT

  # Keep at most this many newest flows per project; 0 = unlimited. Read by the surfaces that
  # OPEN a store for capture (see Settings.retention_flows), not by Store itself.
  class_property retention_max_flows : Int32 = DEFAULT_RETENTION_FLOWS

  # The value a capture-owning surface passes to `Store.open`. Negative is clamped to 0
  # (unlimited) rather than left to mean something odd inside the sweep, which tests
  # `<= 0` — a hand-edited -1 should read as "off", the same as 0.
  def self.retention_flows : Int32
    retention_max_flows < 0 ? 0 : retention_max_flows
  end

  private def self.parse_retention(node : JSON::Any?) : Nil
    return unless h = node.try(&.as_h?)
    h["max_flows"]?.try(&.as_i?).try { |v| self.retention_max_flows = v < 0 ? 0 : v }
  end

  # Omitted at the factory default, like the other optional sections, so an untouched install
  # keeps a settings.json free of values nobody chose.
  private def self.serialize_retention(j : JSON::Builder) : Nil
    return if retention_max_flows == DEFAULT_RETENTION_FLOWS
    j.field "retention" do
      j.object do
        j.field "max_flows", retention_max_flows
      end
    end
  end

  # nil if `value` is an acceptable cap; an error message otherwise. Only a non-integer is
  # rejected — 0 is the documented "unlimited", and there is no upper bound to enforce (a huge
  # cap simply never trips, which is what the operator asked for).
  def self.retention_error(value : String) : String?
    n = value.strip.to_i?
    return "settings: retention must be a whole number of flows (0 = unlimited)" unless n
    n < 0 ? "settings: retention cannot be negative (use 0 for unlimited)" : nil
  end
end
