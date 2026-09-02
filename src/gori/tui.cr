require "termisu"

module Gori
  # The terminal UI, built directly on termisu's cell buffer. termisu provides
  # only cells (no widgets/layout), so we supply a tiny immediate-mode drawing
  # layer (Screen) and redraw from state each frame. Rendering goes through a
  # Backend so views can be unit-tested without a real TTY.
  module Tui
    alias Color = Termisu::Color
    alias Attribute = Termisu::Attribute

    # Construct the terminal, turning the "no controlling terminal" failure into a clean
    # message instead of a raw backtrace. Termisu opens /dev/tty directly (independent of
    # STDIN/STDOUT redirection), and raises when there is none — CI, or a detached /
    # background job. `hint` tails the message with how to run interactively. Every
    # interactive entrypoint (the TUI and `gori wizard`) goes through here so the guard
    # lives at the one shared construction point.
    def self.open_terminal(hint : String) : Termisu
      bind_log_file
      with_termisu_logging_silenced { Termisu.new }
    rescue IO::Error
      abort "gori: requires an interactive terminal (no /dev/tty) — #{hint}"
    end

    # The one fd every entrypoint's records go to, and the binding that keeps them OFF the
    # screen. Called here, before the terminal exists, because the terminal's own constructor
    # already logs.
    #
    # Crystal's default `::Log` backend is `Log::IOBackend.new`, whose io is **STDOUT** — which
    # under a TUI is the screen being drawn. termisu emits three INFO records inside
    # `Termisu.new` alone, and it used to hide that by seizing the root binding for its own file
    # (see `with_termisu_logging_silenced`). Taking that away without putting gori's binding in
    # its place painted those records into the first frame: measured, `gori tutorial` opened
    # with "Initializing Termisu v0.6.1" written across its own tour chrome. `App#run_tui` had
    # always bound first and was fine; `gori wizard` and `gori tutorial` reach a terminal
    # without ever calling it, which is why the binding belongs at the SHARED construction
    # point rather than in one caller.
    #
    # The io is memoized and the binding re-applied on every call: three entrypoints share one
    # fd, and a caller that re-asserts after something else has had its say (App#run_tui does)
    # costs nothing.
    def self.bind_log_file : Nil
      io = (@@log_io ||= File.open(File.join(Gori::Paths.home_dir, "gori.log"), "a"))
      ::Log.setup(:info, ::Log::IOBackend.new(io))
    rescue
      # No writable log file (a read-only or missing home). Silence is the only other safe
      # answer: the default backend writes to STDOUT, and a diagnostic that lands on the
      # alternate screen is worse than one nobody keeps (#411).
      ::Log.setup(:none)
    end

    @@log_io : File? = nil

    # The ONE place the persisted language choice becomes the live one. TUI-only by design:
    # neither `gori run` nor `gori mcp` calls it, so their output stays English whatever the
    # operator picked, and a core module that phrases a sentence through `I18n` (a peer
    # notice, say) is still English on the headless surfaces. Returns I18n.apply's
    # "something changed" verdict; a re-assert is free.
    def self.apply_language : Bool
      I18n.apply(Settings.language_default, Settings.language_overrides)
    end

    # Keep the terminal library out of `/tmp`, for the length of its constructor and no longer.
    #
    # `Termisu.new` unconditionally runs `Termisu::Logging.setup`, and with nothing in the
    # environment that opens `/tmp/termisu.log` in append mode and rebinds the process-wide root
    # logger to it at DEBUG. Three things follow from that, none of them gori's intent:
    #
    #   - a path in a world-writable directory is opened BY NAME on every launch, and
    #     `File.open(path, "a")` follows a symlink. On a shared box anyone can pre-create
    #     `/tmp/termisu.log` pointing at a file this user can write and collect gori's records
    #     there. gori keeps its own tree at 0700/0600 to avoid exactly this shape.
    #   - the file is world-readable and never rotated, and every launch appends the terminal
    #     setup trace to it — measured, ~10 lines per run — so it doubles as an unowned record
    #     that this user runs gori, growing without bound.
    #   - `::Log.setup("*", …)` CLEARS prior bindings, so it would drop what `bind_log_file`
    #     just installed.
    #
    # `TERMISU_LOG_LEVEL=none` is termisu's own switch for all three: it marks logging
    # configured and returns BEFORE opening the file or touching `::Log`.
    #
    # SET AND RESTORED around the call rather than left in place. `ENV[]=` is `setenv(3)` for
    # the whole process, and Crystal hands the parent environment to every child by default —
    # so leaving it set exports gori's preference to the statusline's `sh -c`, to `$EDITOR`,
    # and to the external process hooks (#818). A user debugging a termisu app from inside gori
    # would have had its logging silenced with nothing to point at. An operator who set the
    # variable themselves keeps their setting untouched: termisu's records then land in
    # gori.log, since `bind_log_file` above ran first and termisu's `Log.setup` re-points the
    # root at its own file only when it actually configures one.
    private def self.with_termisu_logging_silenced(&)
      key = "TERMISU_LOG_LEVEL"
      return yield if ENV.has_key?(key)
      ENV[key] = "none"
      begin
        yield
      ensure
        ENV.delete(key)
      end
    end
  end
end

require "./tui/input_idle_backoff_patch" # carried termisu patch — see the file
require "./tui/geometry"
require "./tui/theme"
require "./tui/screen"
require "./tui/frame"
require "./tui/brand"
require "./tui/highlight"
require "./tui/ansi"
require "./tui/tty_out"
require "./tui/mouse_drag"
require "./tui/resource"
require "./tui/layout"
require "./tui/chrome"
