require "./env"
require "./session_slot"
require "./store"

module Gori
  # The project's session slots, plus WHICH ONE is active.
  #
  # A slot is a named send context: a header overlay plus a namespace for the values
  # `Bindings` observes (see `SessionSlot`). This class owns the persisted list — one settings
  # row, the same one the Authorize tab has always written — and the ACTIVE pointer, which is
  # the only piece of session state a send seam has to consult.
  #
  # ## Why the active slot is in memory and the list is on disk
  #
  # The list is configuration: header names, header values an operator typed, and which
  # extract rules belong to which identity. Configuration persists, exactly as `env.vars` and
  # the Rewriter's rules do.
  #
  # The active pointer does NOT, and it is the same argument `Bindings` makes about a value:
  # a slot with nothing bound in it is a slot that resolves nothing, and every binding table
  # is empty at process start by design. Restoring "admin is active" into an empty admin
  # table would hand the next send an overlay whose `$SESSION` is literal — a 401 the operator
  # did not ask for and cannot see the cause of. Activation is one keystroke and one line of
  # `gori run`; a stale one is a support ticket.
  #
  # ## What is NOT here
  #
  # No cookie jar. A slot carries the headers the operator wrote and the bindings gori
  # observed; it does not parse `Set-Cookie`, keep a path/domain tree, or expire anything.
  # RFC 6265 storage is a separate feature with its own failure modes, and the case operators
  # actually ask for — "send these headers as this identity" — is this one.
  #
  # No auto-login. `--bind-from` already replays ONE named flow to fill a binding table, and
  # that is a flow the operator pointed at. A macro that decides for itself when to
  # re-authenticate is gori acting behind the operator's back (P4).
  class SessionSlots
    # The settings key. Deliberately the SAME row Authorize identities have always used:
    # identities are slots, so an existing project's identities ARE its slots and a new key
    # would silently orphan every one of them on upgrade.
    KEY = Store::SESSION_SLOTS_KEY

    def initialize(@store : Store, slots : Array(SessionSlot))
      @mutex = Mutex.new
      @slots = slots
      @active = nil.as(String?)
      @rev = 0_u64
      # Lock-free fast path for the send seams: with no slot claiming a rule, `Bindings`
      # skips every namespacing test and behaves exactly as it did before slots existed.
      # Same pattern and the same reason as `Bindings`' own `@enabled_count`.
      @scoped_count = Atomic(Int32).new(count_scoped(slots))
    end

    def self.load(store : Store) : SessionSlots
      new(store, SessionSlot.parse_json(store.setting(KEY)))
    end

    def slots : Array(SessionSlot)
      @mutex.synchronize { @slots.dup }
    end

    def find(name : String) : SessionSlot?
      @mutex.synchronize { @slots.find(&.name.==(name)) }
    end

    # Bumped on every list edit and every activation. `Bindings` folds this into its own `rev`
    # so a consumer caching a merged snapshot (`Rules`, on the proxy hot path) repaints when
    # the send context changes and not only when a value does.
    def rev : UInt64
      @rev
    end

    # Replace the whole list. Returns false when the write did NOT commit (store busy, locked
    # or closing) — `Bindings#remove`'s contract, for the same reason: a surface that reports
    # having saved a slot the operator will not find after a restart is worse than one that
    # says the project was busy.
    #
    # The ACTIVE pointer follows the list: a slot that is no longer there cannot be the send
    # context, and leaving a dangling name would make `overlay` a silent no-op that the
    # readout still reports as active.
    def save(list : Array(SessionSlot)) : Bool
      return false unless @store.set_setting(KEY, SessionSlot.serialize(list))
      @mutex.synchronize do
        @slots = list
        @active = nil unless (a = @active) && list.any?(&.name.==(a))
        @rev &+= 1
      end
      @scoped_count.set(count_scoped(list))
      Env.bump_highlight_rev
      true
    end

    # Re-read the persisted list (an MCP / other-instance edit), keeping the active pointer
    # when the slot it names survived. Same shape as `Bindings#reload`.
    def reload : Nil
      fresh = SessionSlot.parse_json(@store.setting(KEY))
      @mutex.synchronize do
        @slots = fresh
        @active = nil unless (a = @active) && fresh.any?(&.name.==(a))
        @rev &+= 1
      end
      @scoped_count.set(count_scoped(fresh))
      Env.bump_highlight_rev
    end

    # ── list edits ────────────────────────────────────────────────────────────
    #
    # `save` takes a whole list, which is what the TUI's identities card hands it (the card
    # holds the array and edits it in place). A surface that names ONE slot — `gori run
    # session add`, MCP `create_session_slot` — would otherwise each rebuild the list and each
    # re-decide what "exactly one baseline" means, and three copies of that rule is how the
    # Authorize tab and a headless run come to disagree about which slot a run is judged
    # against. So the rule lives here, once.
    #
    # All four return `save`'s answer: false means the project was NOT written. They do NOT
    # answer "no such slot" / "that name is taken" — a caller that needs to tell those apart
    # from a busy store asks `find` first, the same split `HostOverrides` makes for the same
    # reason (a deterministic refusal reported as retryable makes an agent loop).

    # Append a slot. The caller has already established the name is free.
    def add(slot : SessionSlot) : Bool
      save(with_one_baseline(slots << slot, slot.baseline? ? slot.name : nil))
    end

    # Replace the slot named `name`, IN PLACE — the list order is the order the Authorize tab
    # replays in, so an edit must not move a row. A rename is an ordinary update: `replacement`
    # carries the new name and the caller has checked it is free.
    def update(name : String, replacement : SessionSlot) : Bool
      list = slots
      idx = list.index(&.name.==(name))
      return false unless idx
      list[idx] = replacement
      # An update that TOOK the baseline clears it everywhere else; one that dropped it leaves
      # the list without an anchor, so the first row inherits it (the card's own delete rule).
      save(with_one_baseline(list, replacement.baseline? ? replacement.name : nil))
    end

    # Drop the slot named `name`. Unlike the TUI card this does NOT refuse the last one: an
    # Authorize run needs two, but a project with zero slots is exactly the pre-slot project
    # every playbook assumes, and a CLI that cannot undo its own `add` is worse.
    def remove(name : String) : Bool
      list = slots
      before = list.size
      list.reject!(&.name.==(name))
      return false if list.size == before
      save(with_one_baseline(list, nil))
    end

    # Move the baseline — the flag every other slot is judged against. Separate from `update`
    # because it is the one edit that changes TWO rows.
    def set_baseline(name : String) : Bool
      return false unless find(name)
      save(with_one_baseline(slots, name))
    end

    # Exactly one baseline, enforced by construction rather than by every caller remembering
    # to clear the old one. `winner` names the slot that must hold it; nil keeps whichever
    # slot already does, and promotes the first row when an edit left none (a set judged
    # against no baseline is a run with no verdict).
    private def with_one_baseline(list : Array(SessionSlot), winner : String?) : Array(SessionSlot)
      return list if list.empty?
      pick = winner || list.find(&.baseline?).try(&.name) || list[0].name
      list.map { |s| s.baseline? == (s.name == pick) ? s : s.with_baseline(s.name == pick) }
    end

    # ── the active slot ───────────────────────────────────────────────────────

    # The send context, or nil for "as captured" — no overlay, global bindings only. nil is
    # the DEFAULT and the baseline: with no slot active nothing here changes a byte, which is
    # what makes every playbook written before slots existed keep working.
    def active : SessionSlot?
      @mutex.synchronize { (a = @active) ? @slots.find(&.name.==(a)) : nil }
    end

    def active_name : String?
      @mutex.synchronize { @active }
    end

    # Select the send context. `nil` deactivates (back to as-captured). False when there is no
    # such slot — the caller reports it; silently leaving the previous slot active would make
    # a typo'd name send the wrong identity's credential.
    #
    # An as-captured slot (`passthrough?` with no rules) may be selected by name like any
    # other: it is the explicit way to say "this request's own session", and it reads better
    # in a readout than an empty pointer.
    def activate(name : String?) : Bool
      @mutex.synchronize do
        if name.nil?
          @active = nil
        else
          return false unless @slots.any?(&.name.==(name))
          @active = name
        end
        @rev &+= 1
      end
      Env.bump_highlight_rev
      true
    end

    # ── what `Bindings` asks ──────────────────────────────────────────────────

    # Is ANY slot claiming ANY extract rule? Read per response on the proxy path, so it is
    # lock-free: a project whose slots are pure header overlays (every Authorize identity ever
    # written before this change) pays nothing for the namespacing tests.
    def scoped? : Bool
      @scoped_count.get > 0
    end

    # Every rule name ANY slot claims. Taken as a whole SET rather than asked per rule,
    # because the caller (`Bindings#candidates`) is inside its own mutex on the proxy response
    # path: one snapshot outside both locks beats N calls that each take this one, and it
    # keeps the two mutexes from ever nesting. Guarded by `scoped?` so the common project —
    # no slot claims anything — never allocates it.
    def claimed_names : Set(String)
      @mutex.synchronize do
        set = Set(String).new
        @slots.each { |slot| slot.rules.each { |name| set << name } }
        set
      end
    end

    # Every slot name that could hold a binding table, for the masking half of `Bindings`.
    def names : Array(String)
      @mutex.synchronize { @slots.map(&.name) }
    end

    # ── the overlay ───────────────────────────────────────────────────────────

    # The active slot's header overlay, applied to final wire bytes at a send seam. Returns
    # the same slice when there is nothing to do — the common case, and byte-fidelity (P7)
    # besides.
    #
    # `resolve` expands a `$NAME` the operator wrote into a slot header VALUE, against
    # whatever the caller resolves against (`Bindings` hands it `Env.expand_bindings` with the
    # boundary guard ON, because a resolved value is the ORIGIN'S bytes and a CR/LF in a
    # header forges a message boundary — see `Bindings.boundary_forging?`). Header NAMES are
    # never scanned.
    #
    # HEADER-ONLY, always: `SessionSlot.overlay_wire` splits the message and touches header
    # lines alone, so the body is byte-exact and Content-Length cannot move. That invariant is
    # what lets this run on bytes the operator did not author — a captured replay, a fuzz
    # template, an intercepted request — without reframing them.
    def overlay(wire : Bytes, & : String -> String) : Bytes
      slot = active
      return wire unless slot
      return wire if slot.passthrough?
      resolved = slot.resolve_values { |v| yield v }
      SessionSlot.overlay_wire(wire, resolved)
    end

    private def count_scoped(list : Array(SessionSlot)) : Int32
      list.sum(&.rules.size)
    end
  end
end
