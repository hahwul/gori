require "../spec_helper"

# What the MCP catalogue costs a client, and the guide's account of it (#1137).
#
# An MCP client loads every advertised tool into the model's context before the first
# question and keeps it there for the session, so the size of `tools/list` is a product
# number, not an implementation detail. Every place gori ever wrote it down had drifted by
# the time #1137 measured it: the guide said "about 160 tools" and "--read-only cuts it to 53"
# of a 179/62 registry, the `--tools` help and two comments said ~43k tokens of a catalogue
# that had grown past 200 KB. So the numbers now live in exactly one checked place — the
# guide's table — and this file is the check: a row whose count is wrong, or whose size is
# off by more than SIZE_TOLERANCE, fails with the row it should say instead.

private GUIDES = {
  "en" => File.expand_path("../../docs/content/guide/mcp.md", __DIR__),
  "ko" => File.expand_path("../../docs/content/guide/mcp.ko.md", __DIR__),
}

# How far a documented size may sit from the measured one before the row is wrong. Counts are
# exact (a tool added is a row to update); sizes are rounded prose, and a reworded description
# should not fail the build — a tenth of the catalogue should.
private SIZE_TOLERANCE = 0.10

# The flags in a row's first cell (`gori mcp`, `--read-only`, `--tools=@recon --read-only`),
# read the way `gori mcp` reads them. nil for a row that is not a start command.
private def row_flags(cell : String) : {String?, Bool}?
  code = cell.strip.match(/\A`([^`]+)`\z/).try(&.[1])
  return nil unless code
  words = code.split
  words.shift(2) if words.first(2) == ["gori", "mcp"]
  return nil unless words.all?(&.starts_with?("--"))
  spec = nil.as(String?)
  allow_actions = true
  words.each do |w|
    case w
    when "--read-only"             then allow_actions = false
    when .starts_with?("--tools=") then spec = w.lchop("--tools=").strip('\'')
    else                                return nil
    end
  end
  {spec, allow_actions}
end

private def filter_for(spec : String?) : Gori::MCP::ToolFilter?
  spec.try { |sp| Gori::MCP::ToolFilter.parse(sp, Gori::MCP::Tools::TOOL_NAMES).as(Gori::MCP::ToolFilter) }
end

private def measured(spec : String?, allow_actions : Bool) : {Int32, Int32}
  json = Gori::MCP::Tools.catalogue_json(filter_for(spec), allow_actions)
  {JSON.parse(json).as_a.size, json.bytesize}
end

# A tool DESCRIPTION naming a tool the profile does not serve, and why that is not an
# instruction the agent will act on. Everything else a member's schema names has to be IN the
# profile: the model reads a description as fact, so "use ql_explain to see which terms would
# drop" on a server without ql_explain is a call spent on UNKNOWN_TOOL. Keyed
# "member -> named"; each entry must still occur (see the example), so the list cannot outlive
# the text it excuses.
private INCIDENTAL = {
  "ql_reference -> list_sitemap"            => "lists the query language's consumers",
  "ql_explain -> list_sitemap"              => "lists the query language's consumers",
  "ql_explain -> probe_scan"                => "lists every tool that would refuse the query",
  "list_history -> list_views"              => "`view` takes a saved view's name; the operator can give it",
  "get_response_body_chunk -> send_request" => "names a producer of truncated output, not a step",
  "operator_messages -> list_events"        => "a cursor analogy (\"forward-cursored like list_events\")",
  "list_sitemap -> set_sitemap_tag"         => "says where an operator's tag comes from",
  "probe_issues -> probe_scan"              => "a contrast (\"unlike probe_scan's stateless rescan\")",
  "probe_issues -> probe_delete"            => "the third triage verb, left out of @recon on purpose: it erases the record",
  "list_env -> send_websocket"              => "names where env tokens are substituted",
  "send_request -> send_websocket"          => "only for a WebSocket repeater id; @recon replays HTTP",
}

private def table_cells(line : String) : Array(String)
  line.strip.strip('|').split('|').map(&.strip)
end

describe "MCP catalogue size" do
  # The banner's number is only worth printing if it is the one the client is handed. A bound
  # server lists through the same `Tools#list` — the claim `catalogue_json` rests on is that
  # nothing about the binding reaches the listing, so hold it to that, byte for byte.
  it "weighs exactly the listing a bound server sends" do
    # `with_store_env`: binding a Tools swaps the process-global Env layer to this store's.
    with_store_env do |store|
      [{nil, true}, {nil, false}, {"@recon", true}, {"@minimal", false}].each do |(spec, allow_actions)|
        filter = filter_for(spec)
        bound = Gori::MCP::Tools.new(store, allow_actions, false, tool_filter: filter)
        sent = JSON.build { |j| bound.list(j) }
        Gori::MCP::Tools.catalogue_json(filter, allow_actions).should eq(sent), "--tools=#{spec.inspect} allow_actions=#{allow_actions}"
      end
    end
  end

  # A profile exists to be the SMALL catalogue; one that crept up to the default's size
  # would still pass every other example here.
  it "keeps every profile a fraction of the full catalogue" do
    _, full = measured(nil, true)
    Gori::MCP::ToolFilter::PROFILES.each do |profile|
      _, bytes = measured("@#{profile.name}", true)
      bytes.should be < (full // 4), "@#{profile.name} is #{bytes} bytes of a #{full}-byte catalogue"
    end
  end

  # The profiles' tools must not send the agent to tools the profile leaves out. Checked on
  # the served catalogue, not the full one: descriptions that name a project binder are
  # already assembled from what is served (#1136).
  it "keeps every profile's descriptions pointing only at tools it serves" do
    seen = Set(String).new
    unexcused = [] of String
    Gori::MCP::ToolFilter::PROFILES.each do |profile|
      served = profile.tools.to_set
      JSON.parse(Gori::MCP::Tools.catalogue_json(filter_for("@#{profile.name}"), true)).as_a.each do |tool|
        text = tool.to_json
        Gori::MCP::Tools::TOOL_NAMES.each do |named|
          next if served.includes?(named)
          next unless text.matches?(/(?<![a-z_])#{named}(?![a-z_])/)
          pair = "#{tool["name"]} -> #{named}"
          seen << pair
          unexcused << "@#{profile.name}: #{pair}" unless INCIDENTAL.has_key?(pair)
        end
      end
    end
    unexcused.should be_empty,
      "add each named tool to the profile, or to INCIDENTAL with the reason it is not an instruction:\n  #{unexcused.join("\n  ")}"
    (INCIDENTAL.keys.to_set - seen).should be_empty, "INCIDENTAL entries no description makes any more"
  end

  GUIDES.each do |lang, path|
    describe "the #{lang} guide" do
      # Read inside each example, never here: a tree without docs/ (a packaged source
      # filter) should fail these examples, not abort the whole spec binary at load.
      it "states each start command's tool count and size as they measure today" do
        text = File.read(path)
        rows = text.lines.compact_map do |line|
          next unless line.starts_with?('|')
          cells = table_cells(line)
          next unless cells.size >= 3 && (flags = row_flags(cells[0]))
          {cells, flags}
        end
        documented = rows.map { |(cells, _)| cells[0] }
        required = ["`gori mcp`", "`--read-only`"] + Gori::MCP::ToolFilter::PROFILES.map { |pr| "`--tools=@#{pr.name}`" }
        required.each do |cell|
          documented.should contain(cell), "#{path}: the catalogue table has no row for #{cell}"
        end

        rows.each do |(cells, (spec, allow_actions))|
          count, bytes = measured(spec, allow_actions)
          kb = Gori::MCP::Tools.catalogue_kb(bytes)
          want = "| #{cells[0]} | #{count} | ~#{kb} KB | ~#{(bytes / 4 / 1000.0).round.to_i}k |"
          cells[1].should eq(count.to_s), "#{path}: #{cells[0]} advertises #{count} tools; the row should read #{want}"
          doc_kb = cells[2].match(/~?(\d+)\s*KB/).try(&.[1].to_i)
          doc_kb.should_not be_nil, "#{path}: #{cells[0]} has no size; the row should read #{want}"
          next unless doc_kb
          (doc_kb - kb).abs.should be <= {1, (kb * SIZE_TOLERANCE).round.to_i}.max,
            "#{path}: #{cells[0]} documents ~#{doc_kb} KB but weighs #{kb} KB; the row should read #{want}"
          # The token column is derived, never measured (bytes ÷ 4, said so in the guide), and
          # held to the same tolerance so it cannot outlive the size beside it.
          doc_k = cells[3]?.try(&.match(/~?(\d+)k/)).try(&.[1].to_i)
          doc_k.should_not be_nil, "#{path}: #{cells[0]} has no token estimate; the row should read #{want}"
          next unless doc_k
          k = bytes / 4 / 1000.0
          (doc_k - k).abs.should be <= {1.0, k * SIZE_TOLERANCE}.max,
            "#{path}: #{cells[0]} documents ~#{doc_k}k tokens but its bytes ÷ 4 is #{k.round(1)}k; the row should read #{want}"
        end
      end

      # The membership table, checked the same way: every code span in a profile's row is a
      # tool (or another profile, expanded), and together they are exactly the profile. A
      # tool added to RECON and not to the guide is the drift this file exists for, one level
      # down from a count.
      it "lists exactly each profile's tools" do
        text = File.read(path)
        Gori::MCP::ToolFilter::PROFILES.each do |profile|
          line = text.lines.find { |l| l.starts_with?('|') && table_cells(l).first? == "`@#{profile.name}`" }
          line.should_not be_nil, "#{path}: no membership row for @#{profile.name}"
          next unless line
          named = Set(String).new
          table_cells(line)[1..].join(' ').scan(/`([^`]+)`/) do |m|
            span = m[1]
            if span.starts_with?('@')
              other = Gori::MCP::ToolFilter::PROFILES.find { |p| "@#{p.name}" == span }
              other.should_not be_nil, "#{path}: @#{profile.name}'s row names unknown profile #{span}"
              named.concat(other.tools) if other
            else
              named << span
            end
          end
          missing = profile.tools.to_set - named
          extra = named - profile.tools.to_set
          missing.should be_empty, "#{path}: @#{profile.name}'s row omits #{missing.to_a.sort.join(", ")}"
          extra.should be_empty, "#{path}: @#{profile.name}'s row names #{extra.to_a.sort.join(", ")}, which it does not serve"
        end
      end
    end
  end
end
