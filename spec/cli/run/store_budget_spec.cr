require "../../spec_helper"

# Which SQLite wait budget a `gori run` subcommand opens its project with.
#
# `open_store` is the one door every subcommand uses, and #1118 gave it a one-second busy /
# checkout budget on the premise that a CLI invocation is one-shot. Six of them are not: a
# crawl, a sweep, a HAR stream, a scan, a retest and a listen keep the handle open for the whole
# run and write through it as they go. Measured against a peer holding `BEGIN IMMEDIATE`, the
# one-second budget refused those writes too — a dropped batch of findings, not a fast exit.
# Those callers now say `long_running: true` and keep the Store's own defaults.
#
# The choice is pinned as a pure function plus the wiring, rather than by timing a contended
# open: the timing is SQLite's, and a spec that sleeps five seconds to prove a constant is the
# wrong trade.
private def cli_src(*parts : String) : String
  File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", *parts)).lines
    .reject(&.lstrip.starts_with?('#')).join('\n')
end

describe "gori run — the SQLite wait budget a subcommand opens with" do
  it "keeps a short-lived subcommand on the bounded one-shot budget" do
    busy, checkout = Gori::CLI::Run.store_budget(false)
    busy.should eq(Gori::CLI::Run::CLI_BUSY_TIMEOUT_MS)
    checkout.should eq(Gori::CLI::Run::CLI_CHECKOUT_TIMEOUT_SECONDS)
    busy.should be < Gori::Store::SQLITE_BUSY_TIMEOUT_MS
    checkout.should be < Gori::Store::DB_CHECKOUT_TIMEOUT_SECONDS
  end

  it "gives a subcommand that holds the project for a whole run the Store's own defaults" do
    Gori::CLI::Run.store_budget(true)
      .should eq({Gori::Store::SQLITE_BUSY_TIMEOUT_MS, Gori::Store::DB_CHECKOUT_TIMEOUT_SECONDS})
  end

  # The wiring. Each of these holds its store across the run and writes through it; a new
  # caller of that shape belongs on this list, and a one-shot caller must NOT be on it.
  it "is asked for by every subcommand that keeps the store open across its run" do
    {
      {"run/discover.cr", 1},  # findings flushed in batches for the whole crawl
      {"run/fuzz.cr", 1},      # write_store: History / permanent results per round trip
      {"run/import.cr", 1},    # a HAR stream, chunk by chunk
      {"run/probe.cr", 1},     # a scan over every selected flow, --active sends
      {"run/retest.cr", 1},    # the live backend and the run summary
      {"run/oast.cr", 2},      # listen --save and resume touch the session row every poll tick
      {"run/intercept.cr", 4}, # only has a job when a TUI is capturing into the project
    }.each do |file, expected|
      cli_src(file).scan(/open_store\(.*long_running: true\)/).size.should eq(expected),
        "#{file}: expected #{expected} long_running open(s)"
    end
  end

  it "is not asked for by a one-shot subcommand" do
    %w[run/notes.cr run/issues.cr run/repeater.cr run/links.cr run/views.cr].each do |file|
      cli_src(file).should_not contain("long_running: true"), "#{file} is one-shot"
    end
  end

  it "hands the re-spelling the same budget as the open beside it" do
    run = cli_src("run.cr")
    open_store = run[/private def self\.open_store\(.*?\n      end\n/m].not_nil!
    open_store.should contain("busy_ms, checkout_s = store_budget(long_running)")
    open_store.should contain("busy_timeout_ms: busy_ms,")
    open_store.should contain("checkout_timeout_seconds: checkout_s)")
    open_store.should contain("hydrate_cli_store(store, project, busy_ms)")
    hydrate = run[/private def self\.hydrate_cli_store\(.*?\n      end\n/m].not_nil!
    hydrate.should contain("EnvMigration.reconcile(store, project.db_path, project.name,")
    hydrate.should contain("busy_timeout_ms: busy_ms))")
  end
end
