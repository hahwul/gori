require "compress/zlib"
require "digest/crc32"

# A minimal PNG DECODER, for `spec/screenshot/png_spec.cr`.
#
# It exists because nothing else can prove the writer. Asserting on the writer's own byte
# output would only restate the writer; shelling out to `file`, `sips` or ImageMagick would
# make the suite depend on the host. So the spec reads the PNG back the way any other decoder
# would — signature, chunk walk with the CRCs verified, zlib inflate, unfilter — and asks
# about pixels.
#
# Deliberately narrow: 8-bit depth, colour types 3 (indexed) and 2 (truecolor), no
# interlacing — exactly what `Screenshot::Png` can emit. Anything else raises, which is itself
# the assertion that the writer stayed inside that envelope.
module PngReader
  SIGNATURE = Bytes[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

  INDEXED   = 3
  TRUECOLOR = 2

  class Error < Exception
  end

  class Image
    getter width : Int32
    getter height : Int32
    getter depth : Int32
    getter color_type : Int32

    # Chunk type names in the order they appeared — the spec asserts IHDR/PLTE/tRNS/IDAT/IEND
    # and, just as importantly, that nothing ancillary crept in.
    getter chunks : Array(String)
    getter palette : Array({UInt8, UInt8, UInt8})
    getter transparency : Bytes

    # Unfiltered scanlines, `height * width * bytes_per_pixel` long.
    getter raw : Bytes

    def initialize(@width, @height, @depth, @color_type, @chunks, @palette, @transparency, @raw)
    end

    def bytes_per_pixel : Int32
      @color_type == INDEXED ? 1 : 3
    end

    def indexed? : Bool
      @color_type == INDEXED
    end

    def index_at(x : Int32, y : Int32) : UInt8
      raise Error.new("not an indexed PNG") unless indexed?
      @raw[y * @width + x]
    end

    def pixel(x : Int32, y : Int32) : {UInt8, UInt8, UInt8}
      check_bounds(x, y)
      return @palette[index_at(x, y).to_i] if indexed?
      at = (y * @width + x) * 3
      {@raw[at], @raw[at + 1], @raw[at + 2]}
    end

    # 0 or 255: `Screenshot::Png` only ever writes a tRNS prefix over an indexed palette, and
    # truecolor has no alpha channel at all.
    def alpha(x : Int32, y : Int32) : UInt8
      check_bounds(x, y)
      return 255_u8 unless indexed?
      index = index_at(x, y).to_i
      index < @transparency.size ? @transparency[index] : 255_u8
    end

    private def check_bounds(x : Int32, y : Int32) : Nil
      return if 0 <= x < @width && 0 <= y < @height
      raise Error.new("pixel #{x},#{y} outside #{@width}x#{@height}")
    end
  end

  def self.read(bytes : Bytes) : Image
    io = IO::Memory.new(bytes)
    signature = Bytes.new(8)
    io.read_fully(signature)
    raise Error.new("not a PNG: bad signature") unless signature == SIGNATURE
    walk(io, bytes.size)
  end

  private record Header, width : Int32, height : Int32, depth : Int32, color_type : Int32

  private def self.walk(io : IO::Memory, size : Int32) : Image
    chunks = [] of String
    header = nil.as(Header?)
    palette = [] of {UInt8, UInt8, UInt8}
    transparency = Bytes.empty
    idat = IO::Memory.new
    while io.pos < size
      type, data = chunk(io)
      chunks << type
      case type
      when "IHDR" then header = parse_header(data)
      when "PLTE" then palette = parse_palette(data)
      when "tRNS" then transparency = data.dup
      when "IDAT" then idat.write(data)
      when "IEND" then break
      end
    end
    build(header, chunks, palette, transparency, idat)
  end

  # Length, type+data (checksummed together, exactly as the writer accumulates it), CRC.
  private def self.chunk(io : IO::Memory) : {String, Bytes}
    length = io.read_bytes(UInt32, IO::ByteFormat::BigEndian).to_i
    body = Bytes.new(4 + length)
    io.read_fully(body)
    crc = io.read_bytes(UInt32, IO::ByteFormat::BigEndian)
    type = String.new(body[0, 4])
    raise Error.new("CRC mismatch in #{type}") unless Digest::CRC32.checksum(body) == crc
    {type, body[4, length]}
  end

  private def self.parse_header(data : Bytes) : Header
    raise Error.new("short IHDR") unless data.size == 13
    width = IO::ByteFormat::BigEndian.decode(UInt32, data[0, 4]).to_i
    height = IO::ByteFormat::BigEndian.decode(UInt32, data[4, 4]).to_i
    raise Error.new("interlaced PNGs are not supported here") unless data[12] == 0
    Header.new(width, height, data[8].to_i, data[9].to_i)
  end

  private def self.parse_palette(data : Bytes) : Array({UInt8, UInt8, UInt8})
    raise Error.new("PLTE is not a multiple of 3") unless data.size % 3 == 0
    Array({UInt8, UInt8, UInt8}).new(data.size // 3) do |i|
      {data[i * 3], data[i * 3 + 1], data[i * 3 + 2]}
    end
  end

  private def self.build(header : Header?, chunks : Array(String),
                         palette : Array({UInt8, UInt8, UInt8}), transparency : Bytes,
                         idat : IO::Memory) : Image
    raise Error.new("no IHDR") unless header
    raise Error.new("only 8-bit depth is supported here") unless header.depth == 8
    unless header.color_type == INDEXED || header.color_type == TRUECOLOR
      raise Error.new("colour type #{header.color_type} is not supported here")
    end
    bpp = header.color_type == INDEXED ? 1 : 3
    inflated = Compress::Zlib::Reader.open(IO::Memory.new(idat.to_slice), &.getb_to_end)
    raw = unfilter(inflated, header.width, header.height, bpp)
    Image.new(header.width, header.height, header.depth, header.color_type,
      chunks, palette, transparency, raw)
  end

  # All five filter types, even though the writer only emits three: the spec's job is to read
  # what a PNG may contain, not what this writer happens to produce today.
  private def self.unfilter(data : Bytes, width : Int32, height : Int32, bpp : Int32) : Bytes
    stride = width * bpp
    dest = Bytes.new(stride * height)
    at = 0
    height.times do |y|
      raise Error.new("IDAT is short at row #{y}") if at + 1 + stride > data.size
      filter = data[at]
      at += 1
      unfilter_row(data, dest, at, y * stride, (y - 1) * stride, stride, bpp, filter, y > 0)
      at += stride
    end
    dest
  end

  private def self.unfilter_row(data : Bytes, dest : Bytes, from : Int32, row : Int32,
                                prev : Int32, stride : Int32, bpp : Int32, filter : UInt8,
                                has_prev : Bool) : Nil
    stride.times do |i|
      a = i >= bpp ? dest[row + i - bpp] : 0_u8
      b = has_prev ? dest[prev + i] : 0_u8
      c = i >= bpp && has_prev ? dest[prev + i - bpp] : 0_u8
      dest[row + i] = reconstruct(filter, data[from + i], a, b, c)
    end
  end

  private def self.reconstruct(filter : UInt8, raw : UInt8, a : UInt8, b : UInt8,
                               c : UInt8) : UInt8
    case filter
    when 0 then raw
    when 1 then raw &+ a
    when 2 then raw &+ b
    when 3 then raw &+ ((a.to_i + b.to_i) // 2).to_u8!
    when 4 then raw &+ paeth(a, b, c)
    else        raise Error.new("unknown PNG filter type #{filter}")
    end
  end

  private def self.paeth(a : UInt8, b : UInt8, c : UInt8) : UInt8
    p = a.to_i + b.to_i - c.to_i
    pa = (p - a.to_i).abs
    pb = (p - b.to_i).abs
    pc = (p - c.to_i).abs
    return a if pa <= pb && pa <= pc
    return b if pb <= pc
    c
  end
end
