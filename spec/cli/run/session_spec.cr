require "../../spec_helper"
require "json"

# `gori run session` — the headless half of the session-slot list, plus `--slot`, which is
# this surface's "activate" (a `gori run` process sends and exits, so a persisted pointer has
# nothing to span).
#
# What is under test is the part with no I/O: the row/JSON projections a script reads, the
# `--set` parse, and the ACTIVATION seam. The `abort` branches (an unknown slot, an
# unparseable `--set`) are unreachable from a spec — `abort` calls `exit`, which would take
# the whole suite down — the same limit spec/cli/run/rewriter_spec.cr works under. So the
# activation seam is driven through the registry it mutates rather than through the flag.

private alias Slot = Gori::SessionSlot

private def with_store(&)
  path = File.tempname("gori-clislots", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

describe "gori run session — projections" do
  it "renders a row with the baseline diamond and header NAMES only" do
    slot = Slot.new("admin", [{"Cookie", "session=SUPERSECRET"}], ["X-Debug"], true, ["SESSION"])
    row = Gori::CLI::Run.session_slot_row(slot, false)
    row.should contain("◆")
    row.should contain("admin")
    row.should contain("sets Cookie")
    row.should contain("drops X-Debug")
    row.should contain("rules $SESSION")
    # The whole point of the default: a credential must not land in scrollback.
    row.should_not contain("SUPERSECRET")
  end

  it "prints values only under --show-values" do
    slot = Slot.new("admin", [{"Cookie", "session=SUPERSECRET"}])
    Gori::CLI::Run.session_slot_row(slot, true).should contain("Cookie: session=SUPERSECRET")
  end

  it "marks a passthrough slot as as-captured rather than as an empty overlay" do
    Gori::CLI::Run.session_slot_row(Slot.as_captured, false).should contain("as captured")
    Gori::CLI::Run.session_slot_row(Slot.as_captured, true).should contain("as captured")
  end

  it "redacts in the detail view too, and names the claimed rules with the env prefix" do
    slot = Slot.new("admin", [{"Cookie", "session=SUPERSECRET"}], ["Authorization"], false, ["SESSION"])
    plain = Gori::CLI::Run.session_slot_detail(slot, false)
    plain.should contain("set     Cookie: [REDACTED]")
    plain.should contain("remove  Authorization")
    plain.should contain("rule    $SESSION")
    plain.should_not contain("SUPERSECRET")
    Gori::CLI::Run.session_slot_detail(slot, true).should contain("session=SUPERSECRET")
  end

  it "emits the JSON a script keys on, redacted by default" do
    slot = Slot.new("low-priv", [{"Cookie", "session=SUPERSECRET"}], ["Authorization"], true, ["SESSION"])
    j = JSON.parse(JSON.build { |b| Gori::CLI::Run.session_slot_json(b, slot, false) })
    j["name"].as_s.should eq("low-priv")
    j["baseline"].as_bool.should be_true
    j["passthrough"].as_bool.should be_false
    j["set"][0]["name"].as_s.should eq("Cookie")
    j["set"][0]["value"].as_s.should eq("[REDACTED]")
    j["remove"].as_a.map(&.as_s).should eq(["Authorization"])
    j["rules"].as_a.map(&.as_s).should eq(["SESSION"])

    shown = JSON.parse(JSON.build { |b| Gori::CLI::Run.session_slot_json(b, slot, true) })
    shown["set"][0]["value"].as_s.should eq("session=SUPERSECRET")
  end
end

# `--set 'Name: value'` goes through `Discover::Headers.parse_lines`, the SAME parser the TUI's
# identity form runs its editor buffer through. Pinned here because the alternative — a local
# `partition(':')` — would accept a CR/LF-carrying value and let a slot forge a header boundary
# into every request it overlays.
describe "gori run session — the --set parse" do
  it "shares the TUI form's header parser, refusals and all" do
    rejected = [] of String
    ok = Gori::Discover::Headers.parse_lines(["Cookie: session=abc"], rejected)
    ok.should eq([{"Cookie", "session=abc"}])
    rejected.should be_empty

    Gori::Discover::Headers.parse_lines(["Cookie: a\r\nX-Admin: true"], rejected).should be_empty
    rejected.size.should eq(1)
  end

  it "is what the CLI actually calls" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "session.cr"))
    body = src[/def self\.parse_session_header.*?\n      end/m]
    body.should contain("Discover::Headers.parse_lines")
  end
end

# The active pointer, which is what `--slot` sets. Driven through the registry `activate_slot`
# mutates: the flag itself aborts on a bad name, and `abort` is not spec-able here.
describe "gori run session — the active slot" do
  it "is memory-only: a saved list survives, a selection does not" do
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.add(Slot.new("admin", [{"X-Who", "admin"}]))
      slots.activate("admin").should be_true
      slots.active_name.should eq("admin")

      # A second `gori run` invocation is a second process: same list, no pointer.
      fresh = Gori::SessionSlots.load(store)
      fresh.slots.map(&.name).should eq(["admin"])
      fresh.active_name.should be_nil
    end
  end

  it "changes the bytes a send seam produces, through Env.overlay_slot" do
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.add(Slot.new("admin", [{"X-Who", "admin"}]))
      previous = Gori::Env.layer
      begin
        Gori::Env.layer = Gori::Bindings.load(store, slots)
        wire = "GET / HTTP/1.1\r\nHost: h\r\n\r\n".to_slice
        # Nothing active: the SAME slice back, which is the compatibility guarantee.
        Gori::Env.overlay_slot(wire).to_unsafe.should eq(wire.to_unsafe)
        slots.activate("admin")
        String.new(Gori::Env.overlay_slot(wire)).should contain("X-Who: admin")
      ensure
        Gori::Env.layer = previous
      end
    end
  end

  it "refuses a name no slot has, rather than leaving the previous one active" do
    with_store do |store|
      slots = Gori::SessionSlots.load(store)
      slots.add(Slot.new("admin"))
      slots.activate("admin")
      slots.activate("adm1n").should be_false
      slots.active_name.should eq("admin")
    end
  end
end

# `--slot` has to be applied BEFORE `--bind-from` replays its seed: the seed fills the tables of
# whichever slots claim each matched rule, and the run then resolves `$NAME` out of the ACTIVE
# one. The other order seeds one identity and sends as another, silently.
describe "gori run — --slot ordering" do
  {"fuzz", "mine", "sequence", "discover"}.each do |cmd|
    it "activates before the #{cmd} bind-from seed" do
      src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "#{cmd}.cr"))
      lines = src.lines.reject(&.lstrip.starts_with?('#'))
      activate = lines.index(&.includes?("activate_slot(slot,"))
      preflight = lines.index(&.includes?("preflight_bind_from(bind_from,"))
      seed = lines.index(&.includes?("seed_bindings("))
      activate.should_not be_nil, "gori run #{cmd} lost its --slot activation"
      preflight.should_not be_nil
      activate.not_nil!.should be < preflight.not_nil!
      activate.not_nil!.should be < seed.not_nil! if seed
    end
  end

  # A `gori run` command opens its project MORE THAN ONCE — the flow read, the host-override
  # snapshot, and `project_outbound`'s own long-lived connection are three separate
  # `open_store` calls, and each one REPLACES `Env.layer` (and with it the slot registry that
  # holds the active pointer). A one-shot activation survived only until the next open, so
  # `--slot admin` announced itself on stderr and then put no overlay on the wire at all.
  it "re-applies the selection every time open_store installs a fresh layer" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run.cr"))
    body = src[/private def self\.open_store.*?\n      end/m]
    lines = body.lines.reject(&.lstrip.starts_with?('#'))
    install = lines.index(&.includes?("Env.layer = Bindings.load"))
    reapply = lines.index(&.includes?("reapply_active_slot"))
    install.should_not be_nil
    reapply.should_not be_nil, "open_store stopped re-selecting --slot; the flag is a no-op again"
    reapply.not_nil!.should be > install.not_nil!
  end

  it "offers --slot on every command that sends" do
    root = File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run")
    {"fuzz", "mine", "sequence", "discover", "repeater"}.each do |cmd|
      File.read(File.join(root, "#{cmd}.cr")).should contain("--slot=NAME")
    end
  end
end
