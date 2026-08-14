require "socket"
require "./dial_address"
require "./store"

module Gori
  # A per-project /etc/hosts: maps a hostname to the address the proxy should DIAL for it.
  # The override changes ONLY the TCP connect target — SNI, the certificate hostname,
  # the Host header, and the upstream-reuse pool key all keep the original hostname
  # (see Proxy::Upstream.dial). Owned by the TUI (the Project tab's HOST OVERRIDES
  # pane), persisted per project, and ALSO layered under a global set
  # (Settings.hostname_overrides) — the project layer wins on a host collision.
  #
  # The value is `IP` or `IP:PORT` (see `Gori::DialAddress`): a bare IP keeps the request's
  # own port, which is what every entry written before ports existed says.
  #
  # Entries are read on the PROXY hot path (connect_address) while the TUI fiber mutates
  # them (add/update/remove), so every cross-fiber access is Mutex-guarded — exactly
  # like Scope. TWO mutexes, though, and the split matters: see the constructor.
  class HostOverrides
    # One override. Immutable: rebuilt on every load/mutate (never edited in place).
    #
    # `ip` is the column name and the historical spelling; it holds a dial ADDRESS, which may
    # carry a port. Kept as `ip` rather than renamed because the persisted column is `ip` and
    # this round must not touch the schema — `address` is the accessor that says what it is.
    class Entry
      getter id : Int64
      getter host : String # `OverrideHost.key` form: lowercased, no trailing root dot
      getter ip : String

      def initialize(@id : Int64, @host : String, @ip : String)
      end

      # The stored value as gori dials it.
      def address : String
        @ip
      end
    end

    getter entries : Array(Entry)

    def initialize(@store : Store, @entries : Array(Entry))
      # Guards `@entries` ONLY, and every critical section it has is a pointer read or a
      # pointer swap. The store round-trip that used to sit inside it does not: `exec_task`
      # parks the calling fiber on its reply channel, and with `busy_timeout=5000` a PEER
      # process holding the write lock parks it for up to five seconds. `connect_address`
      # takes this same mutex on every proxied request, so holding it across that write
      # stalled every dial in a project that has any override at all, for as long as the
      # peer held the lock. The writers below serialise against each other on @write_mutex
      # instead, which the read path never touches.
      @mutex = Mutex.new
      # Serialises writers THROUGH THIS INSTANCE — the session's live object, which the TUI
      # holds and the proxy dials from. It is deliberately not claimed as more than that: the
      # MCP tools and the CLI each `HostOverrides.load` an instance of their own per call, so
      # they carry their own lock and never contend with this one. They are answered the same
      # way a peer PROCESS is, which is the case that has to work anyway: `INSERT OR IGNORE`
      # plus the post-write reload verify below. The residue is that two writers racing the
      # same host make the loser's verify fail, and MCP reports that deterministic duplicate
      # as retryable — narrow enough to leave, but it is a race, not an atomicity guarantee.
      @write_mutex = Mutex.new
    end

    def self.load(store : Store) : HostOverrides
      new(store, load_entries(store))
    end

    # Folded on READ, not just on write, because the `Entry#host` invariant has to hold for
    # rows that predate it. Every writer now stores `OverrideHost.key`, but a row written
    # before this — "legacy.test." — would otherwise sit in the list in a form no lookup can
    # produce: dead for both spellings of the request, AND invisible to `add`'s dedupe, so
    # adding "legacy.test" would succeed and leave two rows for one host, one of them dead.
    #
    # A migration would rewrite the column instead, and is not worth it: `host` is UNIQUE, so
    # a db holding BOTH "x." and "x" cannot be folded in place without picking one to drop —
    # a decision an UPDATE has no business making on an operator's routing table. Folding here
    # leaves both rows visible in the pane; the first by id answers `connect_address`, and
    # editing either one rewrites it to the key form for good.
    protected def self.load_entries(store : Store) : Array(Entry)
      store.host_overrides.map { |(id, host, ip)| Entry.new(id, OverrideHost.key(host), ip) }
    end

    # Entry count (chrome chip) — read on the TUI fiber, the only writer.
    def size : Int32
      @entries.size
    end

    # PROXY HOT PATH: the address to dial for `host` (exact match on the `OverrideHost.key`
    # form, so case and a trailing root dot don't decide it), or nil when no project override
    # exists (the caller then falls back to the global set, then to normal DNS). May carry a
    # port — see `Gori::DialAddress`. Mutex-guarded: the proxy reads while the TUI mutates.
    def connect_address(host : String) : String?
      return nil if @entries.empty? # fast path (the universal case): no overrides → skip the key + lock
      h = OverrideHost.key(host)
      @mutex.synchronize { @entries }.find { |e| e.host == h }.try(&.ip)
    end

    # Add an override (validates, folds the host to its `OverrideHost.key`, dedupes on it).
    # Returns false
    # (no-op) on an empty/invalid pair, a host that's already mapped (edit it instead) — or a
    # store write that did not commit.
    #
    # That last case used to return TRUE: unlike update/remove (exec_task_ok) the INSERT goes
    # through exec_task, which reports nothing, so a busy/locked/closing store rolled the batch
    # back and `add` still said yes — the caller then reported an override the proxy would
    # never dial. The `INSERT OR IGNORE` behind it can also drop the row when a PEER process
    # created the same host since this object last loaded, which the in-memory dedupe above
    # cannot see. The reload right below already fetches the truth: present with THIS address
    # ⇒ stored. (Address, not just host — a peer's colliding row must not be read as our write.)
    def add(host : String, ip : String) : Bool
      host = OverrideHost.key(host)
      ip = ip.strip
      return false unless HostOverrides.valid?(host, ip)
      @write_mutex.synchronize do
        return false if snapshot.any? { |e| e.host == host }
        @store.add_host_override(host, ip)
        reload
        snapshot.any? { |e| e.host == host && e.ip == ip }
      end
    end

    # Edit an override in place (by id). Dedupes the host against OTHER entries so a
    # no-op self-edit (changing only the IP) is allowed. Returns false on empty/invalid/dup.
    def update(id : Int64, host : String, ip : String) : Bool
      host = OverrideHost.key(host)
      ip = ip.strip
      return false unless HostOverrides.valid?(host, ip)
      @write_mutex.synchronize do
        return false if snapshot.any? { |e| e.id != id && e.host == host }
        committed = @store.update_host_override(id, host, ip)
        reload
        committed # false also when the store write rolled back (busy/locked), not just on dup
      end
    end

    # Returns whether the delete committed (false = store busy/locked/closing).
    def remove(id : Int64) : Bool
      @write_mutex.synchronize do
        committed = @store.remove_host_override(id)
        reload
        committed
      end
    end

    # Permitted hostname shape: letters/digits/dot/hyphen/underscore, no spaces. Rejects
    # garbage like "foo bar" that could never match a real request host (a silent dead
    # override) without being so strict it blocks ordinary names.
    #
    # The first character may not be a DOT, which is the one shape an operator types on
    # purpose and gets nothing from: `.api.test` is how a cookie domain is written, and
    # pasting one here validated, stored and rendered in the pane while no request Host could
    # ever equal it. A TRAILING dot is a different question and is answered before this — see
    # `OverrideHost.key`, which folds it away rather than refusing it. Leading `_` and `-` are
    # still allowed: neither starts a name a resolver would accept either, but both appear in
    # real internal setups and refusing them here would block a host gori can genuinely be
    # asked about, which is a worse trade than the dot.
    HOST_RE = /\A[a-zA-Z0-9_-][a-zA-Z0-9._-]*\z/

    # A valid override is a hostname-shaped host plus an address that parses as a real
    # IPv4/IPv6 literal, optionally with a port — rejecting a hostname-as-"IP" prevents a
    # re-resolution loop (TCPSocket would resolve it) and matches /etc/hosts, which only maps
    # names to addresses. The port is the one thing this goes BEYOND /etc/hosts on, and
    # deliberately: /etc/hosts is consulted by a resolver that has no port to change, whereas
    # gori is the thing making the connection.
    def self.valid?(host : String, ip : String) : Bool
      # Asked of the KEY, not the raw text, so a caller that validates before storing and the
      # store itself judge the same string. It also makes ".", "example.com." and
      # "EXAMPLE.com" answer the way the lookup will treat them rather than the way they were
      # typed — the whole point of HOST_RE being here is to refuse a silent dead override.
      host = OverrideHost.key(host)
      return false if host.empty?
      return false unless host.matches?(HOST_RE)
      DialAddress.valid?(ip)
    end

    # Parse a single-line "ADDRESS host" entry (/etc/hosts order — address first) into
    # {host (`OverrideHost.key` form), address}, or nil when it isn't a valid address +
    # hostname pair. ONE place so the Project pane (ov_commit) and the global settings editor
    # (HostsOverlay#commit) parse and validate identically.
    def self.parse_line(text : String) : {String, String}?
      parts = text.strip.split(/\s+/, 2)
      return nil if parts.size < 2
      ip = parts[0]
      host = parts[1].strip
      return nil unless valid?(host, ip)
      {OverrideHost.key(host), ip}
    end

    # Re-read the entries from the store after an EXTERNAL change — another process
    # (`gori run project host-override add/rm`, an MCP `add_host_override`) or another
    # instance's TUI writing to the SAME db. Mirrors Scope#reload / Rules#reload, and for
    # the same reason: every consumer already holds a reference to THIS object (the proxy's
    # `Upstream.connect_target` via each listener, the Project tab's HOST OVERRIDES pane),
    # so refreshing it in place is enough — no re-wiring needed.
    #
    # Without it a running gori kept dialing the OLD address for the rest of the session
    # while the writing surface reported success, and the TUI pane deduped its own adds
    # against a stale list — `INSERT OR IGNORE` then dropped the write (host is UNIQUE) and
    # the reload surfaced the OTHER process's value under an "override added" toast.
    #
    # Pulled by the same two call sites Scope#reload has: the TUI's data_version poll
    # (Runner#apply_external_change) and headless capture's reload fiber (App#spawn_reload_loop).
    def reload : Nil
      # The SELECT runs outside @mutex — see the constructor. Only the swap is guarded, and
      # the array is rebuilt rather than edited in place, so a concurrent `connect_address`
      # reads either the whole old list or the whole new one.
      fresh = HostOverrides.load_entries(@store)
      @mutex.synchronize { @entries = fresh }
    end

    # The current list, read under @mutex — what a writer compares against and what
    # `connect_address` searches.
    private def snapshot : Array(Entry)
      @mutex.synchronize { @entries }
    end
  end
end
