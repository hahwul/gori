module Gori
  # The Decoder engine: a TUI-independent library of named encode/decode/hash
  # converters plus a left-to-right chain executor (the Decoder tab + a future CLI
  # both drive it). A value flows through the chain as `Bytes` so binary results
  # (gzip, hash digests, base64/hex decode) stay first-class; text converters are
  # authored with the `text` builder, which wraps the lossless Bytes⇄String
  # round-trip (the same invariant mcp/serialize relies on). Depends on Gori::Error, the
  # stdlib, and the two leaf FFI codecs (`Proxy::Codec::Brotli`/`Zstd`) — the two
  # `Content-Encoding`s a captured body arrives in that Crystal has no stdlib reader for.
  module Decoder
    # Structurally-invalid input (bad base64, odd-length hex, truncated gzip …).
    # Subclass of Gori::Error so the app's top-level rescue still classifies it, but
    # the chain executor catches it per-step and turns it into a Failed StepResult —
    # it never escapes a `run`.
    class DecoderError < Gori::Error
    end

    enum Category
      Encoding      # base64, url, hex, base32, ascii85, base58
      Compression   # gzip, zlib, brotli, zstd
      Serialization # msgpack, cbor — a binary document rendered as JSON text
      Hash          # md5, sha1, sha224, sha256, sha384, sha512
      Token         # jwt-decode
      Escape        # html, json-string, unicode
      Text          # rot13, upper, lower, reverse
      Saved         # a named chain from the user's library, callable as one step (decoder/library.cr)

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
      # WHY this converter cannot run, or nil when it can. Only a saved chain sets it: the
      # library registers a recursive / over-MAX_TOKENS entry anyway, as a step that raises,
      # so its NAME still resolves and the failure is visible instead of looking like a typo
      # (see decoder/library.cr). `apply` raises this same sentence — but a caller that must
      # decide BEFORE it sends anything cannot find out by calling it, and the one that
      # guessed instead put un-transformed payloads on the wire and reported `0 errors`.
      # Asking the registry is the same fact, one step earlier and with no side effect.
      getter unusable : String?
      # Whether running this converter runs an EXTERNAL COMMAND. Only a saved chain sets it,
      # and only when its flattened steps contain an `exec:` one (#818) — a built-in never
      # does. It exists because a saved chain is callable BY NAME, so `myenc` can run a command
      # with nothing in the token to say so, and a caller that must refuse command execution
      # (the MCP `decode` tool, which is exposed read-only and unbound) cannot see that by
      # looking at the spec. Askable without calling it, for the same reason `unusable` is.
      getter? runs_commands : Bool

      def initialize(@name, @aliases, @category, @direction, @description, @fn,
                     @unusable : String? = nil, @runs_commands : Bool = false)
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
    #
    # `unusable` is passed through for a converter whose NAME must resolve even where it cannot
    # run — the brotli and zstd decoders in a `-Dwithout_native_codecs` build. Registering them
    # only when the libraries are linked would make `brotli` read as a typo on a build that
    # deliberately dropped them; registering them unusable says which build the operator has.
    # See `Converter#unusable`.
    def self.bytes(name : String, *aliases, category : Category,
                   direction : Direction, description : String, unusable : String? = nil,
                   &fn : Bytes -> Bytes) : Converter
      Converter.new(name, alias_list(aliases), category, direction, description, fn, unusable)
    end

    # text-in / text-out (rot13, url-encode, html-escape …). The transform is
    # character-oriented (String#each_char / String::Builder), so a non-UTF-8
    # intermediate (e.g. raw bytes from a prior hex/base64-decode or gzip step) can't
    # be processed byte-faithfully — each_char would substitute U+FFFD, silently
    # corrupting AND inflating the data. Fail cleanly with a DecoderError (the chain
    # catches it per-step) instead of emitting garbage.
    def self.text(name : String, *aliases, category : Category,
                  direction : Direction, description : String, &fn : String -> String) : Converter
      wrapped = ->(input : Bytes) {
        str = String.new(input)
        raise DecoderError.new("#{name}: needs valid UTF-8 text (got binary — decode/re-encode it to text first)") unless str.valid_encoding?
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
    # clean DecoderError rather than letting the decoder's regex/each_char raise a
    # raw "UTF-8 error: isolated byte" (base64/hex use gsub over the String).
    def self.decode(name : String, *aliases, category : Category,
                    description : String, &fn : String -> Bytes) : Converter
      wrapped = ->(input : Bytes) {
        str = String.new(input)
        raise DecoderError.new("#{name}: input is not valid text (a decoder reads text-encoded data)") unless str.valid_encoding?
        fn.call(str)
      }
      Converter.new(name, alias_list(aliases), category, Direction::Decode, description, wrapped)
    end
  end
end
