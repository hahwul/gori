require "./settings"

module Gori
  # Opens text in the user's external editor (^E in the multi-line fields). Pure:
  # temp-file lifecycle + read-back/normalize. The terminal handoff (suspend +
  # Process.run) lives in the Runner, which owns @term; this module is handed the
  # spawned Process::Status via the block.
  module ExternalEditor
    enum Outcome
      Changed
      Unchanged
      Failed
    end

    record Result, outcome : Outcome, text : String? = nil, error : String? = nil

    # A syntax-hint suffix for the temp file, so the editor lights it up sensibly.
    def self.suffix_for(kind : Symbol) : String
      case kind
      when :request, :intercept then ".http"
      when :notes, :desc        then ".md"
      when :json                then ".json"
      else                           ".txt"
      end
    end

    # Write `text` to a temp file, hand {program, args+path} to the block (which
    # runs the editor and returns its Process::Status), then read back + normalize.
    # Cleans up the temp file in all paths. Never raises.
    def self.edit(text : String, kind : Symbol,
                  & : (String, Array(String)) -> Process::Status?) : Result
      cmd = Settings.editor_command
      program = cmd[0]
      file = File.tempfile("gori-edit", suffix_for(kind))
      begin
        File.write(file.path, text)
        status = yield program, cmd[1..] + [file.path]
        unless status && status.success?
          return Result.new(Outcome::Failed,
            error: status ? "editor exited #{status.exit_code}" : "editor did not run")
        end
        edited = normalize(File.read(file.path), text, kind)
        edited == text ? Result.new(Outcome::Unchanged) : Result.new(Outcome::Changed, text: edited)
      rescue File::NotFoundError
        Result.new(Outcome::Failed, error: "editor not found: #{program}")
      rescue ex
        Result.new(Outcome::Failed, error: ex.message || "editor failed")
      ensure
        file.delete rescue nil
      end
    end

    # The kinds whose text is WIRE BYTES rather than prose: a request template, an
    # intercepted message. Byte-exactness on the operator's own input is a P0 invariant here
    # (DESIGN.md), and it is not one for a note or a project description.
    WIRE_KINDS = {:request, :intercept}

    # Undo the newline an editor appends at end-of-file, without touching one the operator
    # meant. Both halves of that matter and the old rule only had one.
    #
    # The old rule stripped exactly one trailing newline UNCONDITIONALLY, because editors add
    # one and `TextArea.set_text` would otherwise show a spurious empty last line. On prose
    # that is right and stays. On a REQUEST it is a silent mutation of operator bytes: a body
    # that genuinely ends in CRLF came back two bytes shorter and the declared
    # `Content-Length: 34` no longer matched the 32 bytes sent — the exact desync a smuggling
    # test is trying to CAUSE deliberately, arriving by accident.
    #
    # Split by CALLER, as the `kind` argument already distinguishes them, rather than changed
    # globally: for a wire kind the strip is CONDITIONAL on the original not having ended in a
    # newline, which is precisely "remove what the editor's ensure-newline-at-EOF added, and
    # nothing else". Removing the strip outright would have been the mirror-image defect —
    # a request that ended WITHOUT a newline would silently gain one.
    private def self.normalize(edited : String, original : String, kind : Symbol) : String
      return edited if WIRE_KINDS.includes?(kind) && original.ends_with?('\n')
      chop_newline(edited)
    end

    # Strip exactly ONE trailing "\n" (or "\r\n").
    private def self.chop_newline(s : String) : String
      if s.ends_with?("\r\n")
        s.rchop.rchop # two single-byte ASCII chars; rchop avoids byte-vs-char arithmetic
      elsif s.ends_with?('\n')
        s.rchop
      else
        s
      end
    end
  end
end
