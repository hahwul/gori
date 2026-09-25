require "../spec_helper"

# R1 of DESIGN.md §7 (2026-09-12, "one bare letter, one question"): a space-menu letter may
# differ from its verb's own chord, but it must never be a key the same tab answers with a
# DIFFERENT action. A hand that drops the `space` — or presses the letter the menu taught it
# on the tab itself — then does something else, and nothing says so.
#
# `validate_menu_keys!` checks menu against menu and `validate_chords!` chord against chord;
# this is the menu-against-chord check neither makes (#1274 WP0). It sweeps every place a
# bare key is answered before the menu ever sees it:
#
#   • the tab's OWN scope, under every OS profile × editor keyset (vim respells a bundle) —
#     except a verb whose chord is live only in sections the row is never drawn in
#     (`Definition#chord_sections`): there the press walks on to Global instead;
#   • the Editor scope, consulted AHEAD of the tab while a text editor pane has focus
#     (`Runner#resolve_verb_id`), so helix's `i` is "insert" in the Repeater request pane;
#   • the sub-tab strip's raw keys (`Runner#handle_subtabs_key`), which the keymap cannot
#     see — with the strip focused the menu shows COMMON + SUB-TABS;
#   • the Global fallback, for a letter the tab does not bind (or binds only pane-gated
#     elsewhere): a dropped space on a menu `c` silently stops capture.
#
# It covers the SHIPPED defaults. A user rebind can recreate a clash at runtime; the Hotkeys
# editor's Conflicts check owns that.
#
# ALLOWED starts as the violation list at the time the guard landed and only shrinks: every
# entry names the exact pair and why it stands, and the last example fails when an entry no
# longer violates, so a fix has to delete its own line.
module MenuLetterMeaning
  extend self

  alias Pair = {String, String}

  # Where `Runner#editor_pane?` is true, from each controller's own #editor_pane?: the
  # sections whose pane is a text editor, or nil when every view of the scope is one.
  EDITOR_VIEWS = {
    Gori::Verb::Scope::Decoder      => [:input],
    Gori::Verb::Scope::Jwt          => [:input],
    Gori::Verb::Scope::Cookie       => [:input],
    Gori::Verb::Scope::Repeater     => [:request, :target],
    Gori::Verb::Scope::Fuzzer       => [:template, :target],
    Gori::Verb::Scope::Notes        => nil,
    Gori::Verb::Scope::IssuesDetail => nil,
    Gori::Verb::Scope::ProjectDesc  => nil,
  } of Gori::Verb::Scope => Array(Symbol)?

  # `Runner#handle_subtabs_key`'s raw arms, as the verb-id suffix that answers the same
  # question from the menu (nil: no verb does — marking one chip is strip-only). Rename is
  # live on every strip but Notes (`Runner#renameable_subtabs?`).
  STRIP_KEYS = {
    'r' => {"rename", "rename-subtab"},
    't' => {"mark", nil},
    'T' => {"mark-all", "subtab-mark-all"},
    'f' => {"find", "find-subtab"},
    '/' => {"filter", "filter-subtabs"},
    'h' => {"nav", nil},
    'j' => {"nav", nil},
    'k' => {"nav", nil},
    'l' => {"nav", nil},
  }

  # Global letters whose fall-through is harmless: the scope lens is a reversible view
  # filter, so a dropped space re-filters the list and the next `s` puts it back.
  HARMLESS_GLOBALS = {"scope.toggle-lens"}

  def rows : Array(Gori::Verb::Definition)
    Gori::Verbs.registry.select do |v|
      !v.hidden? && v.menu_key && !v.scope.global? && !v.scope.editor?
    end
  end

  # The chord a typed menu letter would be read as on the tab (a typed capital is shift +
  # lowercase — `Keybind.from_event`).
  def chord_for(k : Char) : Gori::Verb::Chord
    k.ascii_uppercase? ? Gori::Verb::Chord.new(k.downcase.to_s, shift: true) : Gori::Verb::Chord.new(k.to_s)
  end

  def editor_view?(v : Gori::Verb::Definition) : Bool
    return false unless EDITOR_VIEWS.has_key?(v.scope)
    return true unless secs = EDITOR_VIEWS[v.scope]
    v.section == :common || Gori::Verb::Registry::SUBTAB_SECTIONS.includes?(v.section) ||
      secs.includes?(v.section)
  end

  # Every view this row can appear in is an editor pane, so the Editor scope answers first
  # and a letter it binds never falls through to Global.
  def editor_only?(v : Gori::Verb::Definition) : Bool
    return false unless EDITOR_VIEWS.has_key?(v.scope)
    return true unless secs = EDITOR_VIEWS[v.scope]
    secs.includes?(v.section)
  end

  class_getter strip_scopes : Set(Gori::Verb::Scope) do
    Gori::Verbs.registry.compact_map do |v|
      v.scope if Gori::Verb::Registry::SUBTAB_SECTIONS.includes?(v.section)
    end.to_set
  end

  # Every (menu verb, the other meaning) pair, with the configurations it shows up under.
  def violations : Hash(Pair, Set(String))
    found = Hash(Pair, Set(String)).new { |h, k| h[k] = Set(String).new }
    menu = rows
    Gori::Verb::OsProfile::Os.each do |os|
      Gori::Verb::Keyset::Kind.each do |ks|
        keymap = Gori::Verb::Keymap.build(Gori::Verbs.registry, os, Gori::Verb::Keymap::NO_OVERRIDES, ks)
        where = "#{Gori::Verb::Keyset.name_of(ks)}/#{os.to_s.downcase}"
        menu.each { |v| check_keymap(found, keymap, v, where) }
      end
    end
    menu.each do |v|
      if other = strip_clash(v)
        found[{v.id, other}] << "strip"
      end
    end
    found
  end

  # The Editor link first (it answers ahead of the tab in an editor pane), then the tab's own
  # scope, then — for a letter the tab leaves unbound, or binds only to a verb whose chord is
  # not live where this row is drawn — the Global fallback.
  private def check_keymap(found, keymap : Gori::Verb::Keymap, v : Gori::Verb::Definition, where : String) : Nil
    chord = chord_for(v.menu_key.not_nil!)
    e = editor_view?(v) ? keymap.lookup_in(chord, Gori::Verb::Scope::Editor) : nil
    e = nil if e && !live_where_shown?(Gori::Verbs.registry[e], v)
    found[{v.id, e}] << where if e && e != v.id
    id = keymap.lookup_in(chord, v.scope)
    if id && id != v.id && live_where_shown?(Gori::Verbs.registry[id], v)
      found[{v.id, id}] << where
    end
    return if id && live_everywhere_shown?(Gori::Verbs.registry[id], v)
    if g = global_fallthrough(keymap, chord, v, e)
      found[{v.id, g}] << where
    end
  end

  # The sections this row is drawn in, or nil for every one: a COMMON row and a SUB-TABS
  # bucket row ride every view of the scope (#1055); anything else only its own section.
  def shown_in(v : Gori::Verb::Definition) : Array(Symbol)?
    return nil if v.section == :common || Gori::Verb::Registry::SUBTAB_SECTIONS.includes?(v.section)
    [v.section]
  end

  # Is `other`'s chord live in SOME section this row is drawn in (`Definition#chord_sections`)?
  # A key gated to the response pane is no clash for a row the request pane alone draws —
  # there the press is not that verb at all.
  def live_where_shown?(other : Gori::Verb::Definition, v : Gori::Verb::Definition) : Bool
    return true unless secs = other.chord_sections
    return true unless shown = shown_in(v)
    shown.any? { |sec| secs.includes?(sec) }
  end

  # …in EVERY section this row is drawn in. Where it is not, the press walks on past the tab
  # scope (`Keymap#resolve`) and may reach Global — so a pane gate on `c` is still caught.
  def live_everywhere_shown?(other : Gori::Verb::Definition, v : Gori::Verb::Definition) : Bool
    return true unless secs = other.chord_sections
    return false unless shown = shown_in(v)
    shown.all? { |sec| secs.includes?(sec) }
  end

  private def global_fallthrough(keymap : Gori::Verb::Keymap, chord : Gori::Verb::Chord,
                                 v : Gori::Verb::Definition, editor : String?) : String?
    return nil if editor && editor_only?(v)
    g = keymap.lookup_in(chord, Gori::Verb::Scope::Global)
    return nil if g.nil? || g == v.id || HARMLESS_GLOBALS.includes?(g)
    g
  end

  # A row the strip-focused card shows (COMMON + SUB-TABS) on a letter the strip answers raw.
  private def strip_clash(v : Gori::Verb::Definition) : String?
    return nil unless strip_scopes.includes?(v.scope)
    return nil unless v.section == :common || Gori::Verb::Registry::SUBTAB_SECTIONS.includes?(v.section)
    return nil unless raw = STRIP_KEYS[v.menu_key.not_nil!]?
    name, suffix = raw
    return nil if name == "rename" && v.scope.notes?
    return nil if suffix && v.id.ends_with?(".#{suffix}")
    "strip:#{name}"
  end
end

# The standing exceptions, keyed by the exact pair so a later, unrelated row on the same
# letter is still caught. The #1274 work packages delete their own lines.
MENU_LETTER_ALLOWED = {
  # Link and add-host on nav letters — settled with the h/j/k/l decision after the families land.
  {"link.history.attach", "body.up"}          => "WP1 hjkl decision: Link is `k`, the list's up key",
  {"link.history-detail.attach", "detail.up"} => "WP1 hjkl decision: Link is `k`, the detail's up key",
  {"detail.add-host", "detail.prev-pane"}     => "WP1 hjkl decision: add-host is `h`, the detail's pane-left key",
  {"link.repeater.attach", "strip:nav"}       => "WP1 hjkl decision: Link is `k`, the strip's up key",
  {"link.fuzzer.attach", "strip:nav"}         => "WP1 hjkl decision: Link is `k`, the strip's up key",
  {"link.miner.attach", "strip:nav"}          => "WP1 hjkl decision: Link is `k`, the strip's up key",
  {"notes.links", "strip:nav"}                => "WP1 hjkl decision: Links is `l`, the strip's right key",
  # WP2 — menu letters another verb of the same tab answers.
  {"history.discover", "history.delete"}                 => "WP2 #1: `d` deletes on the list; Discover moves into Send flow to…",
  {"repeater.toggle-hex", "repeater.select-line"}        => "WP2 #2: hex moves into Display…",
  {"detail.copy-flow", "detail.issue"}                   => "WP2 #5: folds into Copy as… → Raw request",
  {"detail.sequence", "detail.close"}                    => "WP2 #6: Sequencer moves into Send flow to…",
  {"issue.set-severity", "issue.goto-link"}              => "WP2 #7: documented at verbs/issues.cr (severity keeps `s` in the menu)",
  {"probe.scope-toggle", "probe.open-evidence"}          => "WP2 #8: documented in DESIGN.md §7 2026-09-12 (Probe's `s` is go to source)",
  {"mine.filter-subtabs", "mine.filter"}                 => "WP2 #9: the strip owns `/` in every view since #1055",
  {"comparer.close-subtab", "comparer.swap"}             => "WP2 #11: the strip's `w` close vs the R2 table's `w` swap",
  {"comparer.subtab-mark-clear", "comparer.next-change"} => "WP2 #12: the strip's `N` vs ⇧N next change",
  {"fuzzer.send-to", "fuzz.save-results"}                => "WP2 #14: save results moves to the Export letter",
  {"oast.copy", "oast.copy-callback"}                    => "false positive: the LIST's controller arm owns bare `y` (verbs/read_edit.cr)",
  {"colormarker.color-add", "colormarker.add"}           => "false positive: handle_colors_key answers `a` in the colours pane",
  {"colormarker.color-edit", "colormarker.edit"}         => "false positive: handle_colors_key answers `e` in the colours pane",
  {"colormarker.color-delete", "colormarker.delete"}     => "false positive: handle_colors_key answers `d` in the colours pane",
  # WP2 #10 and WP6 — the strip's `r` renames and `t` marks a chip.
  {"repeater.send", "strip:rename"}      => "WP2 #10: strip `r` renames, the menu's `r` sends (hotkeys.md)",
  {"fuzz.run", "strip:rename"}           => "WP2 #10: strip `r` renames, the menu's `r` runs (hotkeys.md)",
  {"mine.run", "strip:rename"}           => "WP2 #10: strip `r` renames, the menu's `r` runs (hotkeys.md)",
  {"sequence.run", "strip:rename"}       => "WP2 #10: strip `r` renames, the menu's `r` runs (hotkeys.md)",
  {"repeater.tag-subtab", "strip:mark"}  => "WP2 #10: Tag leaves `t` for a Mark sub-tab row",
  {"comparer.toggle-pane", "strip:mark"} => "WP6: `t` is a strip letter; the pane toggle moves into Display…",
  # Decision 10 — a letter the tab does not bind falls through to Global on a dropped space.
  {"history.compare", "capture.toggle"}       => "Decision 10: Comparer moves into Send flow to…",
  {"detail.compare", "capture.toggle"}        => "Decision 10: Comparer moves into Send flow to…",
  {"sitemap.compare", "capture.toggle"}       => "Decision 10: Comparer moves into Send flow to…",
  {"repeater.clear-marks", "capture.toggle"}  => "Decision 10: `c` reaches Global capture on a dropped space",
  {"fuzz.clear-marks", "capture.toggle"}      => "Decision 10: `c` reaches Global capture on a dropped space",
  {"issues.set-status", "capture.toggle"}     => "Decision 10: `c` reaches Global capture on a dropped space",
  {"issue.set-status", "capture.toggle"}      => "Decision 10: `c` reaches Global capture on a dropped space",
  {"jwt.copy-attack", "capture.toggle"}       => "Decision 10: `c` reaches Global capture on a dropped space",
  {"rewriter.duplicate", "capture.toggle"}    => "Decision 10: `c` reaches Global capture on a dropped space",
  {"colormarker.duplicate", "capture.toggle"} => "Decision 10: `c` reaches Global capture on a dropped space",
  {"sequence.promote", "intercept.toggle"}    => "Decision 10: file-issue is `a` elsewhere; `i` holds all traffic on a dropped space",
  {"diff.issue", "intercept.toggle"}          => "Decision 10: file-issue is `a` elsewhere; `i` holds all traffic on a dropped space",
  # The Editor scope answers ahead of the tab while a text editor pane has focus.
  {"repeater.insert-marker", "editor.insert"} => "Editor: `i` enters insert in the request pane",
  {"fuzz.insert-marker", "editor.insert"}     => "Editor: `i` enters insert in the template pane",
  {"fuzz.toggle-sni", "editor.insert"}        => "Editor: `i` enters insert in the target pane; SNI moves into Protocol…",
  # vim keyset only: ⇧V is select-line and the editor gains bare `/` `a` `g` `⇧G`.
  {"repeater.toggle-decoded", "repeater.select-line"} => "vim: ⇧V selects a line; the envelope toggle moves into Display…",
  {"issue.set-cvss", "issue.select-line"}             => "vim: ⇧V selects a line",
  {"repeater.filter-subtabs", "editor.find"}          => "vim: editor `/` finds; the SUB-TABS `/` is uniform on all nine strips",
  {"fuzz.filter-subtabs", "editor.find"}              => "vim: editor `/` finds; the SUB-TABS `/` is uniform on all nine strips",
  {"decoder.filter-subtabs", "editor.find"}           => "vim: editor `/` finds; the SUB-TABS `/` is uniform on all nine strips",
  {"jwt.filter-subtabs", "editor.find"}               => "vim: editor `/` finds; the SUB-TABS `/` is uniform on all nine strips",
  {"cookie.filter-subtabs", "editor.find"}            => "vim: editor `/` finds; the SUB-TABS `/` is uniform on all nine strips",
  {"notes.filter-subtabs", "editor.find"}             => "vim: editor `/` finds; the SUB-TABS `/` is uniform on all nine strips",
  {"repeater.auto-mark", "editor.append"}             => "vim: `a` appends in the request pane",
  {"fuzz.automark", "editor.append"}                  => "vim: `a` appends in the template pane",
  {"jwt.cycle-alg", "editor.append"}                  => "vim: `a` appends in the input pane",
  {"cookie.cycle-format", "editor.append"}            => "vim: `a` appends in the input pane",
  {"repeater.send-group", "editor.top"}               => "vim: `g` jumps to the top of the request pane",
  {"cookie.cycle-algorithm", "editor.top"}            => "vim: `g` jumps to the top of the input pane",
  {"issue.goto-link", "editor.top"}                   => "vim: `g` jumps to the top of the notes pane",
  {"notes.goto", "editor.top"}                        => "vim: `g` jumps to the top of the note",
  {"repeater.send-race", "editor.bottom"}             => "vim: ⇧G jumps to the bottom of the request pane",
} of MenuLetterMeaning::Pair => String

describe "space-menu letters vs the keys the same tab answers (R1)" do
  found = MenuLetterMeaning.violations

  it "names no key the tab answers with a different action" do
    fresh = found.keys.reject { |pair| MENU_LETTER_ALLOWED.has_key?(pair) }
    fresh.map { |(menu, other)| "#{menu} ~ #{other} (#{found[{menu, other}].to_a.sort.join(", ")})" }
      .should eq([] of String)
  end

  it "keeps no allowlist entry that has stopped violating" do
    MENU_LETTER_ALLOWED.keys.reject { |pair| found.has_key?(pair) }.should eq([] of MenuLetterMeaning::Pair)
  end

  it "gives every allowlist entry a reason" do
    MENU_LETTER_ALLOWED.each { |pair, why| why.strip.should_not be_empty, pair.to_s }
  end
end
