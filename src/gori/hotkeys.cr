require "./verb"
require "./settings"

module Gori
  # Facade over the hotkey engine (Verb::Keymap / OsProfile / Reserved / Conflicts) and
  # the persisted Settings. The read-path the DISPATCH keymap (`build_keymap`), the
  # settings:hotkeys editor, the command PALETTE, Help (verb-id rows), and status body
  # hints (History/Repeater) share for a verb's effective chord — so a rebind is reflected
  # on those surfaces via #binding_for / #binding_label.
  module Hotkeys
    # Selectable OS default profiles (the Settings.keymap_os domain). "auto" tracks the
    # build's native platform.
    PROFILES = %w[auto darwin linux windows]

    # Verb ids the editor must NOT expose, because their chord is consumed by a hardcoded
    # handler BEFORE the keymap — so a rebind/unbind on them can't take effect:
    #   view.reveal-ws  ^B  — Runner#handle_key global guard
    #   app.palette     ^P  — every controller's handle_body_key opens the palette (save-first)
    #   repeater.new/fuzz.new ^N — Runner#handle_key intercepts ^N at menu/body/subtabs focus
    #   app.quit/app.back   — deliberately palette-only (single-key quit is a footgun)
    FIXED_IDS = {"view.reveal-ws", "app.quit", "app.back", "app.palette", "repeater.new", "fuzz.new"}

    # Chords consumed by a hardcoded handler BEFORE the keymap is consulted, so binding ANY
    # verb to one would be silently shadowed — the editor refuses them on top of the
    # terminal-reserved set.
    #
    # **Single source of truth for "claimed" keys.** Runner#handle_key and controllers
    # must only hardcode Ctrl+key guards that appear here (or the reserved set). When
    # adding a new pre-keymap guard, append to CLAIMED_CTRL_LETTERS / CLAIMED_CTRL_DIGITS /
    # CLAIMED_CTRL_PUNCT first, then wire the handler — the hotkey editor, reserved?() and
    # Tui::Keybind.dealias all derive from these, so they stay in sync.
    #   • Runner global guards: ^G goto, ^F find, ^B reveal, ^E external editor, ^, prefs.
    #   • Controllers + Runner: ^P palette, ^N new, ^W close, ^1-9 sub-tab.
    #   • Every text editor: ^Z undo (Repeater, Fuzzer, Notes, Issues, Intercept, Decoder,
    #     JWT, Rewriter, Project — nine controllers consume it before the keymap is read).
    #     Listed late: the guards predate the list, so the hotkey editor was offering ^Z as
    #     bindable and the binding was shadowed wherever an editor had focus.
    CLAIMED_CTRL_LETTERS = %w[g f b e p n w z]
    CLAIMED_CTRL_DIGITS  = ('1'..'9').map(&.to_s)
    # Spelled as a plain array, not `%w[,]`: in a word list a comma reads as a separator,
    # so the one-element form looks like a typo for an empty list. This is the ^, prefs chord.
    CLAIMED_CTRL_PUNCT = [","]

    # Every claimed key, modifier-free. The ctrl and alt chord sets below are both built
    # from this, and Keybind.dealias uses it to decide which events to rewrite.
    CLAIMED_KEYS = CLAIMED_CTRL_LETTERS + CLAIMED_CTRL_DIGITS + CLAIMED_CTRL_PUNCT

    CLAIMED_CHORDS     = CLAIMED_KEYS.map { |k| Verb::Chord.new(k, ctrl: true) }
    CLAIMED_ALT_CHORDS = CLAIMED_KEYS.map { |k| Verb::Chord.new(k, alt: true) }

    # Selectable command modifiers (the Settings.command_modifier domain). "ctrl" is the
    # built-in family's native modifier; "alt" ADDS an ⌥ alias for it (see #alias_active?).
    COMMAND_MODIFIERS = %w[ctrl alt]

    # Clamped on READ as well as on parse (Settings.normalize_command_modifier), the same
    # defence #chord_overrides applies to hand-edited bindings: nothing downstream should
    # have to reason about an unknown modifier, whatever put it there.
    def self.command_modifier : String
      m = Settings.command_modifier
      COMMAND_MODIFIERS.includes?(m) ? m : Settings::DEFAULT_COMMAND_MODIFIER
    end

    # Whether the ⌥ alias for the claimed family is on. The alias is ADDITIVE: the Ctrl
    # form keeps firing, so a terminal that doesn't deliver ⌥ as Meta can never lock a
    # user out of the palette. What the setting changes is which form gets ADVERTISED
    # (see #binding_for / #retag) and which extra chords are claimed.
    def self.alias_active? : Bool
      command_modifier == "alt"
    end

    def self.claimed?(chord : Verb::Chord) : Bool
      CLAIMED_CHORDS.includes?(chord) || (alias_active? && CLAIMED_ALT_CHORDS.includes?(chord))
    end

    # The alt twin of a claimed ctrl chord (nil for anything else) — the form the alias
    # advertises. Shift/alt-carrying chords are not claimed, so only the plain ctrl set
    # maps.
    def self.alt_twin(chord : Verb::Chord) : Verb::Chord?
      return nil unless CLAIMED_CHORDS.includes?(chord)
      Verb::Chord.new(chord.key, alt: true)
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
    # by a hardcoded gori shortcut before the keymap — else nil. Under an active ⌥ alias
    # BOTH forms of a claimed key are refused: the guard fires on either, so a binding on
    # the alt form would be shadowed exactly like one on the ctrl form.
    def self.reserved?(chord : Verb::Chord) : String?
      if reason = Verb::Reserved.reserved?(chord)
        reason
      elsif claimed?(chord)
        "#{display_label(chord)} is reserved by a gori shortcut"
      end
    end

    # The effective PRIMARY chord bound to `id` now (nil = unbound), honouring an optional
    # in-progress overrides map (the editor's working copy) and OS profile.
    #
    # Under an active ⌥ alias a CLAIMED chord is reported as its alt twin. The four
    # FIXED_IDS verbs declare `ctrl: true` defaults (verbs/core.cr, verbs/history.cr) and
    # can keep doing so: the palette, Help's verb-id rows and the space menu all resolve
    # through here, so their labels follow the setting from this one place. The Ctrl form
    # still fires — the alias is additive — but the alt form is the one worth advertising,
    # since a user only turns the alias on when Ctrl isn't reaching gori.
    def self.binding_for(registry : Verb::Registry, id : String,
                         overrides : Hash(String, Array(Verb::Chord)) = rebindable_overrides(registry),
                         profile : String = Settings.keymap_os) : Verb::Chord?
      verb = registry[id]?
      return nil unless verb
      chord = Verb::Keymap.effective_chords(verb, Verb::OsProfile.resolve(profile), overrides).first?
      return chord unless chord && alias_active?
      alt_twin(chord) || chord
    end

    # Compact status/Help token for a chord (`ctrl-r` → `^R`, `alt-p` → `⌥P`, `shift-i` →
    # `⇧I`, `f` → `f`). Matches the curated prose style used in body_hint / Help before
    # binding-truth. A MODIFIED single letter is shown uppercase (`^P`, `⌥P`) while a bare
    # one stays as typed (`f`), which is the convention the hand-written hints use.
    def self.display_label(chord : Verb::Chord) : String
      if chord.ctrl
        rest = chord.key.size == 1 ? chord.key.upcase : chord.key
        return "⇧^#{rest}" if chord.shift
        return "^#{rest}"
      end
      String.build do |io|
        io << "⌥" if chord.alt
        if (chord.shift || chord.alt) && chord.key.size == 1
          io << "⇧" if chord.shift
          io << chord.key.upcase
        else
          io << "⇧" if chord.shift
          io << case chord.key
          when "enter"     then "↵"
          when "escape"    then "esc"
          when "tab"       then "↹"
          when "backspace" then "⌫"
          when "space"     then "space"
          when "up"        then "↑"
          when "down"      then "↓"
          when "left"      then "←"
          when "right"     then "→"
          else                  chord.key
          end
        end
      end
    end

    # The claimed family as it appears in hand-written hint/help PROSE ("^P cmds",
    # "^1-9 jump"). A closed set on purpose: ^R/^S/^X/^C/^D are NOT claimed and must keep
    # their carets, so never widen this to a general `\^(\w)`.
    CLAIMED_CARET_RE = /\^([gfbepnwGFBEPNW,1-9])/

    # Rewrite the claimed family's carets to ⌥ in a DISPLAY string. Identity unless the
    # alias is on. This is why ~86 hand-written "^P"/"^N"/"^1-9" literals across the TUI
    # did not have to be swept: applying it at the few places hint text is drawn (Runner's
    # key_hints funnel, Help's item rows, the empty-state cards, the tutorial) covers all
    # of them, and it can be deleted wholesale if the guards ever move into the keymap.
    def self.retag(s : String) : String
      return s unless alias_active?
      # PCRE2 raises `ArgumentError: Regex match error: UTF-8 error` on a subject that is
      # not valid UTF-8, and this funnel takes ARBITRARY display text — including status
      # toasts interpolating captured wire bytes (a flow's host/method, built by
      # `String.new(bytes)` without a scrub). The raise would land inside `render`, and a
      # toast persists across frames, so it re-raises every tick until the tick-error
      # breaker exits the session. A malformed string has no claimed caret to rewrite.
      return s unless s.valid_encoding?
      s.gsub(CLAIMED_CARET_RE) { "⌥#{$1}" }
    end

    # Verb ids whose PERSISTED override sits on an alt chord the alias has just claimed.
    # Pure-alt chords are bindable while the alias is off (Verb::Reserved never refuses
    # them), so turning it on shadows any such binding — the guard fires before the keymap
    # and #chord_overrides now drops the chord as reserved, so the verb quietly reverts to
    # its default. Callers surface these so the revert isn't silent.
    def self.alias_conflicts(registry : Verb::Registry) : Array(String)
      return [] of String unless alias_active?
      Settings.keymap_overrides.compact_map do |id, labels|
        next unless registry[id]?
        next unless labels.any? { |l| (c = Verb::Chord.parse(l)) && CLAIMED_ALT_CHORDS.includes?(c) }
        id
      end.sort!
    end

    # Effective binding as a status/Help token, or `fallback` when unbound / unknown.
    def self.binding_label(registry : Verb::Registry, id : String, fallback : String,
                           overrides : Hash(String, Array(Verb::Chord)) = rebindable_overrides(registry),
                           profile : String = Settings.keymap_os) : String
      if chord = binding_for(registry, id, overrides, profile)
        display_label(chord)
      else
        fallback
      end
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

    # Decoder the editor's working copy (verb-id → Chord? where nil = unbound) into the
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
