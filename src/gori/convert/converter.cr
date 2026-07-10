module Gori
  # The Convert engine: a TUI-independent library of named encode/decode/hash
  # converters plus a left-to-right chain executor (the Convert tab + a future CLI
  # both drive it). A value flows through the chain as `Bytes` so binary results
  # (gzip, hash digests, base64/hex decode) stay first-class; text converters are
  # authored with the `text` builder, which wraps the lossless Bytes⇄String
  # round-trip (the same invariant mcp/serialize relies on). Pure: depends only on
  # Gori::Error + the stdlib.
  module Convert
    # Structurally-invalid input (bad base64, odd-length hex, truncated gzip …).
    # Subclass of Gori::Error so the app's top-level rescue still classifies it, but
    # the chain executor catches it per-step and turns it into a Failed StepResult —
    # it never escapes a `run`.
    class ConvertError < Gori::Error
    end

    enum Category
      Encoding    # base64, url, hex, base32, ascii85, base58
      Compression # gzip, zlib
      Hash        # md5, sha1, sha256, sha512
      Token       # jwt-decode
      Escape      # html, json-string, unicode
      Text        # rot13, upper, lower, reverse

      def label : String
        to_s.downcase
      end
    end

    enum Direction
      Encode
      Decode
      Hash
      Transform
    end

    # One converter. `fn` is Bytes -> Bytes so binary flows losslessly; the builder
    # helpers below adapt String-shaped transforms onto that boundary.
    struct Converter
      getter name : String # canonical (already normalized: lowercase, hyphenated)
      getter aliases : Array(String)
      getter category : Category
      getter direction : Direction
      getter description : String
      getter fn : Proc(Bytes, Bytes)

      def initialize(@name, @aliases, @category, @direction, @description, @fn)
      end

      def apply(input : Bytes) : Bytes
        @fn.call(input)
      end

      # Every lookup key (canonical + aliases); the registry normalizes them.
      def keys : Array(String)
        [@name] + @aliases
      end
    end

    # ---- builder helpers: keep each catalog entry a single line ----

    # NOTE: the alias splats are intentionally untyped (`*aliases`, not
    # `*aliases : String`) — a TYPE-restricted positional splat requires ≥1 arg in
    # Crystal, which would forbid the no-alias converters (md5, rot13, …). An empty
    # splat's `.to_a` is `Array(NoReturn)`, so `alias_list` rebuilds a real
    # `Array(String)` (empty when there are no aliases).
    private def self.alias_list(aliases) : Array(String)
      out = [] of String
      aliases.each { |a| out << a.to_s }
      out
    end

    # bytes-in / bytes-out (gzip, zlib) — the raw form.
    def self.bytes(name : String, *aliases, category : Category,
                   direction : Direction, description : String, &fn : Bytes -> Bytes) : Converter
      Converter.new(name, alias_list(aliases), category, direction, description, fn)
    end

    # text-in / text-out (rot13, url-encode, html-escape …). The transform is
    # character-oriented (String#each_char / String::Builder), so a non-UTF-8
    # intermediate (e.g. raw bytes from a prior hex/base64-decode or gzip step) can't
    # be processed byte-faithfully — each_char would substitute U+FFFD, silently
    # corrupting AND inflating the data. Fail cleanly with a ConvertError (the chain
    # catches it per-step) instead of emitting garbage.
    def self.text(name : String, *aliases, category : Category,
                  direction : Direction, description : String, &fn : String -> String) : Converter
      wrapped = ->(input : Bytes) {
        str = String.new(input)
        raise ConvertError.new("#{name}: needs valid UTF-8 text (got binary — decode/re-encode it to text first)") unless str.valid_encoding?
        fn.call(str).to_slice
      }
      Converter.new(name, alias_list(aliases), category, direction, description, wrapped)
    end

    # bytes-in / text-out (hashes, hex-encode, base64-encode).
    def self.encode(name : String, *aliases, category : Category,
                    description : String, direction : Direction = Direction::Encode, &fn : Bytes -> String) : Converter
      wrapped = ->(input : Bytes) { fn.call(input).to_slice }
      Converter.new(name, alias_list(aliases), category, direction, description, wrapped)
    end

    # text-in / bytes-out (base64-decode, hex-decode). Decoders read text-encoded
    # data, so a non-UTF-8 intermediate is never valid input — guard it here with a
    # clean ConvertError rather than letting the decoder's regex/each_char raise a
    # raw "UTF-8 error: isolated byte" (base64/hex use gsub over the String).
    def self.decode(name : String, *aliases, category : Category,
                    description : String, &fn : String -> Bytes) : Converter
      wrapped = ->(input : Bytes) {
        str = String.new(input)
        raise ConvertError.new("#{name}: input is not valid text (a decoder reads text-encoded data)") unless str.valid_encoding?
        fn.call(str)
      }
      Converter.new(name, alias_list(aliases), category, Direction::Decode, description, wrapped)
    end
  end
end
