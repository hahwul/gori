require "./screenshot/frame"
require "./screenshot/chrome"
require "./screenshot/svg"
require "./screenshot/ansi"
require "./screenshot/text"
require "./screenshot/mask"

module Gori
  # Turning a drawn TUI frame into something that leaves the terminal: an SVG or PNG picture,
  # a re-ingestable ANSI dump, or plain text.
  #
  # The seam is `Screenshot::Frame` — a grid of resolved cells plus the handful of facts a
  # renderer needs (canvas, ink, theme name, title, wrap marks). It is produced two ways and
  # consumed four, and keeping those apart is the whole design:
  #
  #   * `Tui::Backend#snapshot` builds one from what the terminal SHOWS after the last flush.
  #   * `Frame.from_ansi` (`screenshot/ingest.cr`) builds one from a `tmux capture-pane -e -p`
  #     style dump, which is how a screenshot can be taken of a gori that is not this process.
  #   * `Svg`, `Png`, `Ansi` and `Text` render one. None of them knows the TUI exists.
  #
  # `Mask` sits between: given the project's redaction matcher it rewrites cells in place, so
  # a screenshot of a live engagement can be published without the secrets that were on the
  # screen. It is the only consumer that reads `Frame#continuations`, because a secret can be
  # soft-wrapped across two screen rows and neither half matches on its own.
  #
  # `screenshot/ingest.cr` is required separately, AFTER `./gori/tui`: it is the one file here
  # that touches `Gori::Tui` (for the SGR parser), and keeping it out of this file is what
  # lets every other file in the subsystem stay surface-free.
  module Screenshot
  end
end
