require "json"
require "base64"
require "socket"
require "./binary_document"

module Gori
  # A DNS message (RFC 1035 §4) as a JSON projection: the body of a DNS-over-HTTPS exchange
  # (RFC 8484, `application/dns-message`), which is otherwise a binary placeholder.
  #
  # All or nothing, unlike the schema-less readers beside it. A DNS message declares its own
  # record counts, so a body that is not one runs off the end and is REFUSED rather than shown
  # in part: `BinaryDocument::Rendering#describes?` then sends the caller to the hex view.
  # Derived view only (P7): nothing here re-encodes a byte that is stored or resent.
  module DnsMessage
    extend self

    # RFC 8484 §6: a message is at most 65535 octets, and every record count is a 16-bit number
    # the body itself has to back with bytes.
    MAX_SIZE = 65_535

    TYPES = {1 => "A", 2 => "NS", 5 => "CNAME", 6 => "SOA", 12 => "PTR", 15 => "MX",
             16 => "TXT", 28 => "AAAA", 33 => "SRV", 41 => "OPT", 43 => "DS", 46 => "RRSIG",
             48 => "DNSKEY", 64 => "SVCB", 65 => "HTTPS", 255 => "ANY", 257 => "CAA"}
    RCODES   = %w[NOERROR FORMERR SERVFAIL NXDOMAIN NOTIMP REFUSED]
    SVC_KEYS = %w[mandatory alpn no-default-alpn port ipv4hint ech ipv6hint]

    def render(data : Bytes, *, indent : String? = nil) : BinaryDocument::Rendering
      return refused("too large") if data.size > MAX_SIZE
      reader = Reader.new(data)
      json = JSON.build(indent) { |j| reader.message(j) }
      return refused("trailing") unless reader.pos == data.size
      BinaryDocument::Rendering.new(json, true, data.size, nil, true)
    rescue
      # Every exception, the same net `Cbor.render` carries: this is reached from a TUI draw
      # and from `DecodedView`, and a body off the wire is hostile by default.
      refused("invalid")
    end

    # :ditto: the two-element form the other readers expose.
    def to_json(data : Bytes) : {String, Bool}
      r = render(data)
      {r.json, r.complete}
    end

    private def refused(stop : String) : BinaryDocument::Rendering
      BinaryDocument::Rendering.new(%({"$partial":"not a DNS message"}), false, 0, stop, false)
    end

    # Reads past the end raise `IndexError` (`Bytes#[]`), which `render` turns into a refusal.
    private class Reader
      MAX_JUMPS = 32 # compression pointers followed per name; a loop ends here
      # Octets of names a message may EXPAND to. A two-byte pointer can stand for a 255-octet
      # name, so a 65 KB body of pointers would otherwise render as megabytes of JSON.
      MAX_NAME_BYTES = 256 * 1024

      getter pos = 0
      @expanded = 0

      def initialize(@data : Bytes)
      end

      def message(j : JSON::Builder) : Nil
        id = u16
        hi = u8
        lo = u8
        counts = {u16, u16, u16, u16}
        flags = [] of String
        { {hi, 0x04, "aa"}, {hi, 0x02, "tc"}, {hi, 0x01, "rd"},
         {lo, 0x80, "ra"}, {lo, 0x40, "z"}, {lo, 0x20, "ad"}, {lo, 0x10, "cd"} }.each do |(byte, bit, name)|
          flags << name if byte & bit != 0
        end
        j.object do
          j.field "id", id
          j.field "kind", hi & 0x80 != 0 ? "response" : "query"
          j.field "opcode", (hi >> 3) & 0x0f
          j.field "rcode", RCODES[lo & 0x0f]? || (lo & 0x0f).to_s
          j.field "flags", flags
          j.field("question") { j.array { counts[0].times { question(j) } } }
          {"answer", "authority", "additional"}.each_with_index do |section, i|
            j.field(section) { j.array { counts[i + 1].times { record(j) } } }
          end
        end
      end

      private def question(j : JSON::Builder) : Nil
        owner = name
        type = u16
        klass = u16
        j.object do
          j.field "name", owner
          j.field "type", type_name(type)
          j.field "class", class_name(klass)
        end
      end

      private def record(j : JSON::Builder) : Nil
        owner = name
        type = u16
        klass = u16
        ttl = (u16.to_i64 << 16) | u16
        len = u16
        stop = @pos + len
        raise IndexError.new if stop > @data.size
        j.object do
          j.field "name", owner
          j.field "type", type_name(type)
          if type == 41
            # OPT (RFC 6891) reuses CLASS for the sender's UDP payload size and TTL for the
            # upper bits of the RCODE, the EDNS version and the DO bit.
            j.field "udp_size", klass
            j.field "extended_rcode", ttl >> 24
            j.field "version", (ttl >> 16) & 0xff
            j.field "do", ttl & 0x8000 != 0
          else
            j.field "class", class_name(klass)
            j.field "ttl", ttl
          end
          j.field("data") { rdata(j, type, stop) }
        end
        # Every reader consumes its RDATA exactly. Bytes left behind a name would be bytes the
        # rendering hides, so such a record refuses the message instead.
        raise IndexError.new unless @pos == stop
      end

      private def rdata(j : JSON::Builder, type : Int32, stop : Int32) : Nil
        len = stop - @pos
        case
        when len == 0                then bin(j, take(0, stop)) # an RFC 2136 UPDATE carries these
        when type == 1 && len == 4   then j.string(v4(take(4, stop)))
        when type == 28 && len == 16 then j.string(v6(take(16, stop)))
        when type.in?(2, 5, 12)      then j.string(name)
        when type == 15
          j.object do
            j.field "preference", u16
            j.field "exchange", name
          end
        when type == 6
          j.object do
            j.field "mname", name
            j.field "rname", name
            {"serial", "refresh", "retry", "expire", "minimum"}.each do |key|
              j.field key, (u16.to_i64 << 16) | u16
            end
          end
        when type == 16
          j.array do
            while @pos < stop
              j.string(text(take(u8, stop)))
            end
          end
        when type.in?(64, 65) then svcb(j, stop)
        else                       bin(j, take(len, stop))
        end
      end

      # SVCB / HTTPS (RFC 9460): the record that hands a client an HTTP/3 route or an ECH
      # config without any response header gori could see.
      private def svcb(j : JSON::Builder, stop : Int32) : Nil
        j.object do
          j.field "priority", u16
          j.field "target", name
          while @pos < stop
            key = u16
            value = take(u16, stop)
            j.field(SVC_KEYS[key]? || "key#{key}") { svc_value(j, key, value) }
          end
        end
      end

      private def svc_value(j : JSON::Builder, key : Int32, value : Bytes) : Nil
        case
        when key == 1 # alpn: length-prefixed protocol ids
          j.array do
            i = 0
            while i < value.size
              n = value[i].to_i
              j.string(text(value[i + 1, n]))
              i += n + 1
            end
          end
        when key == 3 && value.size == 2 then j.number((value[0].to_i << 8) | value[1])
        when key == 4 && value.size % 4 == 0
          j.array { (value.size // 4).times { |i| j.string(v4(value[i * 4, 4])) } }
        when key == 5 then j.string(Base64.strict_encode(value))
        when key == 6 && value.size % 16 == 0
          j.array { (value.size // 16).times { |i| j.string(v6(value[i * 16, 16])) } }
        else bin(j, value)
        end
      end

      # A domain name at `@pos`, compression pointers followed (RFC 1035 §4.1.4). `@pos` ends
      # after the name where it was WRITTEN, not where a pointer led.
      private def name : String
        labels = [] of String
        pos = @pos
        after = nil
        jumps = 0
        total = 0
        loop do
          len = @data[pos].to_i
          if len == 0
            pos += 1
            break
          elsif len >= 0xc0
            after ||= pos + 2
            raise IndexError.new if (jumps += 1) > MAX_JUMPS
            pos = ((len & 0x3f) << 8) | @data[pos + 1]
          elsif len > 63
            raise IndexError.new # the 0x40 / 0x80 label types were never deployed
          else
            raise IndexError.new if (total += len + 1) > 255
            raise IndexError.new if (@expanded += len + 1) > MAX_NAME_BYTES
            labels << text(@data[pos + 1, len], label: true)
            pos += len + 1
          end
        end
        @pos = after || pos
        labels.empty? ? "." : labels.join('.') + "."
      end

      # Wire octets as ASCII text, anything else as the `\DDD` escape of RFC 1035 §5.1. So a
      # label or a TXT string holding arbitrary bytes still renders as valid JSON, and a dot
      # INSIDE a label cannot pass for a label boundary.
      private def text(bytes : Bytes, label = false) : String
        String.build do |io|
          bytes.each do |b|
            plain = b > (label ? 0x20 : 0x1f) && b < 0x7f && b != 0x5c && !(label && b == 0x2e)
            plain ? io << b.chr : io << '\\' << b.to_s.rjust(3, '0')
          end
        end
      end

      private def v4(b : Bytes) : String
        Socket::IPAddress.v4(b[0], b[1], b[2], b[3], port: 0).address
      end

      private def v6(b : Bytes) : String
        g = StaticArray(UInt16, 8).new { |i| (b[i * 2].to_u16 << 8) | b[i * 2 + 1] }
        Socket::IPAddress.v6(g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], port: 0).address
      end

      # Base64, as every other reader behind `binary_documents[]` spells `$bin`.
      private def bin(j : JSON::Builder, bytes : Bytes) : Nil
        j.object { j.field "$bin", Base64.strict_encode(bytes) }
      end

      private def take(n : Int32, stop : Int32) : Bytes
        raise IndexError.new if @pos + n > stop
        slice = @data[@pos, n]
        @pos += n
        slice
      end

      private def type_name(type : Int32) : String
        TYPES[type]? || "TYPE#{type}"
      end

      private def class_name(klass : Int32) : String
        klass == 1 ? "IN" : "CLASS#{klass}"
      end

      private def u8 : Int32
        v = @data[@pos].to_i
        @pos += 1
        v
      end

      private def u16 : Int32
        (u8 << 8) | u8
      end
    end
  end
end
