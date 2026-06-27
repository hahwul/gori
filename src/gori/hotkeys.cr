require "./verb"
require "./settings"

module Gori
  # Facade over the hotkey engine (Verb::Keymap / OsProfile / Reserved / Conflicts) and
  # the persisted Settings. The SINGLE read-path for a verb's effective chord, so a
  # rebind is never visually stale — the dispatch keymap, the palette chord hint and the
  # Help tab all resolve a verb's binding through here.
  module Hotkeys
    # Selectable OS default profiles (the Settings.keymap_os domain). "auto" tracks the
    # build's native platform.
    PROFILES = %w(auto darwin linux windows)

    # Verb ids the editor must NOT expose. Guard-shadowed ids (`view.reveal-ws` — `^B` is
    # claimed by a hardcoded guard in Runner#handle_key before the keymap, so rebinding it
    # would silently do nothing) and deliberately-keyless app verbs (`app.quit`/`app.back`
    # are palette-only on purpose — single-key quit is a footgun).
    FIXED_IDS = {"view.reveal-ws", "app.quit", "app.back"}

    # gori claims these globally BEFORE the keymap (Runner#handle_key): ^G goto, ^F find,
    # ^B reveal, ^E external editor. Binding a verb to one would be shadowed by the guard,
    # so the editor refuses them on top of the terminal-reserved set.
    GUARD_CLAIMED = [
      Verb::Chord.new("g", ctrl: true), Verb::Chord.new("f", ctrl: true),
      Verb::Chord.new("b", ctrl: true), Verb::Chord.new("e", ctrl: true),
    ]

    # Build the dispatch keymap from the registry under the persisted OS profile + user
    # overrides. Replaces the bare Verb::Keymap.build at its call sites.
    def self.build_keymap(registry : Verb::Registry) : Verb::Keymap
      Verb::Keymap.build(registry, Verb::OsProfile.resolve(Settings.keymap_os), chord_overrides)
    end

    # The persisted user overrides, parsed from Settings' label strings into Chords.
    def self.chord_overrides : Hash(String, Array(Verb::Chord))
      Verb::Keymap.parse_overrides(Settings.keymap_overrides)
    end

    # Whether the editor should let the user rebind this verb. Excludes hidden nav
    # primitives, the FIXED ids, and multi-chord verbs — those extra chords are
    # navigation aliases (e.g. body.open = enter/right/l) that a single-chord rebind
    # would silently collapse, and their structural primary (enter/arrows) isn't a
    # meaningful shortcut to remap. Keyless verbs (0 chords) stay assignable.
    def self.rebindable?(verb : Verb::Definition) : Bool
      !verb.hidden? && !FIXED_IDS.includes?(verb.id) && verb.chords.size <= 1
    end

    # A human reason if `chord` is unbindable — terminal-/structurally reserved, or
    # claimed by a gori global guard before the keymap — else nil.
    def self.reserved?(chord : Verb::Chord) : String?
      if reason = Verb::Reserved.reserved?(chord)
        reason
      elsif GUARD_CLAIMED.includes?(chord)
        "#{chord.label} is reserved by a gori global shortcut"
      end
    end

    # The effective PRIMARY chord bound to `id` now (nil = unbound), honouring an optional
    # in-progress overrides map (the editor's working copy) and OS profile.
    def self.binding_for(registry : Verb::Registry, id : String,
                         overrides : Hash(String, Array(Verb::Chord)) = chord_overrides,
                         profile : String = Settings.keymap_os) : Verb::Chord?
      verb = registry[id]?
      return nil unless verb
      Verb::Keymap.effective_chords(verb, Verb::OsProfile.resolve(profile), overrides).first?
    end

    # The PRIMARY default chord for `id` under `profile` with NO user overrides — what a
    # row reverts to on "reset". `profile` is a Settings.keymap_os string.
    def self.default_for(registry : Verb::Registry, id : String, profile : String) : Verb::Chord?
      verb = registry[id]?
      return nil unless verb
      Verb::Keymap.effective_chords(verb, Verb::OsProfile.resolve(profile)).first?
    end

    # First conflict for a proposed (id, chord) against the working `overrides`, or nil.
    def self.conflict(registry : Verb::Registry, id : String, chord : Verb::Chord,
                      overrides : Hash(String, Array(Verb::Chord)),
                      profile : String = Settings.keymap_os) : Verb::Conflicts::Conflict?
      Verb::Conflicts.detect(registry, Verb::OsProfile.resolve(profile), overrides, id, chord)
    end

    # Convert the editor's working copy (verb-id → Chord? where nil = unbound) into the
    # engine's override shape (verb-id → Array(Chord) where [] = unbind).
    def self.as_chord_overrides(working : Hash(String, Verb::Chord?)) : Hash(String, Array(Verb::Chord))
      out = {} of String => Array(Verb::Chord)
      working.each { |id, chord| out[id] = chord ? [chord] : [] of Verb::Chord }
      out
    end

    def self.os_profile : String
      Settings.keymap_os
    end

    # Display label for an OS-profile string; "auto" shows the resolved platform.
    def self.profile_label(profile : String) : String
      case profile
      when "darwin"  then "macOS"
      when "linux"   then "Linux"
      when "windows" then "Windows"
      else                "auto (#{os_label(Verb::OsProfile::COMPILE_DEFAULT)})"
      end
    end

    private def self.os_label(os : Verb::OsProfile::Os) : String
      case os
      when .darwin?  then "macOS"
      when .windows? then "Windows"
      else                "Linux"
      end
    end

    # Persist the editor's working copy into the Settings model (the caller then runs
    # Settings.save). `working` is verb-id → Chord? (Chord = rebound; nil = unbound);
    # absent ids keep the profile default. Stored as label strings; an unbind is [].
    def self.apply(working : Hash(String, Verb::Chord?), profile : String) : Nil
      Settings.keymap_os = PROFILES.includes?(profile) ? profile : "auto"
      out = {} of String => Array(String)
      working.each { |id, chord| out[id] = chord ? [chord.label] : [] of String }
      Settings.keymap_overrides = out
    end
  end
end
