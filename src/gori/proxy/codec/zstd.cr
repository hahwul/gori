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
          loop do
            outb = LibZstd::OutBuffer.new
            outb.dst = buf.to_unsafe.as(Void*)
            outb.size = LibC::SizeT.new(buf.size)
            outb.pos = LibC::SizeT.new(0)
            ret = LibZstd.decompress_stream(dctx, pointerof(outb), pointerof(inb))
            produced = outb.pos.to_i32
            out.write(buf[0, produced]) if produced > 0
            break if LibZstd.is_error(ret) != 0           # error → return partial
            break if ret == 0                             # frame complete
            break if out.bytesize >= max_out              # bomb guard
            break if produced == 0 && inb.pos >= inb.size # truncated / no progress
          end
          out.to_slice
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
