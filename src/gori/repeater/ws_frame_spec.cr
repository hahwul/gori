require "base64"
require "../store/models"
require "../proxy/ws/frame"

module Gori
  module Repeater
    # The one grammar both scripted surfaces use to author a WebSocket frame whose shape is
    # not the default one — `gori run repeater send --message-frame`, and MCP's string form of
    # a `messages` / `ws_out_messages` entry.
    #
    # It exists because `--message TEXT` and a JSON string can only ever mean "TEXT, FIN=1,
    # RSV=0, masked, length equal to the payload". That is one shape, and the frames a
    # WebSocket test actually needs — a PING with a chosen payload, a CLOSE with a chosen
    # code, an unmasked client frame (§5.1), a lone CONT or a FIN=0 fragment (§5.4), an RSV1
    # frame on a socket that negotiated no extension (§5.2), a length header that disagrees
    # with the payload — are all outside it.
    #
    # A SEPARATE flag rather than a prefix syntax on `--message`. A prefix would make some
    # literal payload unsendable the moment it happened to start with the marker, which is the
    # byte-exactness invariant this codebase treats as P0: an operator must always be able to
    # send the bytes they typed.
    #
    #   opcode=text|bin|cont|close|ping|pong|<0-15>   (default: text, or bin with hex=/b64=)
    #   fin=0|1                                        (default 1)
    #   rsv=<0-7>                                      (RSV1=4, RSV2=2, RSV3=1; default 0)
    #   mask=0|1                                       (default 1 — §5.3 requires it of a client)
    #   mask_key=<8 hex digits>                        (default: a fresh random key per send)
    #   len=<n>                                        (the DECLARED length; default: the payload's)
    #   hex=<hex> | b64=<base64> | text=<literal>      (the payload; default empty)
    #
    # Comma-separated, and `text=` takes everything to the end of the spec so a payload may
    # contain commas, `=` and spaces. `hex=`/`b64=` are there for a payload that cannot go
    # through a shell argument intact.
    module WsFrameSpec
      OPCODES = {
        "cont" => 0, "text" => 1, "bin" => 2, "binary" => 2,
        "close" => 8, "ping" => 9, "pong" => 10,
      }

      # The fields as they accumulate. A mutable holder rather than eight locals threaded
      # through the loop, so `parse` stays a scanner and `set` stays a per-field validator.
      private class Fields
        property opcode : Int32? = nil
        property? fin = true
        property rsv = 0
        property masked : Bool? = nil
        property mask_key : Bytes? = nil
        property declared : Int32? = nil
        property payload = Bytes.empty
        property payload_kind : String? = nil

        # nil on success, else the error naming the field. One `when` per field, each one
        # statement long — the branchiness is the grammar's, and it belongs in one place.
        def set(key : String, value : String) : String?
          case key
          when "opcode"   then take_opcode(value)
          when "fin"      then take_bool(value, "fin") { |b| @fin = b }
          when "mask"     then take_bool(value, "mask") { |b| @masked = b }
          when "rsv"      then take_rsv(value)
          when "len"      then take_len(value)
          when "mask_key" then take_mask_key(value)
          when "hex", "b64", "text"
            take_payload(key, value)
          else
            "unknown --message-frame field #{key.inspect}"
          end
        end

        private def take_opcode(value : String) : String?
          v = value.strip.downcase
          op = OPCODES[v]? || v.to_i?
          return "bad opcode #{value.inspect} (expected #{OPCODES.keys.join('|')} or 0-15)" unless op
          return "opcode #{op} out of range (0-15)" unless 0 <= op <= 15
          @opcode = op
          nil
        end

        # `b = bool(value) || return …` would take the error branch on a legitimate FALSE —
        # the one value `fin=0` and `mask=0` exist to express. Ask about nil explicitly.
        private def take_bool(value : String, name : String, &) : String?
          b = WsFrameSpec.bool(value)
          return "bad #{name} #{value.inspect} (expected 0 or 1)" if b.nil?
          yield b
          nil
        end

        private def take_rsv(value : String) : String?
          r = value.strip.to_i?
          return "bad rsv #{value.inspect} (expected 0-7; RSV1=4, RSV2=2, RSV3=1)" unless r && 0 <= r <= 7
          @rsv = r
          nil
        end

        private def take_len(value : String) : String?
          n = value.strip.to_i?
          return "bad len #{value.inspect} (expected a non-negative integer)" unless n && n >= 0
          @declared = n
          nil
        end

        private def take_mask_key(value : String) : String?
          k = WsFrameSpec.hex(value)
          return "bad mask_key #{value.inspect} (expected hex digits)" unless k
          @mask_key = k
          @masked = true if @masked.nil?
          nil
        end

        private def take_payload(key : String, value : String) : String?
          @payload_kind = key
          case key
          when "text" then @payload = value.to_slice
          when "hex"
            k = WsFrameSpec.hex(value)
            return "bad hex payload #{value.inspect}" unless k
            @payload = k
          else
            @payload = (Base64.decode(value.strip) rescue return "bad b64 payload #{value.inspect}")
          end
          nil
        end

        def message : Store::WsOutMessage
          # A hex/base64 payload with no stated opcode is BINARY: an operator who reached for
          # a byte encoding was not describing text. A bare shape with no payload at all stays
          # TEXT, which is what an empty frame or a control frame with no body wants.
          op = @opcode || (@payload_kind == "hex" || @payload_kind == "b64" ? 2 : 1)
          Store::WsOutMessage.new(op, @payload,
            Proxy::WS::Shape.new(fin: @fin, rsv: @rsv, masked: @masked,
              mask_key: @mask_key, declared_len: @declared))
        end
      end

      # {message, nil} or {nil, error}. Never raises: every surface here reports rather than
      # aborts mid-parse, and the error names the field so a script can fix it.
      def self.parse(spec : String) : {Store::WsOutMessage?, String?}
        f = Fields.new
        rest = spec
        until rest.empty?
          eq = rest.index('=')
          return {nil, "bad --message-frame field #{rest.split(',').first.inspect} (expected key=value)"} unless eq
          key = rest[0, eq].strip.downcase
          # `text=` is the payload and swallows the remainder verbatim — commas and all, so a
          # payload may contain the delimiter without an escape nobody would remember.
          if key == "text"
            err = f.set(key, rest[(eq + 1)..])
            return {nil, err} if err
            break
          end
          comma = rest.index(',', eq)
          value = comma ? rest[(eq + 1)...comma] : rest[(eq + 1)..]
          rest = comma ? rest[(comma + 1)..] : ""
          err = f.set(key, value)
          return {nil, err} if err
        end
        {f.message, nil}
      end

      protected def self.bool(v : String) : Bool?
        case v.strip.downcase
        when "1", "true", "yes", "on"  then true
        when "0", "false", "no", "off" then false
        end
      end

      # Hex digits, optionally 0x-prefixed and with `:`/`-`/spaces between octets — the forms
      # a mask key or a payload gets pasted in. An odd digit count is an error, not a guess.
      protected def self.hex(v : String) : Bytes?
        # `.scrub` first: `v` is a raw `--message-frame` value off the command line, and
        # PCRE2 raises `ArgumentError` on a subject that is not valid UTF-8 — which would
        # break this module's documented "Never raises" contract (see `parse` above) and
        # escape `CLI.run`, whose rescue only covers `Gori::Error`. Lossless in practice:
        # anything a scrub touches fails the hex-digit check two lines down regardless.
        s = v.scrub.strip.gsub(/\A0[xX]/, "").gsub(/[\s:_-]/, "")
        return Bytes.empty if s.empty?
        return nil unless s.size.even? && s.matches?(/\A[0-9a-fA-F]+\z/)
        s.hexbytes
      end
    end
  end
end
