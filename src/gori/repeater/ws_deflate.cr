require "compress/deflate"

module Gori::Repeater::WsDeflate
  OFFER = "permessage-deflate; client_no_context_takeover; server_no_context_takeover"
  TAIL  = Bytes[0, 0, 255, 255]

  class Error < Exception
  end

  # Only the independent-message profile is offered; a response must honour it (#1897).
  def self.negotiated?(head : Bytes, offered : Bool) : Bool
    values = Proxy::Codec::Http1.parse_response_head(head).headers.get_all("Sec-WebSocket-Extensions")
    return false if values.empty? || !offered
    extensions = values.join(",").split(',')
    raise Error.new("unsupported WebSocket extension negotiation") unless extensions.size == 1
    parts = extensions.first.split(';').map(&.strip)
    raise Error.new("unsupported WebSocket extension negotiation") unless parts.shift == "permessage-deflate"
    unless parts.uniq.size == parts.size && parts.includes?("server_no_context_takeover") &&
           parts.all? { |p| p.in?("server_no_context_takeover", "client_no_context_takeover") }
      raise Error.new("permessage-deflate requires server_no_context_takeover and no unsupported parameters")
    end
    true
  end

  def self.compress(payload : Bytes) : Bytes
    output = IO::Memory.new
    writer = Compress::Deflate::Writer.new(output)
    begin
      writer.write(payload)
      writer.flush
      output.to_slice[0, output.size - TAIL.size].dup
    ensure
      writer.close
    end
  end

  # A final empty block lets the stdlib reader validate the sync-flushed stream to EOF.
  # Separate final blocks in a message (RFC 7692 §7.2.3.4) are read as successive streams.
  def self.inflate(payload : Bytes, max_out : Int32) : Bytes
    input = IO::Memory.new
    input.write(payload)
    input.write(TAIL)
    input.write(Bytes[1, 0, 0, 255, 255])
    input.rewind
    output = IO::Memory.new
    buffer = uninitialized UInt8[8192]
    streams = 0
    while input.pos < input.size
      streams += 1
      raise Error.new("permessage-deflate exceeds the 64-stream decode work cap") if streams > 64
      Compress::Deflate::Reader.open(input) do |reader|
        loop do
          n = reader.read(buffer.to_slice[0, Math.min(buffer.size, max_out - output.size + 1)])
          break if n == 0
          raise Error.new("inflated WebSocket message exceeds the #{max_out}-byte receive cap") if output.size + n > max_out
          output.write(buffer.to_slice[0, n])
        end
      end
    end
    output.to_slice
  rescue ex : Compress::Deflate::Error
    raise Error.new("invalid permessage-deflate message: #{ex.message}")
  end
end
