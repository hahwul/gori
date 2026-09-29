module Gori::Proxy
  # Reading a frame whose length the PEER declared, without trusting the declaration with
  # memory. An h2 frame header may claim 16 MiB and a WebSocket header 16 MiB (the relays' own
  # caps); allocating that on the header alone let a peer send ten bytes, stall, and hold 16 MiB
  # per connection — about 1 GB for 60 connections, and an OOM kill well inside the 2048
  # connection cap. The buffer now grows with the bytes that arrive, so a stalled frame holds at
  # most twice what it actually sent.
  module GrowRead
    # A frame this size or smaller is read into its final buffer at once, exactly as before:
    # 16 KiB is h2's default SETTINGS_MAX_FRAME_SIZE, so ordinary h2 traffic and nearly every
    # WebSocket frame never take the growing path on the fiber the proxy shares (P6).
    PRESIZE = 16 * 1024

    # A buffer of `prefix` followed by exactly `len` bytes read from `io`, the same contiguous
    # shape the callers forward verbatim. nil when `io` ends first.
    def self.read?(io : IO, prefix : Bytes, len : Int32) : Bytes?
      total = prefix.size + len
      buf = Bytes.new(len <= PRESIZE ? total : prefix.size + PRESIZE)
      prefix.copy_to(buf)
      filled = prefix.size
      while filled < total
        if filled == buf.size
          grown = Bytes.new({buf.size.to_i64 * 2, total.to_i64}.min.to_i32)
          buf.copy_to(grown)
          buf = grown
        end
        n = io.read(buf[filled, buf.size - filled])
        return nil if n == 0
        filled += n
      end
      buf
    end
  end
end
