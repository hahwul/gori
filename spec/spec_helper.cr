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

# The chord a keypress ACTUALLY produces, built the way the TUI builds it: a Termisu key
# event run through `Keybind.from_event`, never a hand-spelled `Verb::Chord.new`.
#
# Why the detour matters: `Verb::Chord.new("X")` looks like ⇧X, satisfies an equality
# assertion against a declaration spelled the same way, and never fires — the event path
# normalises a typed capital to shift+lowercase, so nothing ever asks the keymap for a chord
# whose key is "X". Asserting a declaration against a hand-written twin of itself is what
# let a dead binding ship once (see the note in spec/verbs/activity_spec.cr). Every binding
# assertion in spec/verbs/ therefore goes through this helper: `typed_chord("f", shift: true)`
# is what pressing ⇧F yields, `typed_chord("X")` is what typing a capital X yields (the same
# chord), `typed_chord("enter")` a named key, `typed_chord("p", ctrl: true)` a control chord.
#
# Raises when the event maps to no chord at all — a helper that quietly substituted a
# hand-built chord there would reintroduce exactly the blind spot it exists to close.
def typed_chord(key : String, *, ctrl = false, alt = false, shift = false) : Gori::Verb::Chord
  mods = Termisu::Input::Modifier::None
  mods |= Termisu::Input::Modifier::Ctrl if ctrl
  mods |= Termisu::Input::Modifier::Alt if alt
  mods |= Termisu::Input::Modifier::Shift if shift
  Gori::Tui::Keybind.from_event(typed_key_event(key, mods, ctrl: ctrl, shift: shift)) ||
    raise("typed_chord: #{key.inspect} (ctrl=#{ctrl} alt=#{alt} shift=#{shift}) maps to no chord")
end

TYPED_NAMED_KEYS = {
  "enter" => Termisu::Input::Key::Enter, "escape" => Termisu::Input::Key::Escape,
  "tab" => Termisu::Input::Key::Tab, "up" => Termisu::Input::Key::Up,
  "down" => Termisu::Input::Key::Down, "left" => Termisu::Input::Key::Left,
  "right" => Termisu::Input::Key::Right, "backspace" => Termisu::Input::Key::Backspace,
  "space" => Termisu::Input::Key::Space,
}

# The Termisu event a terminal delivers for `key` under `mods` — the half of `typed_chord`
# that knows what real input looks like.
private def typed_key_event(key : String, mods : Termisu::Input::Modifier, *, ctrl : Bool, shift : Bool) : Termisu::Event::Key
  if key == "tab" && shift
    # Legacy terminals deliver ⇧Tab as its own key, which the event path maps to no chord:
    # a binding spelled shift+tab is dead, and typed_chord says so by raising.
    return Termisu::Event::Key.new(Termisu::Input::Key::BackTab, mods, nil)
  end
  if named = TYPED_NAMED_KEYS[key]?
    return Termisu::Event::Key.new(named, mods, nil)
  end
  raise "typed_chord: #{key.inspect} is neither a named key nor one character" unless key.size == 1
  c = key[0]
  # Shift on a letter is a real event; shift on a symbol or digit is not — the terminal
  # sends the shifted CHARACTER ('?' for ⇧/, '!' for ⇧1) with no modifier, so a chord
  # spelled that way can never be pressed. Refuse rather than certify it.
  if shift && !c.ascii_letter?
    raise "typed_chord: shift+#{key.inspect} is not an event a terminal sends; spell the shifted character itself"
  end
  # A shifted letter arrives as the lowercase key with Shift and the uppercase char (the
  # shape `Keybind.from_event` documents); a typed capital arrives as the capital itself
  # with no modifier. Ctrl+letter carries no char, matching the parser branch.
  char = ctrl ? nil : (shift ? c.upcase : c)
  Termisu::Event::Key.new(Termisu::Input::Key.from_char(c.downcase), mods, char)
end

# `typed_chord(letter, shift: true)` for the ⇧-letter case, kept under its older name.
def shift_chord(letter : Char) : Gori::Verb::Chord
  typed_chord(letter.downcase.to_s, shift: true)
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

# `with_store` for an example that writes the project env or bindings layer: the
# process-global `Settings.project_env_vars` and `Env.layer` are put back on the way out
# and the highlight revision bumped, so a `$KEY` an example set cannot leak into the next
# file's expansions. Used to be pasted into six spec/mcp files.
def with_store_env(&)
  path = File.tempname("gori-spec", ".db")
  store = Gori::Store.open(path)
  prev_env = Gori::Settings.project_env_vars
  prev_layer = Gori::Env.layer
  begin
    yield store
  ensure
    Gori::Env.layer = prev_layer
    Gori::Settings.project_env_vars = prev_env
    Gori::Env.bump_highlight_rev
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

# Hand a fresh value to a new fiber. An origin loop in this tree passes the accepted
# socket to its fiber one of two ways, and never through a block that names the loop
# variable:
#
#     while accepted = server.accept?
#       spawn_with(accepted) do |conn|   # a body of its own
#     — or —
#       spawn serve(accepted)            # a call: `spawn` evaluates the ARGUMENTS first
#
# because a `spawn do … conn … end` (or `spawn { … conn … }`) block captures the LOOP
# VARIABLE by reference, and the next `accept?` reassigns it before the fiber runs. Two clients dialling back to back then
# both get served on the second socket while the first is never read: the engine under
# test blocks on it until the GC finalises the orphaned socket, which is why one discover
# example cost 30 s inside the full suite and 1 s alone. AGENTS.md lists the same trap for
# `proxy/server.cr`. A method parameter is a fresh binding per call, so the block here
# closes over this call's value and nothing else.
def spawn_with(value : T, &block : T -> Nil) : Nil forall T
  spawn { block.call(value) }
end

# Run the block with the ROOT logger writing into a `Log::MemoryBackend`, and hand the
# backend over so the example can read `entries`. The previous backend and level come back
# on the way out, whether or not the block raised, so a spec asserting on gori.log lines
# cannot leave the suite logging into memory. Reach for this rather than grepping the source
# for a `Log.info` call: what the operator gets is the line, not the call site.
def capturing_log(&)
  root = ::Log.for("")
  prev_backend = root.backend
  prev_level = root.level
  mem = ::Log::MemoryBackend.new
  ::Log.setup(:info, mem)
  # A nested begin, so the restore sees the captured values as the compiler knows them: a
  # variable assigned inside a method-level body is nilable in that method's `ensure`.
  begin
    yield mem
  ensure
    if prev_backend
      ::Log.setup(prev_level, prev_backend)
    else
      ::Log.setup(:none)
    end
  end
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
