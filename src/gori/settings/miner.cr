require "json"

# MINER section: last Mine-parameters overlay choices (global scratch, not project
# data). See settings.cr for the module-level overview and the load/save/serialize
# orchestration.
module Gori::Settings
  # Last Mine-parameters overlay choices (global scratch — not project data).
  # locations: checked location labels; concurrency/notify mirror the overlay.
  class_property mine_locations : Array(String) = [] of String
  class_property mine_concurrency : Int32 = 10
  class_property mine_notify : String = "when-found"
  class_property? mine_prefs_saved : Bool = false

  private def self.parse_mine_prefs(node : JSON::Any?) : Nil
    obj = node.try(&.as_h?)
    unless obj
      self.mine_prefs_saved = false
      return
    end
    self.mine_prefs_saved = true
    if locs = obj["locations"]?.try(&.as_a?)
      self.mine_locations = locs.compact_map(&.as_s?).map(&.downcase.strip).reject(&.empty?)
    end
    obj["concurrency"]?.try(&.as_i?).try { |n| self.mine_concurrency = n }
    obj["notify"]?.try(&.as_s?).try { |s| self.mine_notify = s }
  end

  # Persist the overlay's last confirmed choices (called when mining starts).
  def self.save_mine_prefs(locations : Array(String), concurrency : Int32, notify : String) : Nil
    self.mine_locations = locations.map(&.downcase.strip).reject(&.empty?)
    self.mine_concurrency = concurrency
    self.mine_notify = notify
    self.mine_prefs_saved = true
    save
  end

  private def self.serialize_mine(j : JSON::Builder) : Nil
    if mine_prefs_saved?
      j.field "mine" do
        j.object do
          j.field "locations" do
            j.array { mine_locations.each { |l| j.string l } }
          end
          j.field "concurrency", mine_concurrency
          j.field "notify", mine_notify
        end
      end
    end
  end
end
