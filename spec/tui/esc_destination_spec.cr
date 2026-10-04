require "../spec_helper"

# `esc tabs` is a PROMISE about where escape lands, and on nine surfaces it was wrong.
#
# `Runner#focus_pane` downgrades `:subtabs` to `:menu` only when no strip is shown
# (`runner.cr`, "never strand focus on an absent strip"). Sitemap, Discover, OAST, Notes,
# Decoder, JWT and Probe's Rules list all show one, so escape stopped at the sub-tab strip
# while their hints said it went to the tab bar — one level further than it goes. The Project
# tab had the right wording all along (`esc sub-tabs`), which is what this pins the rest to.
#
# Checked against the CODE rather than a list of strings: a controller that sends escape to
# `:subtabs` must not promise `esc tabs` in the same file. That way a new tab inherits the
# rule instead of a hand-maintained exemption list.
describe "the esc hint names where esc actually goes" do
  it "never says `esc tabs` where EVERY escape lands on the sub-tab strip" do
    # The condition is "every", not "any", and that is what makes this checkable without an
    # exemption list. A tab may legitimately route escape both ways: Probe sends it to the
    # strip on the Rules sub-tab (`probe_controller`) and to the tab bar on Findings
    # (`verbs/probe.cr`, `probe.leave`), so `esc tabs` is true on one of its two hints. A
    # controller with NO route to `:menu` has no such defence — every `esc tabs` in it is a
    # promise nothing keeps.
    root = File.join(__DIR__, "..", "..", "src", "gori")
    offenders = [] of String
    glob_files(root, "tui", "controllers", "*.cr").sort.each do |path|
      src = File.read(path)
      # `esc sub-tabs` contains `esc tabs` as a substring; the preceding char separates them.
      next unless src.matches?(/[^-]esc tabs/)
      # BOTH files decide where escape goes, and which one owns it varies: Sitemap and
      # Discover route it from their verbs, Probe and OAST from their controllers. Reading
      # only the controller made this check silently miss the two verb-routed tabs — it
      # passed a control run that reintroduced Sitemap's wrong hint.
      name = File.basename(path).sub("_controller.cr", ".cr")
      verbs_path = File.join(root, "verbs", name)
      verbs = File.exists?(verbs_path) ? File.read(verbs_path) : ""
      # File-level, not line-level. An escape handler is routinely several lines from the
      # focus call it ends in (`jwt_controller`: `commit` then `request_focus(:subtabs)` inside
      # an else-branch), so a one-line regex saw only the terse `when key.escape? then …`
      # controllers and let the multi-line ones through — it passed a control run that
      # reintroduced JWT's wrong hint. The cost of the looser test is that a `:menu` route
      # reached by some key OTHER than escape counts as a defence; that is acceptable here,
      # because it can only ever make this check quieter, never wrong about a file it flags.
      # CODE only. Reading whole files means comments count too, and the comment in
      # `verbs/oast.cr` explaining why its `focus_pane(:menu)` verbs were REMOVED read as a
      # live `:menu` route and shielded OAST from this very check.
      code = ->(text : String) do
        text.lines.reject(&.lstrip.starts_with?('#')).join('\n')
      end
      src_code = code.call(src)
      verbs_code = code.call(verbs)
      routes = ->(pane : String) do
        src_code.includes?("request_focus(:#{pane})") || verbs_code.includes?("focus_pane(:#{pane})")
      end
      next unless routes.call("subtabs")
      offenders << File.basename(path) unless routes.call("menu")
    end
    offenders.should be_empty
  end

  it "leaves no escape verb registered where a controller already claims the key" do
    # `Verb` registrations for escape are unreachable on any scope whose controller answers
    # escape and returns true. Two sat on the OAST sub-tabs saying `focus_pane(:menu)` while
    # the live handler went to `:subtabs` — dead code that also documented the wrong
    # destination, which is how the hint came to say it too.
    verbs_dir = File.join(__DIR__, "..", "..", "src", "gori", "verbs")
    oast = File.read(File.join(verbs_dir, "oast.cr"))
    oast.should_not contain(%(Verb::Chord.new("escape")))
  end
end
