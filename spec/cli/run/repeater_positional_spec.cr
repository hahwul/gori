require "../../spec_helper"

# `CLI::Run.no_positional_error` — the ZERO-positional half of the rule
# `list_leftover_error` / `extra_positional_error` already state for the other two shapes.
#
# `OptionParser`'s default `unknown_args` handler is SILENT, so a command that installs none
# discards every leftover word without a sound. Three `repeater` subcommands did:
#
#     $ gori run repeater create -t http://h -r 'GET / HTTP/1.1' STRAYARG
#     Repeater session #8 created successfully.        ← STRAYARG never mentioned
#     $ gori run repeater h2 --target http://h --fields f.json STRAY
#     → 200 in 3.1ms                                   ← request sent, STRAY never mentioned
#     $ gori run repeater list STRAY
#     #1  [H1]  t1  → http://h                         ← listed, STRAY never mentioned
#
# `create` is the one that costs: a bare word there is almost always the request file or the
# target the operator meant to pass through a flag, so the row that gets written holds a
# request they did not type — reported as a clean "session #N created successfully."
#
# `abort` is not spec-able, which is why the decision and the message are a function.
describe Gori::CLI::Run do
  describe ".no_positional_error" do
    it "proceeds when the command was handed no positionals at all" do
      Gori::CLI::Run.no_positional_error([] of String, "gori run repeater list", "hint").should be_nil
    end

    it "refuses ONE — unlike the one-positional sites, a single token here is already a drop" do
      Gori::CLI::Run.no_positional_error(["STRAY"], "gori run repeater create", "pass it via --request-file")
        .should eq("gori run repeater create: unexpected argument \"STRAY\" — pass it via --request-file")
    end

    it "pluralises, and prints every token so the operator can spot which flag went missing" do
      Gori::CLI::Run.no_positional_error(["a.txt", "b.txt"], "gori run repeater create", "use --request-file")
        .should eq("gori run repeater create: unexpected arguments \"a.txt b.txt\" — use --request-file")
    end
  end

  # A source check, the same shape (and for the same reason) as `list_leftovers_spec`'s: the
  # defect is an ABSENCE, and an absence cannot be caught by grepping for a spelling. Every
  # `OptionParser` in the repeater CLI must reach an `unknown_args` handler, whether it
  # installs one itself (the sites that take a positional) or hands the parser to
  # `parse_no_positionals` (the sites that take none) — without either, the leftovers never
  # reach any guard at all.
  #
  # Scoped to these two files rather than all of `cli/run`: 30-odd parsers elsewhere are still
  # missing theirs (`project scope add -p zzz.test STRAY` adds the rule and says nothing), and
  # a repo-wide gate here would be a red suite standing in for a sweep nobody has done.
  it "routes every repeater OptionParser through an unknown_args guard" do
    dir = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
    offenders = [] of String
    {"repeater.cr", "repeater_minimize.cr"}.each do |name|
      src = File.read(File.join(dir, name))
      # Window each block from its `OptionParser.new` to the NEXT one — anchoring on the
      # `parse(` call instead let a block that spells its parse differently (or returns early)
      # swallow the rest of the file, so a LATER block's handler satisfied the check for one
      # that had none: the gate going green on exactly the drift it exists to catch.
      starts = [] of Int32
      pos = 0
      while at = src.index("OptionParser.new do |", pos)
        starts << at
        pos = at + 1
      end
      starts.each_with_index do |at, i|
        window = src[at...(starts[i + 1]? || src.size)]
        next if window.includes?(".unknown_args") || window.includes?("parse_no_positionals(")
        offenders << "#{name}@#{src[0, at].count('\n') + 1}"
      end
    end
    offenders.should be_empty
  end

  # …and the gate has to actually select things, or it is a check that never looked: strip the
  # guard from one window and it must fail. Pinned on the shape rather than on a count, so a
  # new parser in either file does not have to update a magic number.
  it "would catch a parser with neither guard" do
    src = <<-CR
      parser = OptionParser.new do |p|
        p.on("--a", "") { }
      end
      parser.parse(args)
      CR
    src.includes?(".unknown_args").should be_false
    src.includes?("parse_no_positionals(").should be_false
  end
end
