module Gori
  module Import
    # A POSIX-shell word splitter for a PASTED command line — the half of "paste a curl command"
    # (#1244) that has nothing to do with curl, kept apart so it can be tested on its own.
    #
    # It SPLITS and never runs anything: no parameter expansion, no globbing, no command
    # substitution. What it understands is exactly what the copy-as-cURL writers emit and what
    # a hand-typed command uses:
    #
    #   'single quotes'       literal to the next quote
    #   "double quotes"       `\` escapes only $ ` " \ and a newline (POSIX 2.2.3)
    #   \x                    outside quotes, the next byte literally
    #   \⏎                    a line continuation, removed (also inside double quotes)
    #   $'ansi-c'             `\n \t \xHH \uHHHH \NNN …` — Chrome's "Copy as cURL (bash)" emits
    #                         it for a value holding a non-printable or non-ASCII byte
    #   # comment             at the start of a word, to the end of the line — and
    #                         `Export::Curl` ends its commands in `# note` lines, so the round
    #                         trip needs this
    #   ; && || | & ⏎ ( )     end a simple command (Chrome's "Copy all as cURL" joins with ` ;⏎`)
    #   < > >> 2> …           a redirection: dropped together with its target word
    #
    # BYTE-WISE throughout, like `Export::Curl.shell_quote`: `$'\xff'` is one 0xFF byte, and a
    # Char walk would have turned it into the three bytes of U+FFFD.
    #
    # A `$VAR` stays literal (gori's own `$ENV.KEY` token is spelled that way and must reach the
    # Repeater intact). A `$(…)` or backtick is REFUSED instead: the operator's shell would have
    # run it and pasted its output, so keeping the text would store a request nobody sent.
    module Shell
      class Error < Gori::Error
      end

      # The text ENDS inside a quote. Its own class because it is the one refusal that means
      # "not finished yet" rather than "wrong": a paste box reads it the way an interactive shell
      # reads it, as a reason to keep taking lines (`incomplete?`).
      class Unterminated < Error
      end

      # One simple command: its words, and whether a redirection was dropped from it.
      record Command, words : Array(String), redirected : Bool = false

      # The simple commands in `text`, in order. Empty commands (a blank line, `;;`) are dropped.
      # Raises `Error` on an unterminated quote or a command substitution.
      def self.commands(text : String) : Array(Command)
        Splitter.new(text.to_slice).run
      end

      # Would an interactive shell wait for another line — the text ends in a `\` continuation,
      # or inside a quote? A paste box answers ↵ with a newline then, and runs the command
      # otherwise, which is the whole of a shell's PS2 rule.
      #
      # Asked of the splitter itself rather than of the text's last byte, so every rule it
      # already applies holds here too: `\\` is an escaped backslash, and a `\` inside a
      # `# comment` is part of the comment, not a continuation.
      def self.incomplete?(text : String) : Bool
        splitter = Splitter.new(text.to_slice)
        splitter.run
        splitter.dangling?
      rescue Unterminated
        true
      rescue Error
        false
      end

      # :nodoc:
      private class Splitter
        @word = IO::Memory.new
        @in_word = false
        @words = [] of String
        @redirected = false
        @skip_next_word = false
        @commands = [] of Command
        @i = 0
        # The text ended in an unquoted `\` with nothing after it: a continuation still waiting
        # for its next line (see `Shell.incomplete?`).
        getter? dangling = false

        def initialize(@bytes : Bytes)
        end

        def run : Array(Command)
          while @i < @bytes.size
            b = @bytes[@i]
            quoting(b) || structure(b) || add(b)
          end
          end_command
          @commands
        end

        # A byte that opens a quote or an escape. False when `b` is not one.
        private def quoting(b : UInt8) : Bool
          case b
          when 0x5c_u8 then unquoted_backslash # \
          when 0x27_u8 then single_quoted      # '
          when 0x22_u8                         # "
            @i += 1
            double_quoted
          when 0x24_u8 then dollar # $
          when 0x60_u8 then raise Error.new(substitution_refusal("`…`"))
          else              return false
          end
          true
        end

        # A byte that ends a word or a command, starts a redirection or a comment. False when
        # `b` is an ordinary word byte.
        private def structure(b : UInt8) : Bool
          case b
          when 0x20_u8, 0x09_u8, 0x0d_u8                            then end_word
          when 0x0a_u8, 0x3b_u8, 0x26_u8, 0x7c_u8, 0x28_u8, 0x29_u8 then end_command # ⏎ ; & | ( )
          when 0x3c_u8, 0x3e_u8                                                      # < >
            redirection
            return true
          when 0x23_u8 # #
            return false if @in_word
            comment
            return true
          else return false
          end
          @i += 1
          true
        end

        private def add(b : UInt8) : Nil
          @word.write_byte(b)
          @in_word = true
          @i += 1
        end

        # `\⏎` (or `\` CR LF, a Windows paste) continues the line; any other escaped byte is
        # itself. A trailing lone `\` is kept, as bash keeps it.
        private def unquoted_backslash : Nil
          nxt = @bytes[@i + 1]?
          if nxt == 0x0a_u8
            @i += 2
          elsif nxt == 0x0d_u8 && @bytes[@i + 2]? == 0x0a_u8
            @i += 3
          elsif nxt
            @word.write_byte(nxt)
            @in_word = true
            @i += 2
          else
            @dangling = true
            add(0x5c_u8)
          end
        end

        private def single_quoted : Nil
          close = @bytes.index(0x27_u8, @i + 1) || raise Unterminated.new("unterminated single quote (')")
          @word.write(@bytes[(@i + 1)...close])
          @in_word = true
          @i = close + 1
        end

        # Entered just past the opening `"`.
        private def double_quoted : Nil
          @in_word = true
          loop do
            b = @bytes[@i]? || raise Unterminated.new("unterminated double quote (\")")
            case b
            when 0x22_u8
              @i += 1
              return
            when 0x5c_u8
              nxt = @bytes[@i + 1]?
              case nxt
              when 0x0a_u8
                @i += 2
              when 0x0d_u8 # `\` CR LF — a continuation saved with Windows line ends
                if @bytes[@i + 2]? == 0x0a_u8
                  @i += 3
                else
                  @word.write_byte(b)
                  @i += 1
                end
              when 0x24_u8, 0x60_u8, 0x22_u8, 0x5c_u8
                @word.write_byte(@bytes[@i + 1])
                @i += 2
              else
                @word.write_byte(b)
                @i += 1
              end
            when 0x60_u8
              raise Error.new(substitution_refusal("`…`"))
            when 0x24_u8
              raise Error.new(substitution_refusal("$(…)")) if @bytes[@i + 1]? == 0x28_u8
              @word.write_byte(b)
              @i += 1
            else
              @word.write_byte(b)
              @i += 1
            end
          end
        end

        private def dollar : Nil
          case @bytes[@i + 1]?
          when 0x27_u8 # $'…'
            @i += 2
            ansi_c
          when 0x22_u8 # $"…" — a locale-translated string, which is a double-quoted one here
            @i += 2
            double_quoted
          when 0x28_u8
            raise Error.new(substitution_refusal("$(…)"))
          else
            add(0x24_u8)
          end
        end

        # Entered just past `$'`. Bash's escapes; a NUL ends the string there (bash drops the
        # rest of the quote, since an argument cannot carry one), so the tail is skipped to the
        # closing quote rather than written.
        private def ansi_c : Nil
          @in_word = true
          truncated = false
          loop do
            b = @bytes[@i]? || raise Unterminated.new("unterminated ANSI-C quote ($'…')")
            if b == 0x27_u8
              @i += 1
              return
            end
            if b != 0x5c_u8
              @word.write_byte(b) unless truncated
              @i += 1
              next
            end
            decoded = ansi_escape
            next if truncated
            if decoded.empty?
              truncated = true
            else
              @word.write(decoded)
            end
          end
        end

        # The one-letter escapes of `$'…'` and the byte each stands for.
        ANSI_SIMPLE = {
          'a' => 0x07_u8, 'b' => 0x08_u8, 'e' => 0x1b_u8, 'E' => 0x1b_u8, 'f' => 0x0c_u8,
          'n' => 0x0a_u8, 'r' => 0x0d_u8, 't' => 0x09_u8, 'v' => 0x0b_u8,
          '\\' => 0x5c_u8, '\'' => 0x27_u8, '"' => 0x22_u8, '?' => 0x3f_u8,
        }

        # The bytes one `\…` escape inside `$'…'` stands for, with `@i` moved past it. EMPTY
        # means a NUL — the end of the string.
        private def ansi_escape : Bytes
          c = @bytes[@i + 1]? || raise Unterminated.new("unterminated ANSI-C quote ($'…')")
          @i += 2
          ch = c.unsafe_chr
          if simple = ANSI_SIMPLE[ch]?
            return Bytes[simple]
          end
          case ch
          when 'x'      then (v = digits(16, 2)) ? byte_or_end(v) : "\\x".to_slice
          when 'u', 'U' then unicode_escape(ch)
          when 'c'      then control_escape
          when '0'..'7'
            @i -= 1
            byte_or_end((digits(8, 3) || 0_i64) & 0xff)
          else
            # An unknown escape is kept as written, backslash and all — bash's own behaviour.
            Bytes[0x5c_u8, c]
          end
        end

        # `\uHHHH` / `\UHHHHHHHH`: the code point as UTF-8; a surrogate or an out-of-range value
        # is kept as written.
        private def unicode_escape(ch : Char) : Bytes
          digits_start = @i
          value = digits(16, ch == 'u' ? 4 : 8)
          return "\\#{ch}".to_slice if value.nil?
          return Bytes.empty if value == 0
          return value.to_i32.chr.to_s.to_slice if value <= 0x10ffff && !(0xd800..0xdfff).includes?(value)
          @i = digits_start
          "\\#{ch}".to_slice
        end

        # `\cX`: the control character X & 0x1f.
        private def control_escape : Bytes
          ctl = @bytes[@i]? || return "\\c".to_slice
          @i += 1
          byte_or_end((ctl & 0x1f_u8).to_i64)
        end

        private def byte_or_end(value : Int64) : Bytes
          value == 0 ? Bytes.empty : Bytes[value.to_u8]
        end

        # Up to `max` digits in `base` at `@i`, consumed; nil when there is not even one.
        private def digits(base : Int32, max : Int32) : Int64?
          value = 0_i64
          count = 0
          while count < max && (b = @bytes[@i]?) && (d = b.chr.to_i?(base))
            value = value * base.to_i64 + d.to_i64
            count += 1
            @i += 1
          end
          count == 0 ? nil : value
        end

        # `>` `>>` `<` `2>` `&>`-style redirection: the operator and its target word are
        # dropped, and so is an all-digit word glued to its front (`2>` names a descriptor).
        private def redirection : Nil
          if @in_word && !@word.empty? && @word.to_slice.all? { |b| 0x30_u8 <= b <= 0x39_u8 }
            @word.clear
            @in_word = false
          end
          end_word
          while (b = @bytes[@i]?) && (b == 0x3c_u8 || b == 0x3e_u8 || b == 0x26_u8)
            @i += 1
          end
          @redirected = true
          @skip_next_word = true
        end

        private def comment : Nil
          while (b = @bytes[@i]?) && b != 0x0a_u8
            @i += 1
          end
        end

        private def end_word : Nil
          return unless @in_word
          word = String.new(@word.to_slice)
          @word.clear
          @in_word = false
          if @skip_next_word
            @skip_next_word = false
            return
          end
          @words << word
        end

        private def end_command : Nil
          end_word
          @skip_next_word = false
          @commands << Command.new(@words, @redirected) unless @words.empty?
          @words = [] of String
          @redirected = false
        end

        private def substitution_refusal(form : String) : String
          "the command uses a shell substitution (#{form}) — its output is what the shell would " \
          "have sent, and gori never runs a shell. Paste the command with the value filled in"
        end
      end
    end
  end
end
