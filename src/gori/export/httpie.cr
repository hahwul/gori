require "./curl"
require "./request_parts"

module Gori
  module Export
    # A captured request as a runnable `httpie` (`http`) command — the serializer behind the
    # TUI's "Copy as → httpie" row and `gori run show <id> --format httpie`. Surface-neutral,
    # same shape as `Export::Curl`. Like the curl serializer this is a SHELL command, so it
    # reuses `Curl.shell_quote` (every byte survives '…' except 0x00) and refuses a NUL the
    # same way — with a `#` comment rather than an argument a shell would truncate.
    module Httpie
      # The command for one request, or nil when there is no resolvable URL.
      def self.text(wire : String, target : String) : String?
        parts = RequestParts.from_wire(wire, target)
        parts ? command(parts) : nil
      end

      def self.command(parts : RequestParts::Parts) : String
        s = RequestParts.sendable(parts)
        # The URL is the one argument the command IS. A NUL in it truncates the fetch target, so
        # — like `Export::Curl` — there is nothing runnable to hand over: emit the whole thing as
        # a comment, and a paste does nothing rather than requesting a different resource.
        if parts.url.to_slice.includes?(0_u8)
          return "# no command: the captured URL holds a NUL no shell argument can carry — a " \
                 "shell truncates the argument there, so httpie would request a different " \
                 "resource than the capture did. Read the request line with --format raw"
        end
        method = (parts.method.empty? ? "GET" : parts.method)
        notes = [] of String
        # A NUL in the method truncates the positional argument; drop it and let httpie infer the
        # method (GET, or POST when a body is present), the way `Curl.nul_method_note` drops -X.
        if method.to_slice.includes?(0_u8)
          notes << "# method omitted: it holds a NUL no shell argument can carry — httpie will " \
                   "infer #{s.body.empty? ? "GET" : "POST"} instead. Read the request line with --format raw"
          out = ["http #{Curl.shell_quote(parts.url)}"]
        else
          out = ["http #{Curl.shell_quote(method)} #{Curl.shell_quote(parts.url)}"]
        end
        s.headers.each do |(n, v)|
          # A NUL truncates a shell argument (zsh silently, bash by refusing the line), so a
          # header carrying one is dropped and named rather than sent short. Same hole
          # `Curl.nul_header_note` covers.
          if n.to_slice.includes?(0_u8) || v.to_slice.includes?(0_u8)
            notes << "# header '#{n}' omitted: it holds a NUL no shell argument can carry — read the head with --format raw"
            next
          end
          # httpie's header item syntax is `Name:Value` (no space); the whole word is quoted so
          # a value's shell metacharacters cannot end the command.
          out << Curl.shell_quote("#{n}:#{v}")
        end
        unless s.body.empty?
          if s.body.to_slice.includes?(0_u8)
            notes << "# body omitted: #{s.body.bytesize} bytes holding a NUL no shell argument can carry — pipe it in instead: `... --raw < FILE` with --format raw"
          else
            # --raw sends the body verbatim, so httpie does not try to parse it as request items.
            out << "--raw #{Curl.shell_quote(s.body)}"
          end
        end
        # LAST, like curl's notes: a `#` comment swallows the ` \` that continues its line, so a
        # note earlier would truncate the command it annotates.
        out.concat(notes)
        out.join(" \\\n  ")
      end
    end
  end
end
