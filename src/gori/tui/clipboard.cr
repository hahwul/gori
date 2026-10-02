require "base64"
require "../settings"
require "./tty_out"
require "./register"

module Gori::Tui
  # System-clipboard access via the OSC 52 terminal escape. Unlike shelling out
  # to pbcopy/xclip/wl-copy, OSC 52 travels over the terminal itself — so it
  # works locally AND over SSH, with no platform dependency. That matches gori's
  # "any terminal, headless/SSH" stance.
  #
  # UNDER TMUX WE SEND BOTH FORMS, and that is the fix for a copy that reported
  # success and delivered nothing. This used to send ONLY the DCS-passthrough wrap
  # when `$TMUX` was set, on the reasoning that "tmux only forwards OSC 52 when
  # `set-clipboard on`". Both halves of that are off:
  #
  # - tmux parses a BARE OSC 52 itself, and `set-clipboard` defaults to `external`
  #   — which forwards it to the outer terminal (and `on` additionally fills tmux's
  #   own paste buffer). So the unwrapped sequence is the one that works by default.
  # - the DCS wrap is gated on `allow-passthrough`, which defaults to OFF (tmux 3.3+).
  #   With it off tmux DROPS the sequence outright — it is not forwarded, so nothing
  #   reaches the outer terminal and nothing reaches the clipboard. Measured by tapping
  #   a nested tmux's pane with `pipe-pane`: wrapped + passthrough off → zero `ESC]52`
  #   bytes out; wrapped + passthrough on → one.
  #
  # So the wrap replaced a path that works out of the box with one that is off out of
  # the box. Both go out now, in that order, and they cover disjoint configurations:
  # the bare one for default tmux, the wrapped one for `set-clipboard off` (where tmux
  # ignores the bare sequence) with passthrough enabled. A terminal that honours both
  # simply sets the same clipboard twice.
  module Clipboard
    # Ceiling on the copied payload: OSC 52 writes base64 of `data` straight to the
    # tty, so an unbounded copy (e.g. a multi-MB request/body) would flood the
    # terminal (and many terminals cap/refuse oversized OSC 52 anyway).
    MAX_CLIP = 64 * 1024

    # Builds the OSC 52 "set clipboard" sequence for `data` (base64-encoded).
    # When `tmux` is true, appends the DCS-passthrough copy of the SAME sequence —
    # appends rather than substitutes, see the module comment for why.
    def self.osc52(data : String, tmux : Bool = false) : String
      core = "\e]52;c;#{Base64.strict_encode(data)}\a"
      return core unless tmux
      # tmux passthrough: ESC P tmux; <ESC-doubled core> ESC \
      core + "\eP" + "tmux;" + core.gsub('\e', "\e\e") + "\e\\"
    end

    # Emits the sequence to the tty the TUI draws on (see `TtyOut` for why that is not
    # STDOUT). OSC 52 is state-neutral, so it does not disturb the cell grid — the next
    # diff render repaints normally.
    #
    # Returns the number of bytes actually placed on the clipboard (≤ MAX_CLIP), so
    # callers can compare against the source size and report when the copy was clipped.
    def self.copy(data : String, io : IO = TtyOut.io) : Int32
      # The paste register takes every copy first, whole and unscrubbed, and whether or not the
      # terminal clipboard is switched on: `p` puts back what was copied, so it must not depend
      # on OSC 52 or inherit its 64KB cap (see `Register`).
      Register.store(data)
      # Clipboard disabled by the user: write nothing to the tty, report 0 copied.
      return 0 unless Settings.clipboard_osc52?
      data = wire_safe(data)
      io.print(osc52(data, tmux: !ENV["TMUX"]?.nil?))
      io.flush
      data.bytesize
    end

    # What may actually go on the wire, and the reason a copy could report success and
    # deliver nothing even when the sequence DID reach the terminal.
    #
    # A terminal does not treat the OSC 52 payload as opaque bytes. It base64-decodes it
    # and then demands valid UTF-8 — wezterm `String::from_utf8(bytes)?` (the `Err` is
    # swallowed into an `Unspecified` command with a trace log), alacritty
    # `if let Ok(text) = String::from_utf8(bytes)`. Neither tells the user. So invalid
    # UTF-8 is not "harmless for a clipboard cap", it is a silently dropped copy, and
    # gori hits it two ways:
    #
    # - the source itself: a raw request/response dump is `String.new(bytes)` over
    #   whatever was on the wire, and a binary body is not UTF-8
    # - the cap: the old `byte_slice(0, MAX_CLIP)` severed a trailing codepoint, so
    #   ANY copy over 64KB containing non-ASCII text was dropped (measured: 30k Hangul
    #   characters clipped to 65536 bytes → invalid, clipboard untouched, toast claimed
    #   "copied 65536b — clipped from 90000b")
    #
    # Scrub first (the caller is told via `note`, since replacement bytes mean the
    # clipboard is no longer byte-exact evidence), then cap on a codepoint boundary so
    # the scrub cannot be undone by the clip.
    private def self.wire_safe(data : String) : String
      data = data.scrub unless data.valid_encoding?
      return data if data.bytesize <= MAX_CLIP
      bytes = data.to_slice
      cut = MAX_CLIP
      # Byte `cut` is the first one dropped. While it is a UTF-8 continuation byte
      # (0b10xxxxxx) the cut sits inside a character, so walk back onto its lead byte.
      # `data` is valid here, so this backs up at most 3 bytes.
      while cut > 0 && (bytes[cut] & 0xC0) == 0x80
        cut -= 1
      end
      data.byte_slice(0, cut)
    end

    # The status suffix for a copy, derived from what `copy` actually wrote versus the
    # SOURCE ITSELF. Callers append this instead of re-deriving the comparison
    # themselves: the `— clipped from Nb` half used to be hand-written at six call sites
    # and simply absent at five more, so `y` on a large selection reported the TRUNCATED
    # count as the copy size. One formula, one home — the omission can't recur
    # per-caller.
    #
    # Takes the source string rather than its byte count so the second caveat lives here
    # too. `wire_safe` scrubs invalid UTF-8 because the terminal would otherwise drop the
    # whole write, but that makes the clipboard a REPLACED copy of bytes gori captured
    # verbatim, and on this project malformed bytes are routinely the finding itself. A
    # copy that is not byte-exact has to say so; deriving it from `source` keeps every
    # caller out of the decision.
    #
    # A disabled clipboard is its own answer: `copy` returns 0 without touching the tty,
    # and "copied 0b" alone reads as an empty selection rather than a switched-off
    # setting. Empty source is not an error — it returns "".
    def self.note(written : Int32, source : String) : String
      source_bytes = source.bytesize
      return "" if source_bytes.zero?
      return " — clipboard is off (Settings → General)" if written.zero?
      notes = [] of String
      notes << "clipped from #{source_bytes}b (64KB cap)" if written < source_bytes
      notes << "not byte-exact (invalid UTF-8 replaced)" unless source.valid_encoding?
      notes.empty? ? "" : " — #{notes.join(" · ")}"
    end
  end
end
