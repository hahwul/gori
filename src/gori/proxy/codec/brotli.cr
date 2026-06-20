module Gori::Proxy::Codec
  # Brotli (`Content-Encoding: br`) decode for the DISPLAY view, via libbrotlidec
  # (the dominant CDN encoding; Crystal has no stdlib brotli). Linked by default;
  # build with `-Dwithout_native_codecs` on a machine lacking libbrotli/libzstd to
  # skip it (the decoder then reports "not built in" and the raw body is shown).
  module Brotli
    AVAILABLE = {{ !flag?(:without_native_codecs) }}

    # Decode a brotli stream, tolerant of truncation (a capture-capped body EOFs
    # mid-stream → returns what was produced). `max_out` caps output as a
    # decompression-bomb guard.
    def self.decode(input : Bytes, max_out : Int32) : Bytes
      {% if flag?(:without_native_codecs) %}
        raise Gori::Error.new("brotli decoder not built in")
      {% else %}
        state = LibBrotliDec.create_instance(Pointer(Void).null, Pointer(Void).null, Pointer(Void).null)
        raise Gori::Error.new("brotli: failed to create decoder") if state.null?
        begin
          out = IO::Memory.new
          buf = Bytes.new(64 * 1024)
          avail_in = LibC::SizeT.new(input.size)
          next_in = input.to_unsafe
          total = LibC::SizeT.new(0)
          loop do
            avail_out = LibC::SizeT.new(buf.size)
            next_out = buf.to_unsafe
            result = LibBrotliDec.decompress_stream(state,
              pointerof(avail_in), pointerof(next_in),
              pointerof(avail_out), pointerof(next_out), pointerof(total))
            produced = buf.size - avail_out.to_i32
            out.write(buf[0, produced]) if produced > 0
            # 0=ERROR 1=SUCCESS 2=NEEDS_MORE_INPUT(truncated) 3=NEEDS_MORE_OUTPUT
            break unless result == 3         # only NEEDS_MORE_OUTPUT continues
            break if produced == 0           # no progress → bail (defensive)
            break if out.bytesize >= max_out # bomb guard
          end
          out.to_slice
        ensure
          LibBrotliDec.destroy_instance(state)
        end
      {% end %}
    end
  end
end

{% unless flag?(:without_native_codecs) %}
  @[Link(pkg_config: "libbrotlidec")]
  lib LibBrotliDec
    fun create_instance = BrotliDecoderCreateInstance(alloc : Void*, free : Void*, opaque : Void*) : Void*
    fun destroy_instance = BrotliDecoderDestroyInstance(state : Void*) : Void
    fun decompress_stream = BrotliDecoderDecompressStream(
      state : Void*, available_in : LibC::SizeT*, next_in : UInt8**,
      available_out : LibC::SizeT*, next_out : UInt8**, total_out : LibC::SizeT*,
    ) : Int32
  end
{% end %}
