module Gori::Proxy
  # An IO that replays a small `prefix` of already-read bytes before delegating
  # to the underlying IO. Used to "un-read" the bytes we peek to tell apart a TLS
  # ClientHello from an HTTP/2 cleartext preface after a CONNECT, so the chosen
  # handler (TLS MITM or h2c relay) still sees the complete byte stream (P7).
  class PrefixIO < IO
    def initialize(@prefix : Bytes, @inner : IO)
      @pos = 0
    end

    def read(slice : Bytes) : Int32
      if @pos < @prefix.size
        n = Math.min(slice.size, @prefix.size - @pos)
        @prefix[@pos, n].copy_to(slice[0, n])
        @pos += n
        return n
      end
      @inner.read(slice)
    end

    def write(slice : Bytes) : Nil
      @inner.write(slice)
    end

    def flush
      @inner.flush
    end

    def close
      @inner.close
    end
  end
end
