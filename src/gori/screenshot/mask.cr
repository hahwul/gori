# STUB — replaced wholesale by the W1a core package at merge; keep in sync with the Mask contract
require "./frame"
require "../redact/matcher"

module Gori::Screenshot
  # Redaction over a captured frame: the same project redaction profile the copy-as menu
  # applies, re-applied to the GLYPHS, so a screenshot of a pane showing a session token does
  # not ship the token. W1a owns the real implementation; until it lands this is the identity
  # so the call stays wired at its one site (`Tui::Headless.render`) rather than being added
  # later to a path nobody re-reads.
  module Mask
    def self.apply(frame : Frame, matcher : Gori::Redact::Matcher?) : Frame
      frame
    end
  end
end
