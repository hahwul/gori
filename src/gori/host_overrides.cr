require "socket"
require "./store"

module Gori
  # A per-project /etc/hosts: maps a hostname to the IP the proxy should DIAL for it.
  # The override changes ONLY the TCP connect target — SNI, the certificate hostname,
  # the Host header, and the upstream-reuse pool key all keep the original hostname
  # (see Proxy::Upstream.dial). Owned by the TUI (the Project tab's HOST OVERRIDES
  # pane), persisted per project, and ALSO layered under a global set
  # (Settings.hostname_overrides) — the project layer wins on a host collision.
  #
  # Entries are read on the PROXY hot path (connect_ip) while the TUI fiber mutates
  # them (add/update/remove), so every cross-fiber access is Mutex-guarded — exactly
  # like Scope.
  class HostOverrides
    # One override. Immutable: rebuilt on every load/mutate (never edited in place).
    class Entry
      getter id : Int64
      getter host : String # lowercased
      getter ip : String

      def initialize(@id : Int64, @host : String, @ip : String)
      end
    end

    getter entries : Array(Entry)

    def initialize(@store : Store, @entries : Array(Entry))
      @mutex = Mutex.new
    end

    def self.load(store : Store) : HostOverrides
      new(store, load_entries(store))
    end

    protected def self.load_entries(store : Store) : Array(Entry)
      store.host_overrides.map { |(id, host, ip)| Entry.new(id, host, ip) }
    end

    # Entry count (chrome chip) — read on the TUI fiber, the only writer.
    def size : Int32
      @entries.size
    end

    # PROXY HOT PATH: the IP to dial for `host` (case-insensitive exact match), or nil
    # when no project override exists (the caller then falls back to the global set,
    # then to normal DNS). Mutex-guarded — the proxy reads while the TUI mutates.
    def connect_ip(host : String) : String?
      h = host.downcase
      @mutex.synchronize { @entries.find { |e| e.host == h }.try(&.ip) }
    end

    # Add an override (validates, lowercases the host, dedupes on host). Returns false
    # (no-op) on an empty/invalid pair or a host that's already mapped (edit it instead).
    def add(host : String, ip : String) : Bool
      host = host.strip.downcase
      ip = ip.strip
      return false unless HostOverrides.valid?(host, ip)
      @mutex.synchronize do
        return false if @entries.any? { |e| e.host == host }
        @store.add_host_override(host, ip)
        reload_entries_unlocked
      end
      true
    end

    # Edit an override in place (by id). Dedupes the host against OTHER entries so a
    # no-op self-edit (changing only the IP) is allowed. Returns false on empty/invalid/dup.
    def update(id : Int64, host : String, ip : String) : Bool
      host = host.strip.downcase
      ip = ip.strip
      return false unless HostOverrides.valid?(host, ip)
      @mutex.synchronize do
        return false if @entries.any? { |e| e.id != id && e.host == host }
        @store.update_host_override(id, host, ip)
        reload_entries_unlocked
      end
      true
    end

    def remove(id : Int64) : Nil
      @mutex.synchronize do
        @store.remove_host_override(id)
        reload_entries_unlocked
      end
    end

    # A valid override is a non-empty host plus an IP that parses as a real IPv4/IPv6
    # literal — rejecting a hostname-as-"IP" prevents a re-resolution loop (TCPSocket
    # would resolve it) and matches /etc/hosts, which only maps names to addresses.
    def self.valid?(host : String, ip : String) : Bool
      return false if host.strip.empty? || ip.strip.empty?
      Socket::IPAddress.new(ip.strip, 0)
      true
    rescue
      false
    end

    private def reload_entries_unlocked : Nil
      @entries = HostOverrides.load_entries(@store)
    end
  end
end
