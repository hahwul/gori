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
# in the menu spelling the app already uses for it ("space → o sort").
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
