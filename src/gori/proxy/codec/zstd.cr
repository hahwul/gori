module Gori::Proxy::Codec
  # Zstandard (`Content-Encoding: zstd`) decode for the DISPLAY view, via libzstd
  # (Chrome/CDNs increasingly use it; no stdlib support). Linked by default;
  # `-Dwithout_native_codecs` skips it (then the raw body is shown with a note).
  module Zstd
    AVAILABLE = {{ !flag?(:without_native_codecs) }}

    # ZSTD_dParameter::ZSTD_d_windowLogMax — bumped generously so large-window
    # HTTP streams decode instead of erroring.
    WINDOW_LOG_MAX = 100

    # Decode a zstd stream, tolerant of truncation. `max_out` caps output (bomb guard).
    def self.decode(input : Bytes, max_out : Int32) : Bytes
      decode_full(input, max_out)[0]
    end

    # :ditto: — plus whether the stream ENDED cleanly: every frame in it completed and every
    # input byte was consumed.
    #
    # The flag exists because "empty output" is not an error signal here and cannot be made
    # into one. libzstd answers a corrupt frame the same way it answers a frame that really
    # decodes to nothing: no bytes, no raise. A caller that has to tell a body apart from a
    # buffer that was never zstd (the Decoder workbench does; the display path does not) needs
    # the reader to say so, and guessing from the output length gets a legal empty frame wrong
    # in one direction and a corrupt one wrong in the other.
    def self.decode_full(input : Bytes, max_out : Int32) : {Bytes, Bool}
      {% if flag?(:without_native_codecs) %}
        raise Gori::Error.new("zstd decoder not built in")
      {% else %}
        dctx = LibZstd.create_dctx
        raise Gori::Error.new("zstd: failed to create dctx") if dctx.null?
        begin
          LibZstd.dctx_set_parameter(dctx, WINDOW_LOG_MAX, 31)
          out = IO::Memory.new
          buf = Bytes.new(128 * 1024)
          inb = LibZstd::InBuffer.new
          inb.src = input.to_unsafe.as(Void*)
          inb.size = LibC::SizeT.new(input.size)
          inb.pos = LibC::SizeT.new(0)
          clean = false
          loop do
            outb = LibZstd::OutBuffer.new
            outb.dst = buf.to_unsafe.as(Void*)
            outb.size = LibC::SizeT.new(buf.size)
            outb.pos = LibC::SizeT.new(0)
            ret = LibZstd.decompress_stream(dctx, pointerof(outb), pointerof(inb))
            produced = outb.pos.to_i32
            out.write(buf[0, produced]) if produced > 0
            break if LibZstd.is_error(ret) != 0 # error → return partial
            # THE BOMB GUARD FIRST, above the frame-boundary branch. `ZSTD_decompressStream`
            # returns 0 at the end of EVERY frame, so a stream of back-to-back frames takes the
            # `next` below on every iteration — and a guard underneath it is never consulted at
            # all. Measured on 20_000 copies of one 25-byte frame (25 KB of input, a legal
            # `Content-Encoding: zstd` body): 131 MB produced against a 32 MiB cap, scaling
            # linearly with input, on the path an operator reaches by opening the flow.
            #
            # PAST the ceiling, not AT it: 32 MiB divides by this 128 KiB buffer exactly, so a
            # `>=` stop landed a bomb on precisely `max_out` and cleared every consumer's
            # `size > max_out` guard (`Chain.run`'s, `ExternalOpen`'s) — the cut output was
            # reported as a finished decode. One byte over is what proves the stream had more
            # to give; a stream that decodes to exactly `max_out` still ends cleanly below.
            # Same rule as `Decoder::Codecs#drain` and `Brotli.decode_full`.
            break if out.bytesize > max_out
            if ret == 0
              # A frame ended — but a zstd STREAM may be several frames back to back, and a
              # `Content-Encoding: zstd` body legitimately is one. Stopping at the first
              # returned the first frame and dropped the rest, with nothing saying so: two
              # concatenated 2 MB frames decoded to exactly half the body.
              if inb.pos >= inb.size
                clean = true
                break
              end
              next
            end
            break if produced == 0 && inb.pos >= inb.size # truncated / no progress
          end
          {out.to_slice, clean}
        ensure
          LibZstd.free_dctx(dctx)
        end
      {% end %}
    end
  end
end

{% unless flag?(:without_native_codecs) %}
  @[Link(pkg_config: "libzstd")]
  lib LibZstd
    struct InBuffer
      src : Void*
      size : LibC::SizeT
      pos : LibC::SizeT
    end

    struct OutBuffer
      dst : Void*
      size : LibC::SizeT
      pos : LibC::SizeT
    end

    fun create_dctx = ZSTD_createDCtx : Void*
    fun free_dctx = ZSTD_freeDCtx(dctx : Void*) : LibC::SizeT
    fun dctx_set_parameter = ZSTD_DCtx_setParameter(dctx : Void*, param : Int32, value : Int32) : LibC::SizeT
    fun decompress_stream = ZSTD_decompressStream(dctx : Void*, output : OutBuffer*, input : InBuffer*) : LibC::SizeT
    fun is_error = ZSTD_isError(code : LibC::SizeT) : UInt32
  end
{% end %}
