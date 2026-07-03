require "./verb"
require "./settings"

module Gori
  # Facade over the hotkey engine (Verb::Keymap / OsProfile / Reserved / Conflicts) and
  # the persisted Settings. The read-path the DISPATCH keymap (`build_keymap`), the
  # settings:hotkeys editor, and the command PALETTE (via #binding_for) share for a verb's
  # effective chord — so a rebind is reflected in the palette's chord column. NOTE: the
  # Help tab and the status-bar hints are still curated DEFAULT-chord prose (a documented
  # limitation — they don't route through here); a rebind isn't reflected in those, which
  # is why the Help tab points users to settings:hotkeys.
  module Hotkeys
    # Selectable OS default profiles (the Settings.keymap_os domain). "auto" tracks the
    # build's native platform.
    PROFILES = %w(auto darwin linux windows)

    # Verb ids the editor must NOT expose, because their chord is consumed by a hardcoded
    # handler BEFORE the keymap — so a rebind/unbind on them can't take effect:
    #   view.reveal-ws  ^B  — Runner#handle_key global guard
    #   app.palette     ^P  — every controller's handle_body_key opens the palette (save-first)
    #   replay.new/fuzz.new ^N — Runner#handle_key intercepts ^N at menu/body/subtabs focus
    #   app.quit/app.back   — deliberately palette-only (single-key quit is a footgun)
    FIXED_IDS = {"view.reveal-ws", "app.quit", "app.back", "app.palette", "replay.new", "fuzz.new"}

    # Chords consumed by a hardcoded handler BEFORE the keymap is consulted, so binding ANY
    # verb to one would be silently shadowed — the editor refuses them on top of the
    # terminal-reserved set. Two sources, both of which this MUST stay in sync with (there is
    # no shared constant yet — a guard moved without updating this set re-opens the footgun):
    #   • Runner#handle_key global guards: ^G goto, ^F find, ^B reveal, ^E external editor.
    #   • Controllers' handle_body_key + Runner's ^N: ^P palette, ^N new, ^W close, ^1-9 sub-tab.
    CLAIMED_CHORDS = begin
      cs = %w(g f b e p n w).map { |k| Verb::Chord.new(k, ctrl: true) }
      (1..9).each { |n| cs << Verb::Chord.new(n.to_s, ctrl: true) }
      cs
    end

    # Build the dispatch keymap from the registry under the persisted OS profile + user
    # overrides. Replaces the bare Verb::Keymap.build at its call sites.
    def self.build_keymap(registry : Verb::Registry) : Verb::Keymap
      Verb::Keymap.build(registry, Verb::OsProfile.resolve(Settings.keymap_os), rebindable_overrides(registry))
    end

    # The user overrides that actually reach the dispatch keymap: chord_overrides minus
    # any id the editor would never let you rebind (hidden nav primitives, FIXED ids,
    # multi-chord nav-alias verbs). A hand-edited settings.json could otherwise install one
    # and collapse a verb's structural chords (e.g. enter/arrows on body.open) — the case
    # the editor's rebindable? gate prevents. The command PALETTE resolves its shown chord
    # through THIS set (not raw chord_overrides), so its column can never advertise a chord
    # dispatch would drop — build_keymap and the palette must agree, so they share this one
    # filter rather than duplicating it.
    def self.rebindable_overrides(registry : Verb::Registry) : Hash(String, Array(Verb::Chord))
      chord_overrides.select { |id, _| (v = registry[id]?) && rebindable?(v) }
    end

    # The persisted user overrides, parsed from Settings' label strings into Chords. A
    # reserved/unparseable chord is DROPPED here too (not just refused by the editor) so a
    # hand-edited settings.json can't install e.g. a verb on `escape`/`enter`/`^C` into the
    # dispatch keymap and shadow a structural handler. An entry that loses all its chords
    # this way falls back to the default; a genuinely empty list stays an explicit unbind.
    def self.chord_overrides : Hash(String, Array(Verb::Chord))
      out = {} of String => Array(Verb::Chord)
      Settings.keymap_overrides.each do |id, labels|
        chords = labels.compact_map { |l| Verb::Chord.parse(l) }.reject { |c| reserved?(c) }
        next if chords.empty? && !labels.empty? # malformed (garbage/reserved) → use the default
        out[id] = chords
      end
      out
    end

    # Whether the editor should let the user rebind this verb. Excludes hidden nav
    # primitives, the FIXED ids, and multi-chord verbs — those extra chords are
    # navigation aliases (e.g. body.open = enter/right/l) that a single-chord rebind
    # would silently collapse, and their structural primary (enter/arrows) isn't a
    # meaningful shortcut to remap. Keyless verbs (0 chords) stay assignable.
    def self.rebindable?(verb : Verb::Definition) : Bool
      !verb.hidden? && !FIXED_IDS.includes?(verb.id) && verb.chords.size <= 1
    end

    # A human reason if `chord` is unbindable — terminal-/structurally reserved, or claimed
    # by a hardcoded gori shortcut before the keymap — else nil.
    def self.reserved?(chord : Verb::Chord) : String?
      if reason = Verb::Reserved.reserved?(chord)
        reason
      elsif CLAIMED_CHORDS.includes?(chord)
        "#{chord.label} is reserved by a gori shortcut"
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
