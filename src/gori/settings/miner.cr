require "json"

# MINER section: last Mine-parameters overlay choices (global scratch, not project
# data). See settings.cr for the module-level overview and the load/save/serialize
# orchestration.
module Gori::Settings
  # Factory values, named rather than inlined so `reset_mine` restores the same numbers
  # the properties below start at instead of a second copy that can drift.
  DEFAULT_MINE_CONCURRENCY = 10
  DEFAULT_MINE_NOTIFY      = "when-found"
  DEFAULT_MINE_KEEP_ALIVE  = true

  # Last Mine-parameters overlay choices (global scratch — not project data).
  # locations: checked location labels; concurrency/notify mirror the overlay.
  class_property mine_locations : Array(String) = [] of String
  class_property mine_concurrency : Int32 = DEFAULT_MINE_CONCURRENCY
  class_property mine_notify : String = DEFAULT_MINE_NOTIFY
  # Reuse one connection across the mine's probes. Mirrors `Settings.discover_keep_alive?`,
  # including the `!= false` read below: a settings file written before this key existed must
  # come back as the default ON, not as an opt-out the operator never chose.
  class_property? mine_keep_alive : Bool = DEFAULT_MINE_KEEP_ALIVE
  class_property? mine_prefs_saved : Bool = false

  private def self.parse_mine_prefs(node : JSON::Any?) : Nil
    # ABSENT (nil) leaves the live prefs alone — import_document filters to selected
    # sections then reuses apply_sections, so a profile without `mine` used to clear
    # mine_prefs_saved and the next save erased the operator's Mine overlay choices.
    # Present-but-not-an-object still clears (malformed section, not "untouched").
    return if node.nil?
    obj = node.as_h?
    unless obj
      self.mine_prefs_saved = false
      return
    end
    self.mine_prefs_saved = true
    if locs = obj["locations"]?.try(&.as_a?)
      self.mine_locations = locs.compact_map(&.as_s?).map(&.downcase.strip).reject(&.empty?)
    end
    int_field(obj, "concurrency").try { |n| self.mine_concurrency = n }
    obj["notify"]?.try(&.as_s?).try { |s| self.mine_notify = s }
    self.mine_keep_alive = obj["keep_alive"]?.try(&.as_bool?) != false
  end

  # Persist the overlay's last confirmed choices (called when mining starts).
  def self.save_mine_prefs(locations : Array(String), concurrency : Int32, notify : String,
                           keep_alive : Bool = true) : Nil
    self.mine_locations = locations.map(&.downcase.strip).reject(&.empty?)
    self.mine_concurrency = concurrency
    self.mine_notify = notify
    self.mine_keep_alive = keep_alive
    self.mine_prefs_saved = true
    save
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). Same shape as
  # reset_discover: clearing `mine_prefs_saved` drops the key, the values are what the Mine
  # overlay opens on for the rest of this process.
  private def self.reset_mine : Nil
    self.mine_locations = [] of String
    self.mine_concurrency = DEFAULT_MINE_CONCURRENCY
    self.mine_notify = DEFAULT_MINE_NOTIFY
    self.mine_keep_alive = DEFAULT_MINE_KEEP_ALIVE
    self.mine_prefs_saved = false
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
          j.field "keep_alive", mine_keep_alive?
        end
      end
    end
  end
end
