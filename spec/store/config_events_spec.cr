require "../spec_helper"

# #864 second half: a change the HUMAN makes has to reach the feed too.
#
# Recorded at the MODEL (`Scope`, `HostOverrides`, `Rules`, `Env`), which is what makes one site
# per change cover TUI, CLI and MCP at once — all three reach the same object. `actor` is what
# tells them apart afterwards, and it is defaulted from `FlowSource.surface`, so these specs set
# that the way an entry point does.
private def cfg_store(surface : Gori::FlowSource::Surface? = Gori::FlowSource::Surface::Tui, &)
  path = File.tempname("gori-config-events", ".db")
  store = Gori::Store.open(path)
  saved = Gori::FlowSource.surface
  Gori::FlowSource.surface = surface
  begin
    yield store
  ensure
    Gori::FlowSource.surface = saved
    store.close rescue nil
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def config_events(store : Gori::Store) : Array(Gori::Store::EventRow)
  store.flush
  store.events_recent(100, source: Gori::ConfigLog::SOURCE).rows
end

describe "config changes reach the event feed" do
  it "records a scope rule being added, changed and removed, with the pattern" do
    cfg_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test").should be_true
      id = scope.rules.first.id
      scope.update(id, "include", "host", "api.acme.test").should be_true
      scope.remove(id).should be_true

      rows = config_events(store).reverse
      rows.map(&.kind).should eq(["scope_add", "scope_update", "scope_remove"])
      rows[0].message.should contain("acme.test")
      rows[1].message.should contain("api.acme.test")
      rows[2].message.should contain("api.acme.test")
      rows.each(&.actor.should(eq("tui")))
    end
  end

  # A rule the store REFUSED never gated a request, so recording it would put a control in the
  # audit trail that never existed. Every one of these models returns whether the write
  # committed — several had to be fixed to do so — and that answer is the gate.
  it "does not record a rule the store refused" do
    cfg_store do |store|
      scope = Gori::Scope.load(store)
      scope.add("include", "host", "acme.test").should be_true
      scope.add("include", "host", "acme.test").should be_false # duplicate
      scope.add("include", "host", "").should be_false          # invalid

      config_events(store).count { |r| r.kind == "scope_add" }.should eq(1)
    end
  end

  # The sandbox is the hard containment gate, not a display lens — the last setting that should
  # be able to move without the log saying who moved it.
  it "records the sandbox and the scope lens" do
    cfg_store do |store|
      scope = Gori::Scope.load(store)
      scope.toggle_sandbox
      scope.toggle

      kinds = config_events(store).map(&.kind)
      kinds.should contain("sandbox")
      kinds.should contain("scope_lens")
      config_events(store).find(&.kind.== "sandbox").not_nil!.message.should contain("ON")
    end
  end

  it "records host override changes with both ends of the dial map" do
    cfg_store do |store|
      ov = Gori::HostOverrides.load(store)
      ov.add("acme.test", "10.0.0.1").should be_true
      config_events(store).first.message.should contain("acme.test")
      config_events(store).first.message.should contain("10.0.0.1")
    end
  end

  # The `$KEY` table is the one config surface whose content is secret by default, so the line
  # carries NAMES and never values.
  it "records env vars by name and never by value" do
    cfg_store do |store|
      Gori::Env.save_project(store, [{"ADMIN_TOKEN", "s3cr3t-do-not-log"}]).should be_true

      row = config_events(store).find(&.kind.== "env").not_nil!
      row.message.should contain("ADMIN_TOKEN")
      row.message.should_not contain("s3cr3t-do-not-log")
    end
  end

  it "attributes the same change to whichever surface made it" do
    cfg_store(Gori::FlowSource::Surface::Cli) do |store|
      Gori::Scope.load(store).add("include", "host", "acme.test").should be_true
      config_events(store).first.actor.should eq("cli")
    end
    cfg_store(Gori::FlowSource::Surface::Mcp) do |store|
      Gori::Scope.load(store).add("include", "host", "acme.test").should be_true
      config_events(store).first.actor.should eq("mcp")
    end
    # No entry point ran — "not recorded" is an honest answer, and better than defaulting to a
    # surface the process is not.
    cfg_store(nil) do |store|
      Gori::Scope.load(store).add("include", "host", "acme.test").should be_true
      config_events(store).first.actor.should be_nil
    end
  end
end

describe "actor attribution" do
  # A background engine acts on NO surface's behalf. Defaulting `insert_event`'s actor to the
  # ambient surface filed every one of these under whichever process observed it — `tui` in the
  # TUI, `mcp` inside an MCP server, for the same event — and the actor filter then returned
  # them as the operator's own doing.
  it "leaves an engine's own event un-actored" do
    cfg_store do |store|
      store.insert_event("bindings", "extract_miss", "warn", "$sid found nothing")
      store.insert_event("probe", "alt_svc_h3", "info", "advertised HTTP/3")
      store.flush

      store.events_recent(50, source: "bindings").rows.first.actor.should be_nil
      store.events_recent(50, source: "probe").rows.first.actor.should be_nil
      # …and the actor filter does not sweep them up with the operator's changes.
      Gori::Scope.load(store).add("include", "host", "acme.test").should be_true
      store.flush
      rows = store.events_recent(50, actor: "tui").rows
      rows.size.should eq(1)
      rows.first.source.should eq(Gori::ConfigLog::SOURCE)
    end
  end
end

describe "rewrite rule audit lines" do
  # The motivating case for rewrite rules is REDACTION — stripping an Authorization token
  # before it leaves — and that puts the token in the PATTERN, with a harmless placeholder in
  # the replacement. Logging either half leaks; the line carries neither.
  it "names a rule by identity and never by the bytes it matches or writes" do
    cfg_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head,
        "Bearer eyJhbGciOi-SECRET-TOKEN", "Bearer REDACTED-PLACEHOLDER",
        name: "strip auth").should be_true
      store.flush

      row = store.events_recent(50, source: Gori::ConfigLog::SOURCE).rows.first
      row.kind.should eq("rule_add")
      row.message.should contain("strip auth")
      row.message.should_not contain("SECRET-TOKEN")
      row.message.should_not contain("REDACTED-PLACEHOLDER")
    end
  end

  # `set_scope` moves a rule by copying it and deleting the original. Logging that delete put
  # "rule removed" in the trail for a rule that still exists, and the move was never recorded.
  it "records a scope move as a move, not as a removal" do
    cfg_store do |store|
      rules = Gori::Rules.load(store)
      rules.add(Gori::Store::RuleTarget::Request, Gori::Store::RulePart::Head, "X-A", "X-B",
        name: "movable").should be_true
      rule = rules.rules.find { |r| r.name == "movable" }.not_nil!
      rules.set_scope(rule, Gori::Store::RuleScope::Global).should be_true
      store.flush

      kinds = store.events_recent(50, source: Gori::ConfigLog::SOURCE).rows.map(&.kind)
      kinds.should contain("rule_move")
      kinds.should_not contain("rule_remove")
    end
  end
end

describe Gori::ConfigLog do
  # An audit trail that leaks the secret it exists to protect is worse than none.
  it "strips userinfo from a proxy URL and keeps the host" do
    Gori::ConfigLog.scrub_url("http://bob:hunter2@corp.example:8080").should eq(
      "http://#{Gori::ConfigLog::REDACTED}@corp.example:8080")
    Gori::ConfigLog.scrub_url("http://corp.example:8080").should eq("http://corp.example:8080")
    # A `@` in the PATH is not userinfo, and a scrubber that reaches past the authority erases
    # the host — the one fact the audit line is for.
    Gori::ConfigLog.scrub_url("http://corp.example/a@b").should eq("http://corp.example/a@b")
    # …while a real credential before that path is still taken.
    Gori::ConfigLog.scrub_url("http://bob:pw@corp.example/a@b").should eq(
      "http://#{Gori::ConfigLog::REDACTED}@corp.example/a@b")
    Gori::ConfigLog.scrub_url("socks5://u:p@10.0.0.1:1080").should eq(
      "socks5://#{Gori::ConfigLog::REDACTED}@10.0.0.1:1080")
  end
end
