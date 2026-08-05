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
  class_property? discover_keep_alive : Bool = true
  class_property? discover_prefs_saved : Bool = false

  private def self.parse_discover_prefs(node : JSON::Any?) : Nil
    obj = node.try(&.as_h?)
    unless obj
      self.discover_prefs_saved = false
      return
    end
    self.discover_prefs_saved = true
    obj["containment"]?.try(&.as_s?).try { |s| self.discover_containment = s }
    int_field(obj, "max_depth").try { |n| self.discover_max_depth = n }
    int_field(obj, "concurrency").try { |n| self.discover_concurrency = n }
    obj["spider"]?.try(&.as_bool?).try { |b| self.discover_spider = b }
    obj["bruteforce"]?.try(&.as_bool?).try { |b| self.discover_bruteforce = b }
    obj["extensions"]?.try(&.as_bool?).try { |b| self.discover_extensions = b }
    # `!= false`, not `try(&.as_bool?)` with a false default: a prefs file written before
    # keep-alive existed has no key at all, and reading a missing key as "off" would silently
    # turn the reuse pool off for every saved overlay (the shape the fuzzer tab guards at
    # fuzzer_view.cr:1411).
    self.discover_keep_alive = obj["keep_alive"]?.try(&.as_bool?) != false
  end

  # Persist the Discover overlay's last confirmed choices (called when a run starts).
  def self.save_discover_prefs(containment : String, max_depth : Int32, concurrency : Int32,
                               spider : Bool, bruteforce : Bool, extensions : Bool,
                               keep_alive : Bool) : Nil
    self.discover_containment = containment
    self.discover_max_depth = max_depth
    self.discover_concurrency = concurrency
    self.discover_spider = spider
    self.discover_bruteforce = bruteforce
    self.discover_extensions = extensions
    self.discover_keep_alive = keep_alive
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
          j.field "keep_alive", discover_keep_alive?
        end
      end
    end
  end
end
