require "json"

# DISCOVER section: last Discover overlay choices (global scratch, not project
# data). See settings.cr for the module-level overview and the load/save/serialize
# orchestration.
module Gori::Settings
  # Factory values, named rather than inlined so `reset_discover` restores the same
  # numbers the properties below start at instead of a second copy that can drift.
  DEFAULT_DISCOVER_CONTAINMENT = "scope-aware"
  DEFAULT_DISCOVER_MAX_DEPTH   =  4
  DEFAULT_DISCOVER_CONCURRENCY = 20
  DEFAULT_DISCOVER_SPIDER      = true
  DEFAULT_DISCOVER_BRUTEFORCE  = true
  DEFAULT_DISCOVER_EXTENSIONS  = false
  DEFAULT_DISCOVER_KEEP_ALIVE  = true

  # Last Discover overlay choices (global scratch — not project data).
  class_property discover_containment : String = DEFAULT_DISCOVER_CONTAINMENT
  class_property discover_max_depth : Int32 = DEFAULT_DISCOVER_MAX_DEPTH
  class_property discover_concurrency : Int32 = DEFAULT_DISCOVER_CONCURRENCY
  class_property? discover_spider : Bool = DEFAULT_DISCOVER_SPIDER
  class_property? discover_bruteforce : Bool = DEFAULT_DISCOVER_BRUTEFORCE
  class_property? discover_extensions : Bool = DEFAULT_DISCOVER_EXTENSIONS
  class_property? discover_keep_alive : Bool = DEFAULT_DISCOVER_KEEP_ALIVE
  class_property? discover_prefs_saved : Bool = false

  private def self.parse_discover_prefs(node : JSON::Any?) : Nil
    # ABSENT (nil) leaves the live prefs alone — same import_document hole as mine
    # (see parse_mine_prefs). Present-but-not-an-object still clears.
    return if node.nil?
    obj = node.as_h?
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

  # Factory reset for this section (dispatched by Settings.reset_to_factory). Clearing
  # `discover_prefs_saved` is what actually drops the key from the file — serialize_discover
  # writes nothing without it — but the values are restored too, because they are what the
  # Discover overlay opens on for the rest of THIS process.
  private def self.reset_discover : Nil
    self.discover_containment = DEFAULT_DISCOVER_CONTAINMENT
    self.discover_max_depth = DEFAULT_DISCOVER_MAX_DEPTH
    self.discover_concurrency = DEFAULT_DISCOVER_CONCURRENCY
    self.discover_spider = DEFAULT_DISCOVER_SPIDER
    self.discover_bruteforce = DEFAULT_DISCOVER_BRUTEFORCE
    self.discover_extensions = DEFAULT_DISCOVER_EXTENSIONS
    self.discover_keep_alive = DEFAULT_DISCOVER_KEEP_ALIVE
    self.discover_prefs_saved = false
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
