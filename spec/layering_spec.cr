require "./spec_helper"

# The layering contract, executable. Core subsystems must not know that a surface exists:
# `store/`, `proxy/`, `probe/`, `fuzz/`, `miner/`, `discover/`, `sequencer/` and `oast/` may
# not reference `Tui::`, `CLI::` or `MCP::` in code. Dependencies run one way — surfaces
# depend on engines, engines depend on Store and the codecs, and nothing depends on a
# surface (AGENTS.md "Three surfaces, one engine layer"; DESIGN.md §2.1).
#
# This is the runnable form of the `grep -rnE '\b(Tui|CLI|MCP)::' …` self-check documented
# in AGENTS.md and DESIGN.md §2.1, over exactly the same file set.
#
# The assertion is "every hit is on a COMMENT line", NOT a hit count. A comment may point at
# a caller — naming the CLI formatter that delegates to an engine is useful, and several such
# comments exist today — while code may not. The number of those comments drifts as they are
# edited, which is precisely why counting them would be a spec that fails on prose changes
# while catching no layering violation.
#
# Crystal has no block comments, so a comment line is simply one whose `lstrip` starts with
# `#`. That is the whole definition, on purpose: a smarter tokenizer (tracking string
# literals, heredocs, trailing comments) would be more code than the rule it guards, and the
# rule only needs to separate "a sentence about a caller" from "a call into a surface".
describe "layering contract" do
  it "keeps every surface reference in the core subsystems on a comment line" do
    root = File.expand_path(File.join(__DIR__, ".."))
    # `authorize` is not in the AGENTS.md list because it did not exist when that list was
    # written. It is a core engine layer with all three surfaces hanging off it — exactly
    # the shape this contract governs — and it is clean today, so this is the one moment
    # adding it costs nothing.
    subsystems = %w[store proxy probe fuzz miner discover sequencer oast authorize]

    paths = [] of String
    subsystems.each do |name|
      paths.concat(Dir.glob(File.join(root, "src", "gori", name, "**", "*.cr")))
    end
    # The module files that sit alongside those directories. There is no `src/gori/proxy.cr`
    # — the proxy is directory-only — so it is absent from this half of the set.
    (subsystems - ["proxy"]).each do |name|
      path = File.join(root, "src", "gori", "#{name}.cr")
      paths << path if File.exists?(path)
    end
    paths.sort!

    surface = /\b(?:Tui|CLI|MCP)::/
    offenders = [] of String
    paths.each do |path|
      File.read_lines(path).each_with_index do |line, i|
        next unless line.matches?(surface)
        next if line.lstrip.starts_with?('#')
        offenders << "#{Path[path].relative_to(root)}:#{i + 1}: #{line.strip}"
      end
    end

    fail(<<-MSG) unless offenders.empty?
      core subsystems must not reference a surface (Tui::, CLI:: or MCP::) in code — \
      only in comments (AGENTS.md; DESIGN.md §2.1). Offending lines:
      #{offenders.join("\n")}
      MSG
  end
end
