require "../../spec_helper"

# `CLI::Run.list_leftover_error` — the one seam behind `refuse_list_leftovers`, which twelve
# `gori run` dispatchers call.
#
# The failure it exists for: every one of those dispatchers routes a first token starting
# with '-' straight to its LIST command, on the assumption that the rest are list options.
# So `gori run rewriter --project=t1 rm 1` — the flag-first ordering every other `gori run`
# command accepts — discarded `rm 1`, listed the rules, and exited 0. A destructive mutation
# that silently no-ops with a SUCCESS status is the worst thing a scripted surface can do,
# and a script cannot see it: the exit code says the delete happened.
#
# `abort` is not spec-able, which is exactly why the DECISION and the MESSAGE were split out
# into this function. Everything below drives it directly.

private REWRITER_VERBS = "add, rm/delete, enable, disable, preview, extract, bindings"

describe Gori::CLI::Run do
  describe ".list_leftover_error" do
    it "proceeds when the list command was handed no positionals at all" do
      Gori::CLI::Run.list_leftover_error([] of String, "rewriter", REWRITER_VERBS).should be_nil
    end

    # The leading-flag route hands the list command its own name back: `cmd_issues` sees
    # `--project=X` (not a verb token) and calls `cmd_issues_list(["--project=X", "list"])`,
    # leaving `["list"]` as the leftover. Refusing that turned every `<cmd> --project=X list`
    # into a usage error whose message listed `list` among the verbs it called unknown.
    it "does not refuse a lone read verb — that is what the command was about to do anyway" do
      Gori::CLI::Run.list_leftover_error(["list"], "issues", "create, update, delete/rm, list").should be_nil
    end

    # `gori run project sandbox` is the only one of the twelve whose read verb is not
    # spelled `list`, which is why `read_verb` is a parameter rather than a constant.
    it "honours a command's own read verb, and refuses another command's" do
      Gori::CLI::Run.list_leftover_error(["status"], "project sandbox",
        "on/enable, off/disable, status", "status").should be_nil

      # `list` is not this command's read verb, so it IS a discarded verb here.
      Gori::CLI::Run.list_leftover_error(["list"], "project sandbox",
        "on/enable, off/disable, status", "status").should_not be_nil
    end

    it "refuses a discarded mutation verb and names the ordering that works" do
      msg = Gori::CLI::Run.list_leftover_error(["rm", "1"], "rewriter", REWRITER_VERBS)
      msg.should eq("gori run rewriter: unknown subcommand 'rm' — global flags go AFTER " \
                    "the subcommand (`gori run rewriter rm … --project=NAME`). Verbs: #{REWRITER_VERBS}")
    end

    it "names the FIRST leftover, which is the position the verb was discarded from" do
      Gori::CLI::Run.list_leftover_error(["delete", "7"], "links", "add, delete/rm, list")
        .not_nil!.should contain("unknown subcommand 'delete'")
    end

    # Exactly one token, and exactly that word, is the exemption. `issues --project=X list rm 3`
    # still names `list` — a real second verb followed it, so something WAS discarded.
    it "refuses a read verb that is followed by another verb" do
      Gori::CLI::Run.list_leftover_error(["list", "rm", "3"], "issues",
        "create, update, delete/rm, list").not_nil!.should contain("unknown subcommand 'list'")
    end

    it "refuses a read verb repeated, since only one token is exempt" do
      Gori::CLI::Run.list_leftover_error(["list", "list"], "links", "add, delete/rm, list").should_not be_nil
    end

    # The message carries the caller's own subcommand path and verb list, so a multi-word
    # subcommand ("project host-override") reads as the command the operator would retype.
    it "echoes a multi-word subcommand path verbatim in both the prose and the example" do
      msg = Gori::CLI::Run.list_leftover_error(["add"], "project host-override",
        "add, update, delete/rm, list").not_nil!
      msg.should start_with("gori run project host-override: unknown subcommand 'add'")
      msg.should contain("(`gori run project host-override add … --project=NAME`)")
      msg.should contain("Verbs: add, update, delete/rm, list")
    end
  end

  describe ".reserved_query_verb_error" do
    it "proceeds for a positional QL term" do
      Gori::CLI::Run.reserved_query_verb_error(["host:x"], "history",
        ["delete", "rm", "clear", "show"], "delete/rm, clear, show").should be_nil
    end

    it "proceeds when there is no leftover" do
      Gori::CLI::Run.reserved_query_verb_error([] of String, "history",
        ["delete", "rm", "clear", "show"], "delete/rm, clear, show").should be_nil
    end

    it "refuses a discarded mutation verb and names the ordering that works" do
      msg = Gori::CLI::Run.reserved_query_verb_error(["delete", "42"], "history",
        ["delete", "rm", "clear", "show"], "delete/rm, clear, show")
      msg.should eq("gori run history: unknown subcommand 'delete' — global flags go AFTER " \
                    "the subcommand (`gori run history delete … --project=NAME`). Verbs: delete/rm, clear, show")
    end

    it "refuses probe's reserved scan-dispatcher verbs" do
      msg = Gori::CLI::Run.reserved_query_verb_error(["dismiss", "5"], "probe",
        ["issues", "dismiss", "promote", "delete", "rm", "rules", "mode"],
        "issues, dismiss, promote, delete/rm, rules, mode")
      msg.not_nil!.should contain("unknown subcommand 'dismiss'")
    end
  end
end
