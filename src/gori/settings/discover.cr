require "json"

# DISCOVER section: last Discover overlay choices (global scratch, not project
# data). See settings.cr for the module-level overview and the load/save/serialize
# orchestration.
module Gori::Settings
  # Last Discover overlay choices (global scratch — not project data).
  class_property discover_containment : String = "scope-aware"
  class_property discover_max_depth : Int32 = 4
  class_property discover_concurrency : Int32 = 20
  class_property? discover_spider : Bool = true
  class_property? discover_bruteforce : Bool = true
  class_property? discover_extensions : Bool = false
  class_property? discover_prefs_saved : Bool = false

  private def self.parse_discover_prefs(node : JSON::Any?) : Nil
    obj = node.try(&.as_h?)
    unless obj
      self.discover_prefs_saved = false
      return
    end
    self.discover_prefs_saved = true
    obj["containment"]?.try(&.as_s?).try { |s| self.discover_containment = s }
    obj["max_depth"]?.try(&.as_i?).try { |n| self.discover_max_depth = n }
    obj["concurrency"]?.try(&.as_i?).try { |n| self.discover_concurrency = n }
    obj["spider"]?.try(&.as_bool?).try { |b| self.discover_spider = b }
    obj["bruteforce"]?.try(&.as_bool?).try { |b| self.discover_bruteforce = b }
    obj["extensions"]?.try(&.as_bool?).try { |b| self.discover_extensions = b }
  end

  # Persist the Discover overlay's last confirmed choices (called when a run starts).
  def self.save_discover_prefs(containment : String, max_depth : Int32, concurrency : Int32,
                               spider : Bool, bruteforce : Bool, extensions : Bool) : Nil
    self.discover_containment = containment
    self.discover_max_depth = max_depth
    self.discover_concurrency = concurrency
    self.discover_spider = spider
    self.discover_bruteforce = bruteforce
    self.discover_extensions = extensions
    self.discover_prefs_saved = true
    save
  end

  private def self.serialize_discover(j : JSON::Builder) : Nil
    if discover_prefs_saved?
      j.field "discover" do
        j.object do
          j.field "containment", discover_containment
          j.field "max_depth", discover_max_depth
          j.field "concurrency", discover_concurrency
          j.field "spider", discover_spider?
          j.field "bruteforce", discover_bruteforce?
          j.field "extensions", discover_extensions?
        end
      end
    end
  end
end
