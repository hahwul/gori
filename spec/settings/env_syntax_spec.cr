require "../spec_helper"
require "file_utils"

# `env.syntax` — which token grammar an install reads and writes.
#
# The migration rule, in one sentence: the ABSENCE of the key on a settings file that was read in
# full means BARE, forever. An existing install's tokens are already written into project
# databases, Repeater drafts, rewrite-rule replacements and slot headers, and nothing rewrites
# them — so only a genuinely NEW home may adopt the namespaced grammar, and it writes the key
# immediately so the decision is never re-derived.
#
# Every example runs in its own temp home and restores the process-global settings through a load
# of their serialization (the same discipline as reset_spec).
private def with_syntax_home(&)
  snapshot = Gori::Settings.export_document(Gori::Settings::SECTION_KEYS)
  prev_home = ENV["GORI_HOME"]?
  prev_cfg = ENV["GORI_CONFIG"]?
  prev_new = Gori::Settings.new_install_env_syntax
  dir = File.tempname("gori-env-syntax")
  Dir.mkdir_p(dir)
  begin
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    Gori::Settings.path_override = nil
    # `load` is TOLERANT: a file with no `env` section leaves the prefix and the vars exactly as
    # they were, and `export_document` omits an empty `env` — so without this the previous
    # example's `"prefix": "%"` survives the restore below and decides whether the section
    # serializes at all.
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    yield dir
  ensure
    Gori::Settings.env_prefix = Gori::Settings::DEFAULT_ENV_PREFIX
    Gori::Settings.env_vars = [] of {String, String}
    Gori::Settings.new_install_env_syntax = prev_new
    Gori::Settings.path_override = nil
    ENV["GORI_HOME"] = dir
    ENV.delete("GORI_CONFIG")
    File.write(File.join(dir, "settings.json"), snapshot)
    Gori::Settings.load
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    prev_cfg ? (ENV["GORI_CONFIG"] = prev_cfg) : ENV.delete("GORI_CONFIG")
    FileUtils.rm_rf(dir)
  end
end

private def env_section(path : String) : Hash(String, JSON::Any)?
  JSON.parse(File.read(path)).as_h["env"]?.try(&.as_h)
end

describe "Settings env.syntax" do
  it "round-trips through the file, and always writes the key once the section exists" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      Gori::Settings.load
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.save.should be_true
      env_section(path).should eq({"syntax" => JSON::Any.new("namespaced")})
      Gori::Settings.env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # A section that exists for ANY reason carries the grammar: a file saying "vars" but not
      # "syntax" means bare, so omitting it would downgrade the install on its next load.
      Gori::Settings.env_vars = [{"HOST", "h"}]
      Gori::Settings.save.should be_true
      env_section(path).not_nil!["syntax"].as_s.should eq("namespaced")
    end
  end

  it "reads the ABSENCE of the key as bare, and an untouched bare install writes no env section" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"theme":"gori","env":{"vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      Gori::Settings.env_vars.should eq([{"A", "1"}])
      # Nothing to say ⇒ no section at all, so a bare install's settings.json diff stays empty.
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.save.should be_true
      JSON.parse(File.read(path)).as_h.has_key?("env").should be_false
    end
  end

  it "does not leak a namespaced home's grammar into the NEXT home loaded in one process" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
    end
    # A second home, bare, loaded by the same process — the project picker and `--config` both do
    # exactly this.
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"theme":"gori"}))
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  it "warns and stays bare on an unknown value" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"NAMESPACED!"}}))
      io = IO::Memory.new
      prev = Gori::Settings.warning_io
      Gori::Settings.warning_io = io
      Gori::Settings.reset_load_warning_guard
      begin
        Gori::Settings.load
      ensure
        Gori::Settings.warning_io = prev
      end
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      io.to_s.should contain("env.syntax")
    end
  end

  it "a genuinely NEW home adopts the namespaced grammar and writes it immediately" do
    with_syntax_home do |dir|
      Gori::Settings.new_install_env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      # Written, so the operator's first project cannot change the answer later.
      env_section(File.join(dir, "settings.json")).not_nil!["syntax"].as_s.should eq("namespaced")
    end
  end

  it "writes nothing when the adopted grammar IS the default" do
    with_syntax_home do |dir|
      Gori::Settings.new_install_env_syntax = Gori::Env::Syntax::Bare
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      File.exists?(File.join(dir, "settings.json")).should be_false
    end
  end

  it "stays bare when the home already holds a project database" do
    with_syntax_home do |dir|
      Gori::Settings.new_install_env_syntax = Gori::Env::Syntax::Namespaced
      Dir.mkdir_p(File.join(dir, "projects", "acme"))
      File.write(File.join(dir, "projects", "acme", "gori.db"), "")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
      File.exists?(File.join(dir, "settings.json")).should be_false
    end
  end

  it "stays bare when the default database is there" do
    with_syntax_home do |dir|
      Gori::Settings.new_install_env_syntax = Gori::Env::Syntax::Namespaced
      File.write(File.join(dir, "gori.db"), "")
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  # A settings file that IS there and could not be read: its `env.syntax` may well say bare, and
  # adopting the other grammar would reinterpret every token in every project of an install that
  # has hit a permissions problem.
  it "stays bare when a settings file exists but cannot be read" do
    with_syntax_home do |dir|
      Gori::Settings.new_install_env_syntax = Gori::Env::Syntax::Namespaced
      path = File.join(dir, "settings.json")
      Dir.mkdir_p(path) # a directory where the file should be: `load_raw` rescues, reads nothing
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    ensure
      Dir.delete(File.join(dir, "settings.json")) rescue nil
    end
  end

  it "stays bare when the file is unparseable" do
    with_syntax_home do |dir|
      Gori::Settings.new_install_env_syntax = Gori::Env::Syntax::Namespaced
      File.write(File.join(dir, "settings.json"), "{not json")
      Gori::Settings.reset_load_warning_guard
      Gori::Settings.load
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  # The reason the absence rule may NOT live in `parse_env`: an import reuses `apply_sections`
  # over a FILTERED document, so a theme-only profile would otherwise flip the grammar back.
  it "an import that does not mention env leaves the grammar alone" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      Gori::Settings.import_document(%({"theme":"goriday"})).should eq(["theme"])
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      env_section(File.join(dir, "settings.json")).not_nil!["syntax"].as_s.should eq("namespaced")
    end
  end

  it "an env import without a syntax keeps the current one; with one, applies it" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"), %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      Gori::Settings.import_document(%({"env":{"vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      Gori::Settings.import_document(%({"env":{"syntax":"bare"}}))
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Bare)
    end
  end

  it "a factory reset PRESERVES the grammar" do
    with_syntax_home do |dir|
      File.write(File.join(dir, "settings.json"),
        %({"theme":"goriday","env":{"syntax":"namespaced","vars":[{"key":"A","value":"1"}]}}))
      Gori::Settings.load
      Gori::Settings.reset_to_factory.should eq(Gori::Settings::ResetResult::Saved)
      # The vars and the prefix are DATA and go; the grammar decides how tokens already stored in
      # project databases are read, and a settings reset does not speak for those.
      Gori::Settings.env_vars.should be_empty
      Gori::Settings.env_syntax.should eq(Gori::Env::Syntax::Namespaced)
      env_section(File.join(dir, "settings.json")).should eq({"syntax" => JSON::Any.new("namespaced")})
    end
  end

  # A vars-less namespaced install writes `env` — a GRAMMAR, not a credential. Firing the
  # "this file holds secrets" notice over it trains the operator to ignore it.
  it "exported_secret_sections ignores an env section that holds no vars" do
    with_syntax_home do
      Gori::Settings.load
      Gori::Settings.env_syntax = Gori::Env::Syntax::Namespaced
      Gori::Settings.env_vars = [] of {String, String}
      Gori::Settings.document_keys.includes?("env").should be_true
      Gori::Settings.exported_secret_sections(["env"]).should be_empty
      Gori::Settings.env_vars = [{"TOKEN", "v"}]
      Gori::Settings.exported_secret_sections(["env"]).should eq(["env"])
    ensure
      Gori::Settings.env_vars = [] of {String, String}
    end
  end

  # The 3-way merge asks "did I change this section?". Bare is representable as absence, so a
  # namespaced install's `syntax` must survive a peer's write to an unrelated section.
  it "survives a merge against a peer's concurrent write" do
    with_syntax_home do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, %({"env":{"syntax":"namespaced"}}))
      Gori::Settings.load
      # A peer rewrites the file between our load and our save, touching another section.
      File.write(path, %({"theme":"goriday","env":{"syntax":"namespaced"}}))
      Gori::Settings.mouse = false
      Gori::Settings.save.should be_true
      doc = JSON.parse(File.read(path)).as_h
      doc["theme"].as_s.should eq("goriday") # the peer's edit survived
      doc["env"].as_h["syntax"].as_s.should eq("namespaced")
    end
  end
end
