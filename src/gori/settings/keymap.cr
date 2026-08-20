require "json"

# HOTKEYS section (settings:hotkeys): OS keymap profile + sparse per-verb chord
# overrides. See settings.cr for the module-level overview and the load/save/
# serialize orchestration.
module Gori::Settings
  # Which modifier fronts gori's BUILT-IN shortcut family — the chords consumed by a
  # hardcoded guard before the keymap (^P palette, ^N new, ^W close, ^G/^F/^B/^E, ^1-9,
  # ^,), which the settings:hotkeys editor deliberately cannot reach. "ctrl" is the
  # default; "alt" ADDS an ⌥ alias (Ctrl keeps working) for terminals/multiplexers that
  # swallow the Ctrl form — tmux's ^B prefix, or Ctrl+digit, which many terminals never
  # deliver. See Gori::Hotkeys for the derived chord sets and Tui::Keybind.dealias for
  # the one place the alias is applied.
  DEFAULT_COMMAND_MODIFIER = "ctrl"

  # "auto" tracks the build's platform — the profile an install that never picked one uses.
  DEFAULT_KEYMAP_OS = "auto"

  # Hotkey customization (settings:hotkeys). `keymap_os` pins an OS default profile —
  # "auto" tracks the build's platform; "darwin"/"linux"/"windows" force one.
  # `keymap_overrides` is SPARSE: verb-id → chord-label strings ("ctrl-p", "shift-s").
  # An empty list = explicit unbind; an absent id = use the profile default.
  class_property keymap_os : String = DEFAULT_KEYMAP_OS
  class_property keymap_overrides : Hash(String, Array(String)) = {} of String => Array(String)
  class_property command_modifier : String = DEFAULT_COMMAND_MODIFIER

  # Tolerant hotkey parse: a non-object (or absent) node keeps current values. `os`
  # is normalized (unknown → "auto"); `bindings` is a sparse verb-id → chord-label
  # list (non-array entries dropped; unparseable chord labels dropped; an empty list
  # is PRESERVED as an explicit unbind). Mirrors parse_tab_prefs' robustness.
  #
  # `command_modifier` is read only WHEN PRESENT (the display.cr shape), unlike `os` —
  # a hotkeys block written by a build that predates it must keep the current value
  # rather than being reset by a nil.
  private def self.parse_hotkeys(node : JSON::Any?) : Nil
    return unless h = node.try(&.as_h?)
    self.keymap_os = normalize_os(h["os"]?.try(&.as_s?))
    if v = h["command_modifier"]?.try(&.as_s?)
      self.command_modifier = normalize_command_modifier(v)
    end
    self.keymap_overrides = parse_keymap_bindings(h["bindings"]?)
  end

  # Allowed command modifiers; anything else falls back to the default.
  def self.normalize_command_modifier(s : String) : String
    {"ctrl", "alt"}.includes?(s) ? s : DEFAULT_COMMAND_MODIFIER
  end

  # Verb ids that were RENAMED, old → new. A stored override is keyed by verb id, so a rename
  # would otherwise silently unbind whatever the operator had bound — the binding survives in
  # the file, matches no verb, and the key just stops working with nothing to see. Rewritten on
  # read, so the next save persists the new id and the entry retires itself.
  RENAMED_VERB_IDS = {
    # v0.1.x called the Miss Ring verbs "pet".
    "pet.toggle"   => "companion.toggle",
    "settings.pet" => "settings.companion",
  }

  private def self.parse_keymap_bindings(node : JSON::Any?) : Hash(String, Array(String))
    obj = node.try(&.as_h?)
    return keymap_overrides unless obj # non-object / absent → keep current
    out = {} of String => Array(String)
    obj.each do |raw_id, v|
      next if raw_id.empty?
      id = RENAMED_VERB_IDS[raw_id]? || raw_id
      # A file carrying BOTH names keeps the current one — the legacy entry is the older write.
      next if id != raw_id && obj.has_key?(id)
      arr = v.as_a?
      next unless arr # a non-array entry is dropped (tolerant)
      # Keep only labels that parse to a real chord (round-trip safe); a list that
      # ends up empty is a deliberate unbind and is preserved.
      out[id] = arr.compact_map(&.as_s?).select { |s| !Verb::Chord.parse(s).nil? }
    end
    out
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory). Drops every
  # rebinding and the OS profile pin; the caller rebuilds the live keymap from what is left.
  private def self.reset_hotkeys : Nil
    self.keymap_os = DEFAULT_KEYMAP_OS
    self.keymap_overrides = {} of String => Array(String)
    self.command_modifier = DEFAULT_COMMAND_MODIFIER
  end

  # Omit when untouched (default profile + default modifier + no overrides) so an
  # untouched install never writes a "hotkeys" block. Every field in the block must
  # appear in this guard — a modifier-only change would otherwise be dropped.
  private def self.serialize_hotkeys(j : JSON::Builder) : Nil
    unless keymap_overrides.empty? && keymap_os == DEFAULT_KEYMAP_OS && command_modifier == DEFAULT_COMMAND_MODIFIER
      j.field "hotkeys" do
        j.object do
          j.field "os", keymap_os
          j.field "command_modifier", command_modifier
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
