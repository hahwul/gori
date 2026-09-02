require "./curl"
require "./escape"
require "./request_parts"

module Gori
  module Export
    # A captured request as a runnable `httpie` (`http`) command — the serializer behind the
    # TUI's "Copy as → httpie" row and `gori run show <id> --format httpie`. Surface-neutral,
    # same shape as `Export::Curl`. Like the curl serializer this is a SHELL command, so it
    # reuses `Curl.shell_quote` (every byte survives '…' except 0x00) and refuses a NUL the
    # same way — with a `#` comment rather than an argument a shell would truncate. It refuses
    # one byte curl does not: httpie is Python, and a field that is not valid UTF-8 aborts the
    # whole command before it dials (`carriable?`).
    module Httpie
      # The command for one request, or nil when there is no resolvable URL.
      def self.text(wire : String, target : String) : String?
        parts = RequestParts.from_wire(wire, target)
        parts ? command(parts) : nil
      end

      def self.command(parts : RequestParts::Parts) : String
        s = RequestParts.sendable(parts)
        url = Escape.percent_encode_non_ascii(parts.url)
        # The URL is the one argument the command IS. A NUL in it truncates the fetch target, and
        # a byte sequence that is not valid UTF-8 kills the process before it dials (see
        # `carriable?`), so — like `Export::Curl` — there is nothing runnable to hand over: emit
        # the whole thing as a comment, and a paste does nothing rather than doing the wrong thing.
        unless carriable?(url)
          return "# no command: the captured URL holds #{uncarriable(url)} — httpie would " \
                 "request a different resource than the capture did, or fail before it dialled. " \
                 "Read the request line with --format raw"
        end
        method = (parts.method.empty? ? "GET" : parts.method)
        notes = [] of String
        # A NUL in the method truncates the positional argument (and a non-UTF-8 byte aborts the
        # whole command); drop it and let httpie infer the method — GET, or POST when a body is
        # present — the way `Curl.nul_method_note` drops -X.
        if carriable?(method)
          out = ["http #{Curl.shell_quote(method)} #{Curl.shell_quote(url)}"]
        else
          notes << "# method omitted: it holds #{uncarriable(method)} — httpie will infer " \
                   "#{s.body.empty? ? "GET" : "POST"} instead. Read the request line with --format raw"
          out = ["http #{Curl.shell_quote(url)}"]
        end
        s.headers.each do |(n, v)|
          # A NUL truncates a shell argument (zsh silently, bash by refusing the line) and a byte
          # that is not valid UTF-8 takes the whole command down, so a header carrying either is
          # dropped and named rather than sent short. Same hole `Curl.nul_header_note` covers.
          unless carriable?(n) && carriable?(v)
            bad = carriable?(n) ? uncarriable(v) : uncarriable(n)
            notes << "# header '#{n}' omitted: it holds #{bad} — read the head with --format raw"
            next
          end
          # A backslash the escaping below cannot survive — see `escape_defeated?`. Dropped and
          # named for the same reason a NUL is: the alternative is an item that means something
          # other than this header.
          if escape_defeated?(n) || escape_defeated?(v)
            notes << "# header '#{n}' omitted: a backslash before one of httpie's item separators (; = @) " \
                     "cannot be escaped, so httpie would eat it — read the head with --format raw"
            next
          end
          out << Curl.shell_quote(header_item(n, v))
        end
        unless s.body.empty?
          if carriable?(s.body)
            # --raw sends the body verbatim, so httpie does not try to parse it as request items.
            out << "--raw #{Curl.shell_quote(s.body)}"
          else
            notes << "# body omitted: #{s.body.bytesize} bytes holding #{uncarriable(s.body)} — " \
                     "pipe it in instead: `... --raw < FILE` with --format raw"
          end
        end
        # LAST, like curl's notes: a `#` comment swallows the ` \` that continues its line, so a
        # note earlier would truncate the command it annotates.
        out.concat(notes)
        out.join(" \\\n  ")
      end

      # Can this field ride on an httpie command line at all? Two bytes cannot, for two different
      # reasons, and both take the same treatment — drop the field and name it:
      #
      #   * NUL. A shell argv is NUL-terminated, so no quoting puts one in an argument;
      #     `Export::Curl` refuses it on the same grounds.
      #   * anything that is not valid UTF-8. httpie is Python: it reads argv through
      #     `surrogateescape`, so `caf\xe9` arrives as `caf\udce9` and the first `.encode()`
      #     raises. Measured on httpie 3.2.4 / Python 3.14, once per field position:
      #
      #       http GET http://h/ $'X-L:caf\xe9'   UnicodeEncodeError: … '\udce9' … surrogates not allowed
      #       http POST http://h/ --raw $'\x80\xff'  UnicodeEncodeError: … position 0-2 …
      #
      #     — and it is fatal to the whole command, not to the one field: zero requests reach the
      #     wire, where curl / requests / fetch / net-http all send those same bytes verbatim. So
      #     the drop is what makes the rest of the command runnable.
      private def self.carriable?(s : String) : Bool
        !s.to_slice.includes?(0_u8) && s.valid_encoding?
      end

      # How a field failed `carriable?`, phrased to slot in after "holds".
      private def self.uncarriable(s : String) : String
        if s.to_slice.includes?(0_u8)
          "a NUL no shell argument can carry"
        else
          "bytes that are not valid UTF-8, which httpie dies re-encoding before it sends"
        end
      end

      # The bytes httpie reads as an item separator, on their own or paired (`:=`, `:@`, `:=@`,
      # `==`, `=@`, `==@`, `;`). A backslash in front of one is httpie's own escape, and it is
      # stripped back off before the request is built.
      SEPARATOR_BYTES = {0x3b_u8, 0x3d_u8, 0x40_u8} # ; = @

      # One httpie request item for a header field. `Name:Value` (no space), with two things the
      # plain interpolation gets wrong — both measured against httpie 3.2.4 and a raw listener:
      #
      #   * an EMPTY value. `Name:` is httpie's syntax for UNSETTING a header, so a captured
      #     `X-Empty:` produced a command that sent no such field at all. `Name;` is the spelling
      #     for "send it with an empty value" — the same split curl's `-H` draws.
      #   * httpie chooses an item's separator by scanning for the FIRST of `;`/`=`/`:`/`@`, so
      #     one of those in the NAME, or a `=`/`@` opening the VALUE, silently changes what the
      #     item IS. `X=A: v1` became the DATA field `X`, and the reproduction of a bodyless GET
      #     went out as `Content-Type: application/json` with a body of `{"X": "A:v1"}` — the
      #     header dropped and a body invented. `X-E: @boom` became httpie's `Header:@file` and
      #     made the command read the local file `boom`.
      #
      # Only the value's FIRST byte needs escaping: a `=` or `@` deeper in cannot extend the `:`
      # that already separated the item. Byte-wise, like everything else here, so a header name
      # that is not valid UTF-8 is not rewritten into U+FFFD on its way into the command.
      private def self.header_item(name : String, value : String) : String
        escaped = String.build do |b|
          name.to_slice.each do |byte|
            b << '\\' if SEPARATOR_BYTES.includes?(byte)
            b.write_byte(byte)
          end
        end
        return "#{escaped};" if value.empty?
        first = value.to_slice[0]
        lead = (first == 0x3d_u8 || first == 0x40_u8) ? "\\" : ""
        "#{escaped}:#{lead}#{value}"
      end

      # Does this field carry a backslash that `header_item`'s escaping cannot get past? httpie
      # keeps `\x` verbatim when `x` is not a separator byte, but reads `\;`/`\=`/`\@` as the
      # escape and drops the backslash — and there is no way to spell a LITERAL backslash in
      # front of one, since `\\` stays two backslashes and re-exposes the separator. So a value
      # of `a\=b` cannot be carried by an item at all, either as itself (httpie sends `a=b`) or
      # escaped (httpie sends `a\\=b`).
      private def self.escape_defeated?(s : String) : Bool
        bytes = s.to_slice
        bytes.each_with_index do |b, i|
          return true if b == 0x5c_u8 && i + 1 < bytes.size && SEPARATOR_BYTES.includes?(bytes[i + 1])
        end
        false
      end
    end
  end
end
