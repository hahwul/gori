module Gori::Oast
  # How many provider interactions a listener remembers for dedup. A webhook.site page is 50,
  # so a provider that replays its whole buffer on every poll stays well inside it.
  DEDUP_WINDOW = 2000

  # The interactions a listener has already announced, bounded to the NEWEST `cap` keys — the
  # dedup every surface's poll loop runs before it records or prints a callback. A plain Set
  # grew one uid per callback for as long as a listener lived (an MCP server, a
  # `gori run oast listen` left running overnight). The cost of the bound is an interaction
  # OLDER than the window that a provider re-announces: it is shown again, never filed again —
  # `oast_callbacks`' UNIQUE(session_id, provider_uid) + INSERT OR IGNORE stays the durable
  # backstop.
  class SeenWindow(K)
    def initialize(@cap : Int32 = DEDUP_WINDOW)
      @set = Set(K).new
      @order = Deque(K).new
    end

    # True the first time `key` is offered (it is remembered from then on); false for a key
    # already in the window. The oldest key leaves once the window is over `cap`.
    def add?(key : K) : Bool
      return false unless @set.add?(key)
      @order << key
      @set.delete(@order.shift) if @order.size > @cap
      true
    end

    def includes?(key : K) : Bool
      @set.includes?(key)
    end

    def size : Int32
      @set.size
    end

    def clear : Nil
      @set.clear
      @order.clear
    end
  end
end
