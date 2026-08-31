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

  # The source gate that used to sit here — every `OptionParser` in these two files must
  # reach an `unknown_args` handler — was scoped to `repeater.cr`/`repeater_minimize.cr`
  # because ~30 parsers elsewhere under `cli/run` were still missing theirs, and a repo-wide
  # gate would have been a red suite standing in for a sweep nobody had done. That sweep has
  # since happened, so the gate is repo-wide and lives in `unknown_args_sweep_spec.cr`, which
  # covers these two files along with every other one.
end
