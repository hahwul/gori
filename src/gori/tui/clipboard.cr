require "base64"
require "../settings"

module Gori::Tui
  # System-clipboard access via the OSC 52 terminal escape. Unlike shelling out
  # to pbcopy/xclip/wl-copy, OSC 52 travels over the terminal itself — so it
  # works locally AND over SSH, with no platform dependency. That matches gori's
  # "any terminal, headless/SSH" stance.
  #
  # Caveat: tmux only forwards OSC 52 when `set-clipboard on`; we additionally
  # wrap the sequence in tmux's DCS passthrough when running inside tmux.
  module Clipboard
    # Ceiling on the copied payload: OSC 52 writes base64 of `data` straight to the
    # tty, so an unbounded copy (e.g. a multi-MB request/body) would flood the
    # terminal (and many terminals cap/refuse oversized OSC 52 anyway).
    MAX_CLIP = 64 * 1024

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
    #
    # Returns the number of bytes actually placed on the clipboard (≤ MAX_CLIP), so
    # callers can compare against the source size and report when the copy was clipped.
    def self.copy(data : String, io : IO = STDOUT) : Int32
      # Clipboard disabled by the user: write nothing to the tty, report 0 copied.
      return 0 unless Settings.clipboard_osc52?
      # Clip by BYTES (not chars): MAX_CLIP bounds the OSC 52 tty write, and the
      # returned count is a byte count the caller compares to the source byte size.
      # `byte_slice` may sever a trailing multi-byte codepoint, but the sequence is
      # base64-encoded from the raw bytes, so that's harmless for a clipboard cap.
      data = data.byte_slice(0, MAX_CLIP) if data.bytesize > MAX_CLIP
      io.print(osc52(data, tmux: !ENV["TMUX"]?.nil?))
      io.flush
      data.bytesize
    end
  end
end
