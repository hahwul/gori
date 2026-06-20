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
        edited = normalize(File.read(file.path))
        edited == text ? Result.new(Outcome::Unchanged) : Result.new(Outcome::Changed, text: edited)
      rescue File::NotFoundError
        Result.new(Outcome::Failed, error: "editor not found: #{program}")
      rescue ex
        Result.new(Outcome::Failed, error: ex.message || "editor failed")
      ensure
        file.delete rescue nil
      end
    end

    # Editors append a final newline; TextArea.set_text would turn it into a
    # spurious empty last line. Strip exactly ONE trailing "\n" (or "\r\n").
    private def self.normalize(s : String) : String
      if s.ends_with?("\r\n")
        s[0, s.bytesize - 2]
      elsif s.ends_with?('\n')
        s.rchop
      else
        s
      end
    end
  end
end
