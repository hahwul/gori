require "../spec_helper"

# CONTRACT: every `{verb.id}` token a hint carries actually EXPANDS.
#
# `Hotkeys.expand` resolves a token to the chord that verb is bound to, and when it cannot it
# leaves the token ALONE — the deliberate fallback for a render that has no registry. On a
# footer strip that fallback is not graceful degradation, it is the literal string
# `{fuzz.sort} sort` printed into the status line, curly braces and all, for a verb that has
# no chord because it is MENU-ONLY by decision (verbs/history.cr, key audit F2). The operator
# then presses the only key the line names — `o` — and gets "nothing bound here".
#
# Two ways to fail, and the spec names them apart because the fixes differ: a token naming no
# verb at all is a typo or a rename that missed a caller; a token naming a real verb with no
# chord is a hint promising a key the key budget deliberately did not spend. That one belongs
# in the menu spelling, `{space:fuzz.sort} sort` (see the contract at the foot of this file).
#
# Source-scanned, like `layering_spec`: the templates live in string literals inside `case`
# arms that no roster can reach, so reading them off disk is the only way to see them all.
describe "hint templates — every verb token expands to a chord" do
  it "names a registered verb, and one that has a key" do
    registry = Gori::Verbs.registry
    root = File.expand_path("../../src", __DIR__)
    # `Hotkeys::VERB_TOKEN_RE` narrowed two ways for a SOURCE scan. It runs on strings whose
    # Crystal interpolations are already resolved, so `#{…}` never reaches it; here the raw
    # text is full of them, hence the `#` lookbehind. And a verb id always carries a dot
    # (`scope.action`), which is what separates a token from an interpolated local.
    token = /(?<!#)\{([a-z][a-z0-9_-]*(?:\.[a-z0-9_-]+)+)\}/
    # Comment lines are skipped, the way `layering_spec` reads its hits: the mechanism is
    # DESCRIBED as `{verb.id}` in five places, and that placeholder is not a token to expand.
    ids = Set(String).new
    Dir.glob(File.join(root, "**", "*.cr")).each do |file|
      File.each_line(file) do |line|
        next if line.lstrip.starts_with?('#')
        line.scan(token) { |m| ids << m[1] }
      end
    end
    ids.size.should be > 100 # the scan found the templates at all

    unknown = ids.select { |id| registry[id]?.nil? }
    unknown.to_a.sort.should be_empty

    chordless = ids.select do |id|
      Gori::Hotkeys.default_for(registry, id, Gori::Settings.keymap_os).nil?
    end
    chordless.to_a.sort.should be_empty
  end
end

# CONTRACT (#1274): a space-menu letter in UI text comes from the registry.
#
# A hand-typed `space → t` is checked by nothing, and letters move — the Help sheet printed
# three wrong ones, the Sitemap filter dropdown said `T` for a Tag path that is `m`, and a
# toast still named `b` only by luck. Text that names a menu row spells it `{space:verb.id}`
# (Hotkeys.expand / Hotkeys.expand_menu_paths), which reads the verb's `menu_key`. Naming the
# row by its TITLE ("space → Mine parameters") is fine: that names no letter.
#
# Comment lines are skipped the way the scan above skips them; a comment may say what a key
# is today, and it is not drawn.
describe "hint templates — space-menu letters come from the registry" do
  root = File.expand_path("../../src/gori", __DIR__)
  lines = [] of {String, Int32, String}
  Dir.glob(File.join(root, "**", "*.cr")).each do |file|
    File.read_lines(file).each_with_index(1) do |line, n|
      next if line.lstrip.starts_with?('#')
      lines << {file.sub(root + "/", ""), n, line}
    end
  end

  it "every {space:verb.id} token names a verb with a route (a menu row, or the palette)" do
    registry = Gori::Verbs.registry
    ids = Set(String).new
    lines.each { |(_, _, line)| line.scan(Gori::Hotkeys::SPACE_TOKEN_RE) { |m| ids << m[1] } }
    ids.size.should be > 15
    ids.reject { |id| Gori::Hotkeys.route(registry, id) }.to_a.sort.should be_empty
    # A palette-only verb's token reads as its palette route, never as a menu path (#1282).
    ids.select { |id| registry[id].palette_only? }.each do |id|
      Gori::Hotkeys.expand_menu_paths(registry, "{space:#{id}}").should_not start_with("space →")
    end
  end

  it "names a palette-only verb through its token, not a hand-written route" do
    # `Hotkeys.route` spells a palette-only verb's route (#1282): its chord when it has one,
    # else `^P → <title>`. A hand-typed `^P → Minimize request` or `space → M` for one would
    # say whatever it said the day it was typed; the token follows the verb.
    titles = Gori::Verbs.registry.select(&.palette_only?).map(&.title)
    hits = lines.select { |(_, _, line)| titles.any? { |t| line.includes?("→ #{t}") } }
      .map { |(file, n, line)| "#{file}:#{n}: #{line.strip}" }
    hits.should be_empty
  end

  it "leaves no literal `space → <key>` (or `space ▸ <key>`) in a string" do
    # One key, then anything that is not part of a word: `space → t`, `space → k/j`, `space → /`,
    # and the same after `▸`, which the Repeater's %%% refusal once spelled `space ▸ g` in.
    # A title (`space → Mine`, `space ▸ SUB-TABS`), a quoted one (`space → "Discover here"`) or
    # an interpolation (Hotkeys.menu_path's own `space → #{key}`, the one place a path is
    # spelled) is not a letter.
    literal = /space [→▸] (?!#\{)[^\s\w"\\…]|space [→▸] \w(?!\w)/
    hits = lines.select { |(_, _, line)| line.matches?(literal) }
      .map { |(file, n, line)| "#{file}:#{n}: #{line.strip}" }
    hits.should be_empty
  end

  it "leaves no hand-written `␣<key>` chip in a string (#1295)" do
    # The compact spelling on a border badge or a tight hint — ` ␣Pr:FRAME `, `␣Zs shows them` —
    # names a menu path as surely as `space → P r` does, and it went stale the same way. It is
    # `Hotkeys.menu_chip`'s to spell. `␣` followed by a space is the space BAR as a key
    # (`␣ toggle`), and an interpolation builds the path from the registry.
    literal = /␣(?!#\{)[^\s"\\]/
    hits = lines.select { |(_, _, line)| line.matches?(literal) }
      .map { |(file, n, line)| "#{file}:#{n}: #{line.strip}" }
    hits.should be_empty
  end
end
