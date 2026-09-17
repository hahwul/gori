require "./screenshot/frame"
require "./screenshot/chrome"
require "./screenshot/svg"
require "./screenshot/font"
require "./screenshot/png"
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
    # What to call the file, when the operator (or the agent) did not say.
    #
    # It lives HERE and not in either surface because both `gori run screenshot` and the MCP
    # `screenshot` tool write into the same `<GORI_HOME>/screenshots` directory: two spellings
    # of the convention would drift, and the directory an operator browses would then be sorted
    # by two different rules. Pure, and surface-free like everything else in this file.
    #
    # The tab segment is omitted when no tab was asked for: the shot is then of whatever tab
    # the project opens on, and naming one would be a claim the file cannot back.
    def self.suggest_filename(slug : String, tab : String?, ext : String, at : Time) : String
      stamp = at.to_s("%Y%m%d-%H%M%S")
      tab ? "#{slug}-#{tab}-#{stamp}.#{ext}" : "#{slug}-#{stamp}.#{ext}"
    end

    # A project name as a filename component: lowercased, everything outside `[a-z0-9._-]`
    # folded to a single dash, and never empty. Deliberately NOT `ProjectRegistry#slugify` —
    # that one is the DIRECTORY spelling and is private to the registry, and a picture's name
    # is allowed to differ from the directory the project lives in.
    def self.slug(name : String) : String
      s = name.downcase.gsub(/[^a-z0-9._-]+/, "-").strip('-')
      s.empty? ? "gori" : s
    end
  end
end
