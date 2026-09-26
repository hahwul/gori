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
#     (`Runner#resolve_verb_id`), so helix's `i` is "insert" in the Repeater request pane —
#     except the `vim` keyset's motions (`VIM_MOTIONS`), a rule rather than allowlist lines;
#   • the sub-tab strip's raw keys (`Runner#handle_subtabs_key`), which the keymap cannot
#     see — with the strip focused the menu shows COMMON + SUB-TABS;
#   • the Global fallback, for a letter the tab does not bind (or binds only pane-gated
#     elsewhere): a dropped space on a menu `c` silently stops capture.
#
# A family row (#1274 WP9) is a menu letter like any other at level 1, so its key is swept
# too, as the row `family:<id>` drawn wherever the scope registers a member. Level-2 letters
# are exempt: they are reached after two keys, never by a dropped space (DESIGN.md §7). The
# SUB-TABS bucket is one such row in a pane view, `family:subtabs` on `T` (#1274 Decision
# 8); its rows are level-1 letters only where the strip or the tab bar has focus, unless
# `pinned:`.
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
    'e' => {"rename", "rename-subtab"},
    't' => {"mark", "subtab-mark"},
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

  # The `vim` keyset's motions (`Keyset::VIM`), exempt where they meet a menu letter under
  # that keyset only (#1295). A dropped space there moves the caret, opens find, selects a
  # line or enters INSERT one column right: what a vim hand expects from the key, and nothing
  # a second key cannot undo. The set names verbs, never letters, and only ones that neither
  # write the buffer nor reach anything outside the pane: undo (`u`) is not here, and neither
  # is helix's `i` insert, which moved Insert marker to `I` instead (#1274).
  VIM_MOTIONS = Set{"editor.append", "editor.top", "editor.bottom", "editor.find"} +
                Gori::Verb::Keyset::SELECT_LINE_IDS.to_set

  def vim_motion?(ks : Gori::Verb::Keyset::Kind, other : String) : Bool
    ks.vim? && VIM_MOTIONS.includes?(other)
  end

  # One level-1 row: a verb on its `menu_key`, or a family on its key. `sections` is where it
  # is drawn — nil for every view of the scope (a COMMON row, a pinned SUB-TABS row, or a
  # family with a member in COMMON), else the sections: the pane's own, the strip's two for
  # a SUB-TABS row, every pane for the Sub-tabs… row.
  record Row, id : String, key : Char, scope : Gori::Verb::Scope, sections : Array(Symbol)?

  def rows : Array(Row)
    reg = Gori::Verbs.registry
    listed = reg.select { |v| !v.hidden? && !v.scope.global? && !v.scope.editor? }
    verbs = listed.compact_map do |v|
      next unless k = v.menu_key
      Row.new(v.id, k, v.scope, drawn_in(v))
    end
    families = listed.select(&.member?).group_by { |v| {v.family.not_nil!, v.scope} }.map do |(fid, scope), members|
      secs = members.map(&.section).uniq!
      Row.new("family:#{fid}", reg.family(fid).not_nil!.key, scope, secs.includes?(:common) ? nil : secs)
    end
    fold = Gori::Verb::Registry::SUBTABS_FOLD
    folds = strip_scopes.map do |scope|
      panes = listed.select { |v| v.scope == scope }.map(&.section).uniq!.reject { |sec| strip_section?(sec) }
      Row.new("family:#{fold.id}", fold.key, scope, (panes + [:common]).uniq!)
    end
    verbs + families + folds
  end

  def strip_section?(section : Symbol) : Bool
    Gori::Verb::Registry::SUBTAB_SECTIONS.includes?(section)
  end

  # nil for a COMMON row and a pinned SUB-TABS row (every view); the strip's own two sections
  # for any other SUB-TABS row, which a pane view folds into Sub-tabs…; else its section.
  def drawn_in(v : Gori::Verb::Definition) : Array(Symbol)?
    return nil if v.section == :common || (strip_section?(v.section) && v.pinned?)
    return Gori::Verb::Registry::SUBTAB_SECTIONS.to_a if strip_section?(v.section)
    [v.section]
  end

  # The chord a typed menu letter would be read as on the tab (a typed capital is shift +
  # lowercase — `Keybind.from_event`).
  def chord_for(k : Char) : Gori::Verb::Chord
    k.ascii_uppercase? ? Gori::Verb::Chord.new(k.downcase.to_s, shift: true) : Gori::Verb::Chord.new(k.to_s)
  end

  def editor_view?(v : Row) : Bool
    return false unless EDITOR_VIEWS.has_key?(v.scope)
    return true unless secs = EDITOR_VIEWS[v.scope]
    return true unless shown = v.sections
    shown.any? { |sec| secs.includes?(sec) }
  end

  # Every view this row can appear in is an editor pane, so the Editor scope answers first
  # and a letter it binds never falls through to Global.
  def editor_only?(v : Row) : Bool
    return false unless EDITOR_VIEWS.has_key?(v.scope)
    return true unless secs = EDITOR_VIEWS[v.scope]
    return false unless shown = v.sections
    shown.all? { |sec| secs.includes?(sec) }
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
        menu.each { |v| check_keymap(found, keymap, v, where, ks) }
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
  private def check_keymap(found, keymap : Gori::Verb::Keymap, v : Row, where : String,
                           ks : Gori::Verb::Keyset::Kind) : Nil
    chord = chord_for(v.key)
    e = editor_view?(v) ? keymap.lookup_in(chord, Gori::Verb::Scope::Editor) : nil
    e = nil if e && !live_where_shown?(Gori::Verbs.registry[e], v)
    note(found, v, e, where, ks)
    id = keymap.lookup_in(chord, v.scope)
    note(found, v, id, where, ks) if id && live_where_shown?(Gori::Verbs.registry[id], v)
    return if id && live_everywhere_shown?(Gori::Verbs.registry[id], v)
    note(found, v, global_fallthrough(keymap, chord, v, e), where, ks)
  end

  # Records `other` as a second meaning of this row's letter, unless it is the row's own verb
  # or a vim motion under the vim keyset.
  private def note(found, v : Row, other : String?, where : String, ks : Gori::Verb::Keyset::Kind) : Nil
    return if other.nil? || other == v.id || vim_motion?(ks, other)
    found[{v.id, other}] << where
  end

  # The sections this row is drawn in, or nil for every one: a COMMON row and a SUB-TABS
  # bucket row ride every view of the scope (#1055); anything else only its own section(s).
  def shown_in(v : Row) : Array(Symbol)?
    v.sections
  end

  # Is `other`'s chord live in SOME section this row is drawn in (`Definition#chord_sections`)?
  # A key gated to the response pane is no clash for a row the request pane alone draws —
  # there the press is not that verb at all.
  def live_where_shown?(other : Gori::Verb::Definition, v : Row) : Bool
    return true unless secs = other.chord_sections
    return true unless shown = shown_in(v)
    shown.any? { |sec| secs.includes?(sec) }
  end

  # …in EVERY section this row is drawn in. Where it is not, the press walks on past the tab
  # scope (`Keymap#resolve`) and may reach Global — so a pane gate on `c` is still caught.
  def live_everywhere_shown?(other : Gori::Verb::Definition, v : Row) : Bool
    return true unless secs = other.chord_sections
    return false unless shown = shown_in(v)
    shown.all? { |sec| secs.includes?(sec) }
  end

  private def global_fallthrough(keymap : Gori::Verb::Keymap, chord : Gori::Verb::Chord,
                                 v : Row, editor : String?) : String?
    return nil if editor && editor_only?(v)
    g = keymap.lookup_in(chord, Gori::Verb::Scope::Global)
    return nil if g.nil? || g == v.id || HARMLESS_GLOBALS.includes?(g)
    g
  end

  # A row the strip-focused card shows (COMMON + SUB-TABS) on a letter the strip answers raw.
  private def strip_clash(v : Row) : String?
    return nil unless strip_scopes.includes?(v.scope)
    return nil unless (secs = v.sections).nil? || secs.all? { |sec| strip_section?(sec) }
    return nil unless raw = STRIP_KEYS[v.key]?
    name, suffix = raw
    return nil if name == "rename" && v.scope.notes?
    return nil if suffix && v.id.ends_with?(".#{suffix}")
    "strip:#{name}"
  end
end

# The standing exceptions, keyed by the exact pair so a later, unrelated row on the same
# letter is still caught. The #1274 work packages delete their own lines.
MENU_LETTER_ALLOWED = {
  # WP2 — menu letters another verb of the same tab answers.
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

  it "exempts only vim motions that leave the buffer and the network alone" do
    vim = Gori::Verb::Keyset::VIM
    MenuLetterMeaning::VIM_MOTIONS.each do |id|
      v = Gori::Verbs.registry[id]? || fail "#{id} is gone — drop it from VIM_MOTIONS"
      vim.has_key?(id).should be_true, "#{id} is not a vim keyset row"
      # Never the send, triage, danger or wipe band: a motion only moves or selects.
      {:none, :view}.should contain(v.group), "#{id} sits in the #{v.group} band"
    end
    MenuLetterMeaning::VIM_MOTIONS.should_not contain("editor.undo")
    MenuLetterMeaning::VIM_MOTIONS.should_not contain("editor.insert")
  end

  it "gives every allowlist entry a reason" do
    MENU_LETTER_ALLOWED.each { |pair, why| why.strip.should_not be_empty, pair.to_s }
  end
end
