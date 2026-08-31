require "../../spec_helper"

# The ZERO-positional guard across `src/gori/cli/run/`, as a CLASS.
#
# `OptionParser`'s default `unknown_args` handler is SILENT, so a parser that installs none
# discards every leftover word without a sound and the command reports success for work it
# did not do. Reproduced through the built binary before this sweep:
#
#   gori run project scope add -p zzz.test STRAY          → "Scope rule added successfully."
#   gori run rewriter add -f a -v b STRAY                 → "Global rule #1 added…"
#   gori run sitemap tag --host h --path / --tag t STRAY  → "Tagged h/: t"
#   gori run capture --project p STRAY                    → proxy starts, STRAY never mentioned
#
# `repeater_positional_spec` pinned this for the three `repeater` subcommands and scoped its
# gate to that one file, noting that ~30 parsers elsewhere still had the hole and that a
# repo-wide gate would be "a red suite standing in for a sweep nobody has done". This is that
# sweep, so the gate is now repo-wide and lives here instead.
#
# Asserted over the SOURCE, the way `spec/cli_spec.cr` and `option_parser_missing_option_spec`
# are, for their two reasons: `abort` calls `exit`, so the refusal itself is not catchable
# in-process, and the defect is an ABSENCE — a new subcommand reintroduces it by copying the
# idiom from its neighbours, which is how every one of these got it. The MESSAGE half is
# pinned on `no_positional_error` at the bottom.

# The three spellings that reach a guard. `one_positional` / `one_positional_list` /
# `refuse_list_leftovers` are not listed because they are called from INSIDE an
# `.unknown_args` block, which the first entry already sees.
private GUARDS = {".unknown_args", "parse_no_positionals(", "views_one_positional("}

private def run_cli_dir : String
  File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
end

# Each parser's window: from its own `OptionParser.new` to the NEXT one. Anchoring on the
# `parse(` call instead let a block that spells its parse differently (or returns early)
# swallow the rest of the file, so a LATER block's handler satisfied the check for one that
# had none — the gate going green on exactly the drift it exists to catch.
private def parser_windows(src : String) : Array({Int32, String})
  starts = [] of Int32
  pos = 0
  while at = src.index("OptionParser.new do |", pos)
    starts << at
    pos = at + 1
  end
  starts.map_with_index { |at, i| {at, src[at...(starts[i + 1]? || src.size)]} }
end

# The handler's own body and its two block parameters, or nil when the line opens no handler.
#
# Windowed to the block's real terminator rather than to a fixed number of following lines: a
# `do …  end` handler longer than the window would be judged on a body it does not have, in
# EITHER direction — a red suite on correct code, or a green one on a handler that drops the
# `after` half further down than the window reached.
private def handler_body(lines : Array(String), i : Int32) : {String, String, String}?
  md = lines[i].match(/\.unknown_args\s*(\{|do)\s*\|\s*(\w+)\s*,\s*(\w+)\s*\|/)
  return nil unless md
  body = md.post_match
  if md[1] == "do"
    indent = lines[i].size - lines[i].lstrip.size
    j = i + 1
    while j < lines.size && !(lines[j].strip == "end" && (lines[j].size - lines[j].lstrip.size) == indent)
      body += "\n#{lines[j]}"
      j += 1
    end
  elsif !body.includes?("}")
    j = i + 1
    while j < lines.size
      body += "\n#{lines[j]}"
      break if lines[j].includes?("}")
      j += 1
    end
  end
  {body, md[2], md[3]}
end

# A parameter is USED only as a whole word. A plain `includes?` answered this vacuously for
# short names — `{ |b, a| positional = b }` "contains" `a`, in the middle of `positional` —
# so the gate returned true for exactly the handler it exists to refuse.
private def word_used?(body : String, name : String) : Bool
  body.matches?(/(?<![A-Za-z0-9_])#{Regex.escape(name)}(?![A-Za-z0-9_])/)
end

# nil when the line opens no handler; otherwise whether the body reads BOTH halves.
# Shared by the gate and its negative controls so a control cannot drift from the check.
private def handler_uses_both_halves?(lines : Array(String), i : Int32) : Bool?
  parts = handler_body(lines, i)
  return nil unless parts
  body, before, after = parts
  word_used?(body, before) && word_used?(body, after)
end

# Method bodies, for the per-subcommand pairing below: from one `def self.` to the next.
private def method_body(src : String, name : String) : String
  lines = src.split("\n")
  starts = [] of Int32
  lines.each_with_index { |l, i| starts << i if l.matches?(/^      (private )?def self\./) }
  at = starts.index { |i| lines[i].matches?(/^      (private )?def self\.#{Regex.escape(name)}\b/) }
  raise "method #{name} not found" unless at
  lines[starts[at]...(starts[at + 1]? || lines.size)].join("\n")
end

# The seventeen subcommands this sweep guarded, each with the prefix its refusal must name.
# Pinned per command because the error a 17-site sweep is likeliest to make is not a missing
# guard — the gate above catches that — but a guard carrying the NEIGHBOUR's subcommand in
# its message, which no generic check can see.
#
# The PREFIX is what is pinned, not the hint: the prefix is the subcommand's identity, while
# several hints are deliberately shared between siblings (`rewriter add`/`preview` and
# `colormarker add`/`preview` each take the same flags), so pinning hints here would assert
# that two commands differ where they are meant to agree.
private SWEPT = [
  {"capture.cr", "cmd_capture", "gori run capture"},
  {"colormarker.cr", "cmd_colormarker_color_add", "gori run colormarker color add"},
  {"colormarker.cr", "cmd_colormarker_add", "gori run colormarker add"},
  {"colormarker.cr", "cmd_colormarker_preview", "gori run colormarker preview"},
  {"decoder.cr", "cmd_decoder_list", "gori run decoder list"},
  {"intercept.cr", "cmd_intercept_toggle", "gori run intercept \#{action}"},
  {"issues.cr", "cmd_issues_create", "gori run issues create"},
  {"oast.cr", "oast_listen", "gori run oast listen"},
  {"probe.cr", "cmd_probe_rule_add", "gori run probe rules add"},
  {"project.cr", "cmd_scope_add", "gori run project scope add"},
  {"project.cr", "cmd_sandbox_set", "gori run project sandbox \#{action}"},
  {"rewriter.cr", "cmd_rewriter_preset_list", "gori run rewriter preset list"},
  {"rewriter.cr", "cmd_extract_add", "gori run rewriter extract add"},
  {"rewriter.cr", "cmd_rewriter_bindings", "gori run rewriter bindings"},
  {"rewriter.cr", "cmd_rewriter_add", "gori run rewriter add"},
  {"rewriter.cr", "cmd_rewriter_preview", "gori run rewriter preview"},
  {"sitemap.cr", "cmd_sitemap_tag", "gori run sitemap tag"},
]

describe "gori run — every OptionParser reaches an unknown_args guard" do
  it "leaves no parser under src/gori/cli/run without one" do
    offenders = [] of String
    Dir.glob(File.join(run_cli_dir, "**", "*.cr")).sort.each do |path|
      src = File.read(path)
      parser_windows(src).each do |(at, window)|
        next if GUARDS.any? { |g| window.includes?(g) }
        offenders << "#{File.basename(path)}@#{src[0, at].count('\n') + 1}"
      end
    end
    offenders.should be_empty
  end

  # …and the gate has to actually select things, or it is a check that never looked. Pinned
  # on the shape rather than on a count, so a new parser does not have to update a number.
  it "would catch a parser with neither guard" do
    src = <<-CR
      parser = OptionParser.new do |p|
        p.on("--a", "") { }
      end
      parser.parse(args)
      CR
    windows = parser_windows(src)
    windows.size.should eq(1)
    GUARDS.any? { |g| windows[0][1].includes?(g) }.should be_false
  end

  # Anchored on the enclosing METHOD rather than on a parser ordinal: an index would follow
  # whatever parser happens to sit at that position, so adding one ahead of it would quietly
  # move the assertion onto a different command instead of failing.
  it "sees the guard in each of the three spellings the surface uses" do
    method_body(File.read(File.join(run_cli_dir, "capture.cr")), "cmd_capture")
      .should contain("parse_no_positionals(")
    method_body(File.read(File.join(run_cli_dir, "views.cr")), "cmd_views_add")
      .should contain("views_one_positional(")
    method_body(File.read(File.join(run_cli_dir, "notes.cr")), "cmd_notes_read")
      .should contain(".unknown_args")
  end

  # `unknown_args` yields TWO lists: the words OptionParser could not claim, and the run
  # after a `--` separator, which it strips and hands over separately. `spec/cli_spec.cr`
  # already refuses the `|x, _|` spelling; this refuses the one that NAMES both halves and
  # then reads only the first, which that regex cannot see.
  it "uses both halves in every `cli/run` unknown_args handler" do
    offenders = [] of String
    Dir.glob(File.join(run_cli_dir, "**", "*.cr")).sort.each do |path|
      lines = File.read_lines(path)
      lines.each_index do |i|
        offenders << "#{File.basename(path)}:#{i + 1}" if handler_uses_both_halves?(lines, i) == false
      end
    end
    offenders.should be_empty
  end

  it "would catch a handler that keeps only the `before` half" do
    handler_uses_both_halves?(["p.unknown_args { |before, after| positional = before }"], 0)
      .should be_false
    handler_uses_both_halves?(["p.unknown_args { |before, after| positional = before + after }"], 0)
      .should be_true
    handler_uses_both_halves?(["parser.parse(args)"], 0).should be_nil
  end

  # Short parameter names are the case a substring test answers vacuously: `positional`
  # CONTAINS an `a`, so `includes?(after_name)` was true for a handler that never reads it.
  it "is not satisfied by a parameter name that merely appears inside another word" do
    handler_uses_both_halves?(["p.unknown_args { |b, a| positional = b }"], 0).should be_false
    handler_uses_both_halves?(["p.unknown_args { |b, a| positional = b + a }"], 0).should be_true
  end

  # …and a `do … end` handler is judged on its WHOLE body: a fixed look-ahead would call the
  # first of these an offender (it reads `after` too late) and miss the second.
  it "reads a multi-line handler to its own `end`, however long" do
    filler = Array.new(9) { "            # …" }
    uses_late = ["          p.unknown_args do |before, after|", "            rest = before"] +
                filler + ["            rest += after", "          end"]
    drops_late = ["          p.unknown_args do |before, after|", "            rest = before"] +
                 filler + ["            rest += rest", "          end"]
    handler_uses_both_halves?(uses_late, 0).should be_true
    handler_uses_both_halves?(drops_late, 0).should be_false
  end

  it "names its own subcommand in the guard it installs" do
    offenders = [] of String
    SWEPT.each do |(file, method, prefix)|
      body = method_body(File.read(File.join(run_cli_dir, file)), method)
      unless body.includes?("parse_no_positionals(parser, args, \"#{prefix}\"")
        offenders << "#{file}##{method}"
      end
    end
    offenders.should be_empty
  end

  # The pairing check has to be able to tell two neighbours apart, or it would pass on the
  # copy-paste it exists to catch: `rewriter add` and `rewriter preview` are adjacent, take
  # nearly the same flags, and are the likeliest pair in the sweep to be given one message.
  it "would catch a guard that names the neighbouring subcommand" do
    body = method_body(File.read(File.join(run_cli_dir, "rewriter.cr")), "cmd_rewriter_preview")
    body.includes?("parse_no_positionals(parser, args, \"gori run rewriter preview\"").should be_true
    body.includes?("parse_no_positionals(parser, args, \"gori run rewriter add\"").should be_false
  end
end

describe Gori::CLI::Run do
  describe ".no_positional_error — the refusals this sweep wired" do
    # `cmd -- stray`: OptionParser strips the `--` and hands the tail over as the SECOND
    # list, so a guard reading only `before` sees nothing to refuse and the command runs as
    # if the word had never been typed. Driven through a real parser rather than asserted,
    # because this is the half of the idiom that has been got wrong here before.
    it "refuses a word after `--`, which arrives in the second list" do
      before_seen = [] of String
      after_seen = [] of String
      parser = OptionParser.new do |p|
        p.on("--format=FMT", "") { }
        p.unknown_args { |b, a| before_seen = b; after_seen = a }
      end
      parser.parse(["--format=json", "--", "stray"])

      # The bug: the first list is EMPTY, so a `before`-only guard accepts this silently.
      before_seen.should be_empty
      after_seen.should eq(["stray"])
      Gori::CLI::Run.no_positional_error(before_seen, "gori run decoder list", "hint").should be_nil

      # What the guards actually pass, and what the operator sees.
      Gori::CLI::Run.no_positional_error(before_seen + after_seen, "gori run decoder list",
        "`decoder list` takes no positional arguments")
        .should eq("gori run decoder list: unexpected argument \"stray\" — " \
                   "`decoder list` takes no positional arguments")
    end

    it "names the stray word and the flag it belonged to" do
      Gori::CLI::Run.no_positional_error(["zzz.test"], "gori run project scope add",
        "pass the pattern as --pattern P, with --kind include|exclude and --type host|string|regex")
        .should eq("gori run project scope add: unexpected argument \"zzz.test\" — pass the " \
                   "pattern as --pattern P, with --kind include|exclude and --type host|string|regex")
    end

    # The dominant real cause on these commands is an unquoted multi-word flag value, whose
    # tail words arrive as positionals. Printing every one of them is what lets the operator
    # see which quotes went missing — a message naming only the first would read as a typo.
    it "prints every word of an unquoted --when query" do
      Gori::CLI::Run.no_positional_error(["AND", "status:500"], "gori run colormarker add",
        "pass the condition as --when FILTER")
        .should eq("gori run colormarker add: unexpected arguments \"AND status:500\" — " \
                   "pass the condition as --when FILTER")
    end
  end
end
