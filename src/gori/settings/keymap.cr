require "json"

# HOTKEYS section (settings:hotkeys): OS keymap profile + sparse per-verb chord
# overrides. See settings.cr for the module-level overview and the load/save/
# serialize orchestration.
module Gori::Settings
  # Hotkey customization (settings:hotkeys). `keymap_os` pins an OS default profile —
  # "auto" tracks the build's platform; "darwin"/"linux"/"windows" force one.
  # `keymap_overrides` is SPARSE: verb-id → chord-label strings ("ctrl-p", "shift-s").
  # An empty list = explicit unbind; an absent id = use the profile default.
  class_property keymap_os : String = "auto"
  class_property keymap_overrides : Hash(String, Array(String)) = {} of String => Array(String)

  # Tolerant hotkey parse: a non-object (or absent) node keeps current values. `os`
  # is normalized (unknown → "auto"); `bindings` is a sparse verb-id → chord-label
  # list (non-array entries dropped; unparseable chord labels dropped; an empty list
  # is PRESERVED as an explicit unbind). Mirrors parse_tab_prefs' robustness.
  private def self.parse_hotkeys(node : JSON::Any?) : Nil
    return unless h = node.try(&.as_h?)
    self.keymap_os = normalize_os(h["os"]?.try(&.as_s?))
    self.keymap_overrides = parse_keymap_bindings(h["bindings"]?)
  end

  private def self.parse_keymap_bindings(node : JSON::Any?) : Hash(String, Array(String))
    obj = node.try(&.as_h?)
    return keymap_overrides unless obj # non-object / absent → keep current
    out = {} of String => Array(String)
    obj.each do |id, v|
      next if id.empty?
      arr = v.as_a?
      next unless arr # a non-array entry is dropped (tolerant)
      # Keep only labels that parse to a real chord (round-trip safe); a list that
      # ends up empty is a deliberate unbind and is preserved. The id is remapped from
      # any pre-rename spelling so a saved binding on e.g. replay.send still resolves.
      out[remap_legacy_id(id)] = arr.compact_map(&.as_s?).select { |s| !Verb::Chord.parse(s).nil? }
    end
    out
  end

  # Omit when untouched (default profile + no overrides) so an untouched install
  # never writes a "hotkeys" block.
  private def self.serialize_hotkeys(j : JSON::Builder) : Nil
    unless keymap_overrides.empty? && keymap_os == "auto"
      j.field "hotkeys" do
        j.object do
          j.field "os", keymap_os
          unless keymap_overrides.empty?
            j.field "bindings" do
              j.object do
                keymap_overrides.each do |id, labels|
                  j.field(id) { j.array { labels.each { |l| j.string l } } }
                end
              end
            end
          end
        end
      end
    end
  end
end
