require "spec"
require "file_utils"

# Isolate the whole suite from the developer's real ~/.gori. Paths.home_dir falls
# back to ~/.gori unless GORI_HOME is set, and Settings is a process-wide singleton;
# without this, a spec that calls Settings.load / Paths.* would read and write the
# real home, and two parallel `crystal spec` runs (e.g. AI agents in sibling
# worktrees) could stomp each other. Set once, before src/gori is required, so any
# load-time path resolution already sees the temp home. Individual specs that still
# save/restore ENV["GORI_HOME"] per-example keep working (redundant but harmless).
GORI_TEST_HOME = File.tempname("gori-spec-home")
Dir.mkdir_p(GORI_TEST_HOME)
ENV["GORI_HOME"] = GORI_TEST_HOME

require "../src/gori"

# Several examples feed Settings a deliberately unparseable file. The warning that earns
# is real behaviour worth keeping, but on STDERR it lands mid-dots as a "settings: ... is
# not valid JSON" line that reads like a failure. Silence it globally; the examples that
# assert the line swap in an IO::Memory of their own.
Gori::Settings.warning_io = nil

Spec.after_suite { FileUtils.rm_rf(GORI_TEST_HOME) }

# The chord a SHIFTED letter actually produces, built the way the TUI builds it rather than
# spelled by hand. `Verb::Chord.new("X")` looks like ⇧X, satisfies an equality assertion
# perfectly, and never fires: `Keybind.from_event` normalises a typed capital to
# shift+lowercase, so nothing ever asks the keymap for a chord whose key is "X". Asserting a
# declaration against a hand-written twin of itself is what let a dead binding ship once
# already (see the note in spec/verbs/activity_spec.cr), so an assertion that the SHIFT is
# right wants the real event path — this is it.
#
# Not yet swept through the suite: the ⇧J/⇧K/⇧F/⇧E/⇧T assertions in the sitemap, diff, oast,
# sequencer, comparer and issues specs still build their chords by hand. Those are reorder and
# navigation verbs, where a dead binding is visible the first time anyone presses the key; the
# four clear-all verbs are the ones where it would not be. Prefer this helper in new specs.
def shift_chord(letter : Char) : Gori::Verb::Chord
  # `.not_nil!` rather than a fallback: from_event returns nil for an event it cannot name, and
  # a helper that quietly substituted a hand-built chord there would reintroduce exactly the
  # blind spot it exists to close.
  Gori::Tui::Keybind.from_event(
    Termisu::Event::Key.new(Termisu::Input::Key.from_char(letter.downcase),
      Termisu::Input::Modifier::Shift, char: letter.upcase)).not_nil!
end

# The scope decision for a spec that is exercising something OTHER than the scope gate
# (payload generation, host overrides, engine plumbing). `Gori::Outbound` is a required
# constructor argument on every active sender — that is the whole point of the seam — so
# specs need an explicit "no project, nothing to gate against" decision rather than a nil.
# Specs that DO exercise the gate build a real Outbound over a real Scope; see
# spec/outbound_spec.cr.
def ungated_outbound : Gori::Outbound
  Gori::Outbound.waived(nil, Gori::Outbound::Reason::NoProject)
end

# A throwaway on-disk Store for one example: opened on a fresh temp path, closed and
# deleted (with its WAL/SHM sidecars) on the way out, whether or not the block raised. This
# is the harness behind most store-backed examples in the tree; it used to be pasted into
# ~120 spec files. A file that needs something this shape cannot give (a Project alongside
# the store, an event channel, a retention knob, an Env layer restored on exit) keeps a
# file-private `with_store` of its own — a top-level `private def` shadows this one inside
# that file only, so the two never collide.
def with_store(&)
  path = File.tempname("gori-spec", ".db")
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

# The MCP tool facade over a store, built the way `gori mcp` builds it for a bound project:
# actions allowed, upstream verification off. `allow_actions: false` is the --read-only
# surface. Typed to a Store so a file that builds its Tools from a Project keeps its own.
def tools_for(store : Gori::Store, allow_actions = true, verify_upstream = false) : Gori::MCP::Tools
  Gori::MCP::Tools.new(store, allow_actions: allow_actions, verify_upstream: verify_upstream)
end

# Hand a fresh value to a new fiber. The origin loops in this tree are all
#
#     while conn = server.accept?
#       spawn_with(conn) do |conn|   # NOT `spawn do`
#
# because a `spawn do … conn … end` block captures the LOOP VARIABLE by reference, and the
# next `accept?` reassigns it before the fiber runs. Two clients dialling back to back then
# both get served on the second socket while the first is never read: the engine under
# test blocks on it until the GC finalises the orphaned socket, which is why one discover
# example cost 30 s inside the full suite and 1 s alone. AGENTS.md lists the same trap for
# `proxy/server.cr`. A method parameter is a fresh binding per call, so the block here
# closes over this call's value and nothing else.
def spawn_with(value : T, &block : T -> Nil) : Nil forall T
  spawn { block.call(value) }
end

# NEVER a bare `Channel#receive` in a spec driven by real sockets — use this instead.
#
# PR #555 hung CI for 24 minutes on exactly that. The suite was green on macOS; on Linux a
# client close was observed before the proxy had recorded its response, so nothing was ever
# sent on the channel and the receive blocked forever. `crystal spec` block-buffers its dots
# under Actions, so the hang left no output at all — not even how far it got.
#
# A timeout turns "it never arrived" into ONE failing example that says so, which is the
# difference between a five-second diagnosis and a rerun. The default is deliberately long:
# this is a deadlock guard, not a latency assertion, and a slow CI runner must not fail an
# example that would have passed. Pass `what` to name what was expected.
def receive_within(chan : Channel(T), seconds : Int32 = 20, what : String = "a value") : T forall T
  select
  when got = chan.receive
    got
  when timeout(seconds.seconds)
    raise "nothing arrived on the channel within #{seconds}s (expected #{what})"
  end
end
