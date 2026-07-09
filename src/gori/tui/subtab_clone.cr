module Gori::Tui
  # Shared helpers for the sub-tab strip "Duplicate" action (Replay / Fuzzer /
  # Notes / Convert / Miner). Content-only clones — no entity links or source flow.
  module SubtabClone
    # Custom chip name for a clone: append " copy" once (idempotent if already present).
    # Blank / nil names stay auto-derived from content.
    def self.copy_name(name : String?) : String?
      return nil unless n = name
      t = n.strip
      return nil if t.empty?
      t.ends_with?(" copy") ? t : "#{t} copy"
    end
  end
end
