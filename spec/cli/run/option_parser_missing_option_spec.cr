require "../../spec_helper"

# Every parser under `src/gori/cli/` that takes a `=VALUE` flag, as a CLASS.
#
# `OptionParser`'s default `missing_option` handler RAISES `OptionParser::MissingOption`. That
# is neither `Gori::Error` (the only type `CLI.run` rescues, src/gori/cli.cr) nor `IO::Error`
# (the only type `Run.dispatch` rescues, src/gori/cli/run.cr), so a value flag left bare at the
# end of argv — `gori run rewriter rm 1 --project`, or an unset `--project "$P"` in a wrapper
# script — reaches `main` and prints a Crystal backtrace instead of a one-line abort:
#
#   gori run rewriter rm 1 --project      → Unhandled exception: Missing option: --project
#   gori run colormarker move 1 --db      → same
#   gori run decoder list --format        → same
#
# `unknown_args` does not absorb it: the token matches a DECLARED option, so `handle_flag` runs
# first. src/gori/cli/run/oast.cr fixed one parser for exactly this and read as the only one;
# eleven more were carrying the same hole. Asserted over the SOURCE rather than per-command,
# the way the `unknown_args` guard in spec/cli_spec.cr is, because the defect is one a new
# subcommand reintroduces by copying the idiom from its neighbours — which is how these got it.
#
# A parser declaring no `=VALUE` flag cannot hit the handler, so it is exempt rather than
# force-fitted.
describe "gori run — missing_option on every value-taking parser" do
  it "is bound wherever a =VALUE flag is declared" do
    dir = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli")
    offenders = [] of String
    Dir.glob(File.join(dir, "**", "*.cr")).sort.each do |path|
      lines = File.read_lines(path)
      i = 0
      while i < lines.size
        line = lines[i]
        unless line.includes?("OptionParser.new do")
          i += 1
          next
        end
        # The block runs to the `end` sitting at the opener's own indentation.
        indent = line.size - line.lstrip.size
        j = i + 1
        body = [] of String
        while j < lines.size
          l = lines[j]
          break if l.strip == "end" && (l.size - l.lstrip.size) == indent
          body << l
          j += 1
        end
        # `p.on("--project=NAME", …)`, `p.on("-p PORT", …)` — and `[a-z][A-Z]` for the
        # short-ATTACHED form `p.on("-fFIND", …)`, which the `[= ]` alternative does not see.
        # Today every short-attached flag happens to carry a `--long=VALUE` twin, so the first
        # alternative alone still passed — which is exactly the kind of accident that lets an
        # unpaired `-nN` slip through later. Flag names in this tree are lowercase kebab-case,
        # so `[a-z][A-Z]` cannot fire on a bare switch. `-h`/`--help` do not match either.
        takes_value = body.any? do |l|
          l.includes?("p.on(") && l.matches?(/"-{1,2}[^"]*(?:[= ][A-Z]|[a-z][A-Z])/)
        end
        offenders << "#{File.basename(path)}:#{i + 1}" if takes_value && !body.any?(&.includes?("p.missing_option"))
        i = j
      end
    end
    offenders.should be_empty
  end
end
