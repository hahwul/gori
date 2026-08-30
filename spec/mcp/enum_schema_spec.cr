require "../spec_helper"

# An MCP client hands the MODEL the tool's JSON Schema, never the reader. So for every
# argument with a CLOSED set of legal strings, the set has to be in the schema as `enum` —
# otherwise the model infers it from the description's prose, and when it infers wrong the
# call comes back refused and it guesses again. That loop costs a round trip per guess and
# reads, from outside the process, as a flaky server.
#
# Declaring the set is only half of it; the other half is that the declaration and the
# reader must AGREE. They drifted before this file existed: `update_rule` and `preview_rule`
# each described `op` without `pipe` while their reader had accepted `pipe` all along, and
# `list_events` offered a `source` its filter would answer with an empty feed.
#
# So these specs drive the real `tools/list` output back through the real `Tools#call`, both
# directions:
#
#   * every value a tool ADVERTISES is one its reader ACCEPTS, and
#   * a value it does not advertise is REFUSED, by name — never silently defaulted, which is
#     how `body_mode` used to inline a whole response body for a caller that mistyped "none".
#
# Generic on purpose. A new `enumprop` is covered the day it is added, and a hand-written
# list that drifts from its reader fails here rather than in an agent's retry loop.

private def with_store(&)
  path = File.tempname("gori-mcpenum", ".db")
  store = Gori::Store.open(path)
  begin
    with_globals { yield store }
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# Driving `scope:"global"` through create_rule / create_color_rule / create_view is the point
# of the acceptance sweep below — and every one of those writes PROCESS-WIDE `Settings` state
# plus a settings.json under `$GORI_HOME`, which the whole suite otherwise shares. Left
# unwound, this file's rules are merged into every later example's rule list: `spec/rules_spec`
# counted three rows where it had created two, and `crystal spec` failed ten examples in files
# this change never touched while each of them passed alone. Same shape (and the same remedy)
# as `spec/rules_spec.cr`'s own `with_globals` — its comment explains why the HOME has to move
# too, not just the arrays.
private def with_globals(&)
  prev_home = ENV["GORI_HOME"]?
  rules = Gori::Settings.rewriter_rules
  rule_id = Gori::Settings.rewriter_next_rule_id
  colors = Gori::Settings.colormarker_colors
  color_rules = Gori::Settings.colormarker_rules
  color_id = Gori::Settings.colormarker_next_rule_id
  views = Gori::Settings.saved_views
  view_id = Gori::Settings.saved_views_next_id
  providers = Gori::Settings.oast_providers
  dir = File.tempname("gori-mcpenum-globals")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    # Cleared AND re-based: `rules_spec.cr` resets its counter inside the block for the same
    # reason, and leaving one at whatever an earlier file left behind makes the ids this file
    # mints depend on suite ordering. Everything saved above is cleared here, so the restore
    # has nothing to put back that this file did not itself create.
    Gori::Settings.rewriter_rules = [] of Gori::Settings::RewriterRule
    Gori::Settings.rewriter_next_rule_id = 1_i64
    Gori::Settings.colormarker_colors = [] of Gori::Settings::ColormarkerColor
    Gori::Settings.colormarker_rules = [] of Gori::Settings::ColormarkerRule
    Gori::Settings.colormarker_next_rule_id = 1_i64
    Gori::Settings.saved_views = [] of Gori::Settings::SavedView
    Gori::Settings.saved_views_next_id = 1_i64
    Gori::Settings.oast_providers = [] of Gori::Settings::OastProvider
    yield
  ensure
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    Gori::Settings.rewriter_rules = rules
    Gori::Settings.rewriter_next_rule_id = rule_id
    Gori::Settings.colormarker_colors = colors
    Gori::Settings.colormarker_rules = color_rules
    Gori::Settings.colormarker_next_rule_id = color_id
    Gori::Settings.saved_views = views
    Gori::Settings.saved_views_next_id = view_id
    Gori::Settings.oast_providers = providers
    FileUtils.rm_rf(dir)
  end
end

private def tools_for(store) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: true, verify_upstream: false)
end

private record EnumArg, tool : String, arg : String, values : Array(String),
  required : Hash(String, JSON::Any)

# Every {tool, argument, enum values} the live schema declares, with the tool's OTHER
# required arguments filled in so the call reaches the reader under test instead of stopping
# at a missing-argument check. Placeholders only — every case below asserts on whether the
# error names THIS argument, so whatever the filler arguments do is irrelevant.
private def enum_args(tools) : Array(EnumArg)
  listing = JSON.parse(JSON.build { |j| tools.list(j) }).as_a
  out = [] of EnumArg
  listing.each do |t|
    name = t["name"].as_s
    # These dial a real origin (or register with a public OAST host) before the reader they
    # would exercise here can be reached. Their enums come from the same constants as the
    # tools that ARE driven below.
    next if name.in?("oast_start", "probe_scan", "send_request", "send_websocket", "grpc_reflect")
    schema = t["inputSchema"]
    props = schema["properties"].as_h
    required = schema["required"].as_a.map(&.as_s)
    props.each do |arg, spec|
      values = spec.as_h["enum"]?.try(&.as_a.map(&.as_s))
      next unless values
      fillers = {} of String => JSON::Any
      required.each do |r|
        next if r == arg
        fillers[r] = case props[r]["type"]?.try(&.as_s)
                     when "integer" then JSON::Any.new(1_i64)
                     when "boolean" then JSON::Any.new(true)
                     else                JSON::Any.new("placeholder")
                     end
      end
      out << EnumArg.new(name, arg, values, fillers)
    end
  end
  out
end

# Whether `text` is the reader refusing THIS argument (as opposed to erroring on one of the
# placeholder fillers, or on a row id that does not exist — both expected and both fine).
private def refuses_arg?(text : String, arg : String) : Bool
  !!text.matches?(/(invalid|unknown|unsupported)\s+'?"?#{Regex.escape(arg)}'?"?/i)
end

private def call_with(tools, e : EnumArg, value : JSON::Any) : {String, Bool}
  args = e.required.dup
  args[e.arg] = value
  r = tools.call(e.tool, JSON::Any.new(args))
  {r.text, r.is_error}
end

describe "MCP closed-set arguments" do
  it "declares at least one enum on every tool family that has a closed set" do
    with_store do |store|
      args = enum_args(tools_for(store))
      # A floor, not a target: it exists so a refactor that drops `enumprop` from a whole
      # file fails here instead of quietly shipping prose-only schemas again.
      args.size.should be > 50
      args.each(&.values.should_not(be_empty))
    end
  end

  it "accepts every value it advertises" do
    with_store do |store|
      tools = tools_for(store)
      offenders = [] of String
      enum_args(tools).each do |e|
        e.values.each do |v|
          text, is_error = call_with(tools, e, JSON::Any.new(v))
          next unless is_error && refuses_arg?(text, e.arg)
          offenders << "#{e.tool}.#{e.arg}=#{v}: #{text}"
        end
      end
      offenders.should eq([] of String)
    end
  end

  it "refuses a value it does not advertise, by name" do
    with_store do |store|
      tools = tools_for(store)
      offenders = [] of String
      enum_args(tools).each do |e|
        bogus = "zzz-not-a-#{e.arg}"
        next if e.values.includes?(bogus)
        text, is_error = call_with(tools, e, JSON::Any.new(bogus))
        # Silence is the failure mode this catches: a reader whose `else` branch falls back
        # to a default answers `isError:false` for a call that did something other than what
        # it was asked to do, and the caller never learns.
        offenders << "#{e.tool}.#{e.arg}: accepted #{bogus.inspect} — #{text[0, 120]}" unless is_error
      end
      offenders.should eq([] of String)
    end
  end

  it "does not re-list the enum values as prose in the description" do
    with_store do |store|
      # Specifically the LIST form — `head|body|ws`, `flask / rack / django` — and not a
      # description that names a value to explain it ("none returns body shape only";
      # "a global rule lives in settings.json"). Naming one is what a good description does;
      # spelling the whole set out a second time is what went stale, because nothing reads
      # the prose copy and so nothing notices when the reader moves on without it.
      offenders = [] of String
      listing = JSON.parse(JSON.build { |j| tools_for(store).list(j) }).as_a
      listing.each do |t|
        t["inputSchema"]["properties"].as_h.each do |arg, spec|
          h = spec.as_h
          values = h["enum"]?.try(&.as_a.map(&.as_s))
          next unless values && values.size > 1
          desc = h["description"].as_s
          # Two of the set's own values, adjacent, joined by a list separator. The
          # lookarounds stand in for `\b`, which misreads a value carrying `.`, `+` or `-`
          # (`webhook.site`, `host+subdomains`, `cluster-bomb`) and would also let `head`
          # match inside `headers`.
          pairs = values.each_permutation(2).select do |(a, b)|
            desc.matches?(/(?<![A-Za-z0-9_.+-])#{Regex.escape(a)}(?![A-Za-z0-9_.+-])\s*[|\/]\s*#{Regex.escape(b)}(?![A-Za-z0-9_.+-])/)
          end
          offenders << "#{t["name"]}.#{arg}: description re-lists #{pairs.first} — the enum is the one copy" unless pairs.empty?
        end
      end
      offenders.should eq([] of String)
    end
  end
end
