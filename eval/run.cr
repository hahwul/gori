# Runs every eval task against `claude -p` with gori MCP attached, once per catalogue
# profile, and grades the answers against the fixture's answer key:
#
#   crystal run eval/run.cr -- [--model sonnet] [--n 3] [--jobs 4]
#                              [--profiles minimal,recon,full,full-ro] [--tasks t0-*]
#
# Build the fixtures first (`just eval-fixtures`) and gori itself (`just build`). Every run
# gets its own copy of the fixture db, its own GORI_HOME and an empty cwd, so neither the
# operator's gori settings nor a repo CLAUDE.md leaks in; `--setting-sources ""` and
# `--strict-mcp-config` keep the operator's Claude Code settings, hooks and other MCP
# servers out. The raw stream of each run stays under eval/out/runs/<stamp>/ for reading.
require "file_utils"
require "json"
require "option_parser"
require "yaml"

ROOT     = File.expand_path("..", __DIR__)
EVAL     = File.join(ROOT, "eval")
GORI_BIN = File.join(ROOT, "bin", "gori")

PROFILES = {
  "minimal" => ["--tools=@minimal"],
  "recon"   => ["--tools=@recon"],
  "full"    => [] of String,
  "full-ro" => ["--read-only"],
}

ANSWER_RULE = "Use only the gori MCP tools to inspect the capture. When you are done, end " \
              "your reply with exactly one final line of the form `ANSWER: <JSON value>` " \
              "(a JSON array, string or number)."

record Task, id : String, fixture : String, tier : Int32, grade : String, prompt : String
record Job, task : Task, profile : String, rep : Int32

model = "sonnet"
reps = 3
jobs = 4
budget = "2"
profiles = PROFILES.keys
task_glob = "*"
OptionParser.parse do |p|
  p.on("--model=M", "claude model alias or id (default sonnet)") { |v| model = v }
  p.on("--n=N", "repetitions per task × profile (default 3)") { |v| reps = v.to_i }
  p.on("--jobs=N", "runs in parallel (default 4)") { |v| jobs = v.to_i }
  p.on("--budget=USD", "--max-budget-usd per run (default 2)") { |v| budget = v }
  p.on("--profiles=LIST", "comma-separated: #{PROFILES.keys.join(',')}") { |v| profiles = v.split(',') }
  p.on("--tasks=GLOB", "task id glob (default *)") { |v| task_glob = v }
end
abort "unknown profile in #{profiles}" unless profiles.all? { |pr| PROFILES.has_key?(pr) }
abort "#{GORI_BIN} missing: run `just build`" unless File.exists?(GORI_BIN)

tasks = Dir.glob(File.join(EVAL, "tasks", "#{task_glob}.yml")).sort.map do |f|
  y = YAML.parse(File.read(f))
  Task.new(File.basename(f, ".yml"), y["fixture"].as_s, y["tier"].as_i, y["grade"].as_s, y["prompt"].as_s)
end
abort "no tasks match #{task_glob}" if tasks.empty?

truths = tasks.map(&.fixture).uniq!.to_h do |fx|
  path = File.join(EVAL, "out", "fixtures", "#{fx}.truth.json")
  abort "#{path} missing: run `just eval-fixtures`" unless File.exists?(path)
  {fx, JSON.parse(File.read(path))}
end

stamp = Time.local.to_s("%Y%m%d-%H%M%S")
run_dir = File.join(EVAL, "out", "runs", stamp)
FileUtils.mkdir_p(run_dir)

# An answer the agent spelled as "70" grades the same as 70; a set ignores order.
def grade(task : Task, answer : JSON::Any?, truth : JSON::Any) : Bool
  return false unless answer
  case task.grade
  when "set"
    got = answer.as_a?.try(&.map { |v| v.as_i64? || v.as_s?.try(&.to_i64?) }) || return false
    return false if got.any?(Nil)
    got.compact.sort! == truth.as_a.map(&.as_i64).sort!
  else
    norm = ->(v : JSON::Any) { v.as_s? || v.to_json }
    norm.call(answer).strip == norm.call(truth).strip
  end
end

# The gori tools a run called, in order; how many tools init listed that are not gori's
# (anything above zero means the isolation leaked); and the final `result` event.
def read_stream(path : String) : {Array(String), Int32, JSON::Any?}
  calls = [] of String
  foreign = 0
  result = nil
  File.each_line(path) do |line|
    ev = JSON.parse(line) rescue next
    case ev["type"]?.try(&.as_s?)
    when "system"
      if ev["subtype"]?.try(&.as_s?) == "init"
        foreign = ev["tools"].as_a.count { |t| !t.as_s.starts_with?("mcp__gori__") }
      end
    when "assistant"
      ev.dig?("message", "content").try(&.as_a?).try &.each do |blk|
        calls << blk["name"].as_s.lchop("mcp__gori__") if blk["type"]? == "tool_use"
      end
    when "result" then result = ev
    end
  end
  {calls, foreign, result}
end

def run_one(job : Job, run_dir : String, model : String, budget : String, truth : JSON::Any) : Hash(String, JSON::Any)
  dir = File.join(run_dir, "#{job.task.id}.#{job.profile}.#{job.rep}")
  cwd = File.join(dir, "cwd")
  home = File.join(dir, "gori_home")
  FileUtils.mkdir_p([cwd, home])
  db = File.join(dir, "fixture.db")
  FileUtils.cp(File.join(EVAL, "out", "fixtures", "#{job.task.fixture}.db"), db)

  mcp = {mcpServers: {gori: {command: GORI_BIN, args: ["mcp", "--db", db] + PROFILES[job.profile],
                             env: {GORI_HOME: home}}}}.to_json
  args = ["-p", job.task.prompt, "--model", model, "--output-format", "stream-json", "--verbose",
          "--setting-sources", "", "--strict-mcp-config", "--mcp-config", mcp,
          "--tools", "", "--allowedTools", "mcp__gori", "--append-system-prompt", ANSWER_RULE,
          "--max-budget-usd", budget, "--no-session-persistence"]
  stream = File.join(dir, "stream.jsonl")
  started = Time.instant
  File.open(stream, "w") do |sout|
    File.open(File.join(dir, "stderr.txt"), "w") do |err|
      Process.run("claude", args, chdir: cwd, output: sout, error: err)
    end
  end
  elapsed = (Time.instant - started).total_seconds

  calls, foreign, result = read_stream(stream)
  text = result.try(&.["result"]?).try(&.as_s?) || ""
  answer = text.lines.reverse_each.find(&.starts_with?("ANSWER:")).try do |l|
    raw = l.lchop("ANSWER:").strip.strip('`').strip
    JSON.parse(raw) rescue JSON::Any.new(raw)
  end
  usage = result.try(&.["usage"]?)
  tokens = %w[input_tokens cache_read_input_tokens cache_creation_input_tokens].sum do |k|
    usage.try(&.[k]?).try(&.as_i64?) || 0_i64
  end
  {
    "task"          => JSON::Any.new(job.task.id),
    "tier"          => JSON::Any.new(job.task.tier.to_i64),
    "profile"       => JSON::Any.new(job.profile),
    "rep"           => JSON::Any.new(job.rep.to_i64),
    "pass"          => JSON::Any.new(grade(job.task, answer, truth)),
    "answer"        => answer || JSON::Any.new(nil),
    "calls"         => JSON::Any.new(calls.map { |c| JSON::Any.new(c) }),
    "input_tokens"  => JSON::Any.new(tokens),
    "output_tokens" => JSON::Any.new(usage.try(&.["output_tokens"]?).try(&.as_i64?) || 0_i64),
    "cost_usd"      => JSON::Any.new(result.try(&.["total_cost_usd"]?).try(&.as_f?) || 0.0),
    "turns"         => JSON::Any.new(result.try(&.["num_turns"]?).try(&.as_i64?) || 0_i64),
    "seconds"       => JSON::Any.new(elapsed.round(1)),
    "error"         => JSON::Any.new(result.nil? || result.try(&.["is_error"]?).try(&.as_bool?) == true),
    "foreign_tools" => JSON::Any.new(foreign.to_i64),
  }
end

queue = Channel(Job).new(tasks.size * profiles.size * reps)
tasks.each { |t| profiles.each { |pr| reps.times { |i| queue.send(Job.new(t, pr, i + 1)) } } }
queue.close
total = tasks.size * profiles.size * reps
rows = Channel(Hash(String, JSON::Any)).new(total)

jobs.times do
  spawn do
    while job = queue.receive?
      truth = truths[job.task.fixture][job.task.id]
      rows.send(run_one(job, run_dir, model, budget, truth))
    end
  end
end

results = [] of Hash(String, JSON::Any)
File.open(File.join(run_dir, "results.jsonl"), "w") do |log|
  total.times do |i|
    row = rows.receive
    results << row
    log.puts row.to_json
    log.flush
    STDERR.puts "[#{i + 1}/#{total}] #{row["task"]} #{row["profile"]} ##{row["rep"]}: " \
                "#{row["pass"].as_bool ? "PASS" : "FAIL"} #{row["calls"].as_a.size} calls #{row["seconds"]}s"
  end
end

def median(xs : Array(Float64)) : Float64
  s = xs.sort
  s.empty? ? 0.0 : (s[(s.size - 1) // 2] + s[s.size // 2]) / 2
end

puts
puts "model=#{model} n=#{reps} → #{run_dir}"
puts "%-22s %-8s %5s %6s %9s %7s %6s" % %w[task profile pass calls in_tok cost secs]
results.group_by { |r| {r["task"].as_s, r["profile"].as_s} }.to_a.sort_by(&.first).each do |(task, pr), rs|
  med = ->(k : String) { median(rs.map { |r| r[k].as_f? || r[k].as_i64.to_f }) }
  puts "%-22s %-8s %2d/%-2d %6.1f %8.0fk %7.3f %6.1f" % {
    task, pr, rs.count(&.["pass"].as_bool), rs.size, median(rs.map(&.["calls"].as_a.size.to_f)),
    med.call("input_tokens") / 1000, med.call("cost_usd"), med.call("seconds"),
  }
end
if (bad = results.count { |r| r["error"].as_bool || r["foreign_tools"].as_i64 > 0 }) > 0
  puts "#{bad} run(s) errored or saw non-gori tools — read their stream.jsonl"
end
