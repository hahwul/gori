require "base64"

module Gori::Tui
  # System-clipboard access via the OSC 52 terminal escape. Unlike shelling out
  # to pbcopy/xclip/wl-copy, OSC 52 travels over the terminal itself — so it
  # works locally AND over SSH, with no platform dependency. That matches gori's
  # "any terminal, headless/SSH" stance.
  #
  # Caveat: tmux only forwards OSC 52 when `set-clipboard on`; we additionally
  # wrap the sequence in tmux's DCS passthrough when running inside tmux.
  module Clipboard
    # Builds the OSC 52 "set clipboard" sequence for `data` (base64-encoded).
    # When `tmux` is true, wraps it in the DCS passthrough so the outer terminal
    # receives it through tmux.
    def self.osc52(data : String, tmux : Bool = false) : String
      core = "\e]52;c;#{Base64.strict_encode(data)}\a"
      return core unless tmux
      # tmux passthrough: ESC P tmux; <ESC-doubled core> ESC \
      "\eP" + "tmux;" + core.gsub('\e', "\e\e") + "\e\\"
    end

    # Emits the sequence to the terminal. In TUI mode STDOUT is the controlling
    # tty (same device termisu draws to); OSC 52 is state-neutral, so it does not
    # disturb the cell grid — the next diff render repaints normally.
    def self.copy(data : String, io : IO = STDOUT) : Nil
      io.print(osc52(data, tmux: !ENV["TMUX"]?.nil?))
      io.flush
    end
  end
end
