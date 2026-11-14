require "../../spec_helper"

# Under `--json` a refusal has to put an object on stdout, or a script reading stdout gets
# nothing. Three shapes were still bare `abort`s: a write that did not commit (`busy_abort` —
# MCP's `PROJECT_BUSY`, retryable), a delete that took no `--json`, and a stray flag counted
# as a second positional. The stderr line and the exit code of each are what they were.
module Gori::CLI::Run
  def self.one_positional_list_for_spec(before : Array(String), after : Array(String)) : Array(String)
    one_positional_list(before, after, "gori run x", "name")
  end

  def self.one_positional_list_for_spec(args : Array(String)) : Array(String)
    one_positional_list(args, "gori run x", "name") { }
  end
end

module JsonRefusals
  ROOT = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")

  BUSY = /busy|unwritable|not writable|could not (be )?writ|failed to persist|failed to delete|did not commit|did not persist|nothing was saved/i

  # Left on purpose, each with its reason. An entry that stops matching fails below, so a fix
  # deletes its own line.
  ALLOWED = {
    {"project.cr", "could not write archive"},                      # the archive path, not the project
    {"project_default.cr", "could not write \#{default_pin_path}"}, # the pin file
  }

  # Each `abort`/`abort_closing` call, with the string continuation lines that follow it.
  def self.abort_calls(path : String) : Array(String)
    lines = File.read_lines(path)
    calls = [] of String
    lines.each_with_index do |line, i|
      next if line.lstrip.starts_with?('#')
      next unless line =~ /(?<![\w])abort(_closing)?[ (]/
      call = line
      j = i
      while lines[j].rstrip.ends_with?('\\') && j + 1 < lines.size
        j += 1
        call += lines[j]
      end
      calls << call
    end
    calls
  end

  # The body of `def self.<name>`, up to the next method at the same indent.
  def self.method(file : String, name : String) : String
    src = File.read(File.join(ROOT, file))
    start = src.index("def self.#{name}(") || raise "#{file}: no #{name}"
    stop = src.index(/\n      (private )?def self\./, start + 1) || src.size
    src[start...stop]
  end
end

describe "gori run — a write that did not commit answers --json" do
  it "leaves no bare abort carrying a busy phrasing, in any command file" do
    seen = Set({String, String}).new
    left = [] of String
    glob_files(JsonRefusals::ROOT, "*.cr").sort.each do |path|
      file = File.basename(path)
      JsonRefusals.abort_calls(path).each do |call|
        next unless call =~ JsonRefusals::BUSY
        if hit = JsonRefusals::ALLOWED.find { |(f, s)| f == file && call.includes?(s) }
          seen << hit
        else
          left << "#{file}: #{call.strip}"
        end
      end
    end
    left.should eq([] of String)
    (JsonRefusals::ALLOWED.to_set - seen).should be_empty
  end

  it "builds repeater's write-failure aborts through busy_abort" do
    src = File.read(File.join(JsonRefusals::ROOT, "repeater.cr"))
    src.should_not contain("abort project_write_failure")
    src.should contain("busy_abort(\"gori run repeater create\", project_write_failure(")
  end

  it "keys Bindings' commit refusal off its constant, as MCP does" do
    File.read(File.join(JsonRefusals::ROOT, "rewriter.cr")).scan("if err == Bindings::STORE_REFUSED").size.should eq(2)
  end
end

describe "gori run <delete> --json — the deletes that took none" do
  it "routes each one's not-found and its success through the shared helpers" do
    {
      {"issues.cr", %(refuse_missing_issues(store, ids, "gori run issues delete", "deleted", format))},
      {"issues.cr", "not_found_abort(cmd, \"no issue with id"},
      {"issues.cr", "deleted_json(ids)"},
      {"history.cr", "not_found_abort(\"gori run history delete\""},
      {"history.cr", "deleted_json(ids)"},
      {"history.cr", "deleted_count_json(n)"},
      {"notes.cr", %(resolve_note_index(store, persisted, n_arg, note_id, "gori run notes delete", format))},
      {"notes.cr", "not_found_abort(cmd, \"no note"},
      {"notes.cr", %(deleted_json("id", target_id))},
      {"oast.cr", %(oast_provider_row_id(store, id, "delete", format))},
      {"oast.cr", "not_found_abort(\"gori run oast providers \#{verb}\""},
      {"oast.cr", "deleted_json(\"id\", \"p_\#{row}\")"},
      {"project.cr", %(abort_unknown_project(registry, name, "gori run project delete", format))},
      {"project.cr", "not_found_abort(cmd, \"no project matching"},
    }.each do |file, needle|
      File.read(File.join(JsonRefusals::ROOT, file)).should contain(needle), failure_message: "#{file}: #{needle}"
    end
  end

  it "probe delete: the id, or the count under --all" do
    body = JsonRefusals.method("probe.cr", "cmd_probe_delete")
    body.should contain("format_flag(p, [:text, :json]")
    body.should contain("not_found_abort(\"gori run probe delete\"")
    body.should contain(%(deleted_json("id", issue.id)))
    JsonRefusals.method("probe.cr", "probe_delete_all").should contain("deleted_count_json(n.to_i64)")
  end

  it "views rm and wordlist delete: the name, not-found through each one's shared helper" do
    body = JsonRefusals.method("views.cr", "cmd_views_rm")
    body.should contain(%(views_find_or_abort(store, name, scope, "rm", format)))
    body.should contain(%(deleted_json("name", view.name)))
    JsonRefusals.method("views.cr", "views_find_or_abort").scan("not_found_abort(").size.should eq(2)
    body = JsonRefusals.method("wordlist.cr", "cmd_wordlist_delete")
    body.should contain(%(wordlist_error("delete", ex, format)))
    body.should contain(%(deleted_json("name", name)))
    JsonRefusals.method("wordlist.cr", "wordlist_error").should contain("not_found_abort(")
  end

  it "grpc forget: the target, or the count under --all, and PROJECT_BUSY when it did not save" do
    JsonRefusals.method("grpc.cr", "cmd_grpc_forget").should contain("not_found_abort(\"gori run grpc forget\"")
    report = JsonRefusals.method("grpc.cr", "grpc_forget_report")
    report.should contain(%(deleted_json("target", target)))
    report.should contain("deleted_count_json(known.to_i64)")
    report.should contain("busy_abort(\"gori run grpc forget\"")
  end

  it "redact rm: the name, and NOT_FOUND in both scopes" do
    body = JsonRefusals.method("redact.cr", "cmd_redact_rm")
    body.should contain("not_found_abort(\"gori run redact rm\"")
    body.should contain("RedactMissing.new(")
    body.scan(%(deleted_json("name", name))).size.should eq(2)
  end
end

# `redact rm NAME --json` refused as "too many arguments": a parser kept whole counts its
# positionals inside `unknown_args`, which OptionParser runs before `invalid_option`.
describe "gori run — one positional, counted inside unknown_args" do
  it "leaves a stray flag to invalid_option, and keeps `-` and what follows `--`" do
    Gori::CLI::Run.one_positional_list_for_spec(["work", "--json"], [] of String).should eq(["work"])
    Gori::CLI::Run.one_positional_list_for_spec(["-"], [] of String).should eq(["-"])
    Gori::CLI::Run.one_positional_list_for_spec([] of String, ["--odd-name"]).should eq(["--odd-name"])
  end

  # The parsed-args path joins both halves before the count, so nothing is filtered there:
  # `probe mode off -- -extra` must stay "too many arguments", never a write with a word dropped.
  it "drops nothing on the parsed-args path" do
    Gori::CLI::Run.one_positional_list_for_spec(["--", "-x"]).should eq(["-x"])
    Gori::CLI::Run.extra_positional_error(["off", "-extra"], "gori run probe mode", "<mode>").should_not be_nil
    src = File.read(File.join(JsonRefusals::ROOT, "..", "run.cr"))
    src.scan("before.reject").size.should eq(1)
  end
end
