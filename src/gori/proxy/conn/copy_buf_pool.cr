require "../codec/body"

module Gori::Proxy
  # The 64 KiB scratch buffers `ClientConn` copies bodies through, LENT for one `Body.stream`
  # call instead of owned by a connection for its whole life.
  #
  # A connection used to keep its buffer from the first body to the last byte of keep-alive, so
  # every idle connection a browser parks pinned 64 KiB: at MAX_CONNECTIONS that is ~130 MB for
  # sockets doing nothing. A buffer is only in use while a body is being pumped, and far fewer
  # connections are doing that at once than are merely open.
  #
  # Safe because a lent buffer never crosses a fiber: `Body.stream` reads into it and writes the
  # same slice onward (to a socket, a CaptureBuffer, an IO::Memory — each copies before
  # returning) on the borrowing fiber, and the buffer comes back in `ensure` only once the call
  # has fully unwound. Nothing else keeps a reference to it. Single-threaded scheduler, so the
  # free list needs no lock (no -Dpreview_mt).
  module CopyBufPool
    SIZE = Codec::Body::BUFSIZE
    # Idle buffers kept for the next borrower (4 MiB at most). Past it a returned buffer is left
    # to the GC; a burst of more concurrent bodies than this allocates, as every body once did.
    MAX_IDLE = 64

    @@idle = [] of Bytes
    @@lent = 0

    # Yields a SIZE-byte buffer for the duration of the block, then takes it back. The block must
    # not let the buffer (or a slice of it) escape.
    def self.lend(& : Bytes -> T) : T forall T
      buf = @@idle.pop? || Bytes.new(SIZE)
      @@lent += 1
      begin
        yield buf
      ensure
        @@lent -= 1
        @@idle << buf if @@idle.size < MAX_IDLE
      end
    end

    # Buffers waiting to be lent. For specs and benches.
    def self.idle_count : Int32
      @@idle.size
    end
  end
end
