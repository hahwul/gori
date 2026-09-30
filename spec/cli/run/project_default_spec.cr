require "../../spec_helper"
require "file_utils"

# #1387: which project a `--project`-less `gori run` reads. It was the most recently active
# project and nothing else, so one write elsewhere silently re-aimed every later command.
# `GORI_PROJECT` and a `project switch` pin now sit in front of that, and a pin that names no
# project is REFUSED — falling through would be the very re-aim they exist to stop.
private def with_projects(&)
  root = File.tempname("gori-defaultroot")
  begin
    yield Gori::ProjectRegistry.new(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

private def pick(registry, env, pin)
  Gori::CLI::Run.default_project(registry, env, pin)
end

describe "gori run — the default project (#1387)" do
  it "prefers GORI_PROJECT, then the pin, then the most recently active project" do
    with_projects do |registry|
      alpha = registry.create("alpha")
      beta = registry.create("beta")
      recent = Gori::ProjectRegistry.default_of(registry.list).not_nil!
      pick(registry, nil, nil).should eq({recent, Gori::CLI::Run::DefaultSource::Recent})
      pick(registry, nil, "alpha").should eq({alpha, Gori::CLI::Run::DefaultSource::Pinned})
      pick(registry, "beta", "alpha").should eq({beta, Gori::CLI::Run::DefaultSource::Env})
      # The pin is the short id `project switch` writes, which still resolves.
      pick(registry, nil, registry.id_of(alpha)).as(Tuple)[0].dir.should eq(alpha.dir)
    end
  end

  it "refuses a pin naming nothing instead of falling through to the recent project" do
    with_projects do |registry|
      registry.create("alpha")
      pick(registry, "nope", nil).as(String).should contain("GORI_PROJECT=\"nope\" names no project")
      pick(registry, "  ", nil).as(String).should contain("set but empty")
      pick(registry, nil, "gone").as(String).should contain("project switch --clear")
      # …and GORI_PROJECT refusing does not quietly consult the pin behind it.
      pick(registry, "nope", "alpha").should be_a(String)
    end
  end

  it "answers nil when there is no project at all" do
    with_projects { |registry| pick(registry, nil, nil).should be_nil }
  end

  it "names the rule that chose it" do
    Gori::CLI::Run::DefaultSource::Env.phrase.should contain("GORI_PROJECT")
    Gori::CLI::Run::DefaultSource::Pinned.phrase.should contain("project switch")
    Gori::CLI::Run::DefaultSource::Recent.phrase.should eq("most recently active")
  end
end
