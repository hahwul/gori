require "./screen"
require "./theme"
require "../store"

module Gori::Tui
  # How an issue's severity, triage status and source flow render in a list row — shared by
  # the Issues tab and the Probe tab, which list the same `Store` records through different
  # lenses (hand-filed vs rule-found).
  #
  # These were duplicated across the two views, which is exactly the wrong place for them:
  # the whole point of the colour ladder below is that CRIT looks the same wherever an
  # operator meets it, and two copies of the mapping is a promise the code cannot keep.
  module IssuePresentation
    # Four columns between the badge and the title (IssuesView `title_x`), so `resolved`
    # itself does not fit; `res` is its abbreviation the way `conf` is `confirmed`. It used to
    # read `done`, a word no other surface uses for this status — the picker, the detail, the
    # Evidence tab, the CLI, MCP and the export all say `resolved`.
    private def status_tag(s : Store::Status) : String
      case s
      when .confirmed?      then "conf"
      when .false_positive? then "fp"
      when .resolved?       then "res"
      else                       "open"
      end
    end

    private def status_color(s : Store::Status) : Color
      # SEVERITY owns the colour ladder on these rows; triage status does not compete for it.
      # The two were drawn five columns apart out of the SAME hues — `CRIT conf` was two reds
      # meaning two different axes, `LOW open` two accents — on a list whose whole job is
      # "scan for red". The four words (conf / fp / res / open) already tell the statuses
      # apart, so what is left for colour here is the one distinction the WORDS do not make
      # at a glance: still live, or already handled.
      case s
      when .false_positive?, .resolved? then Theme.muted
      else                                   Theme.text # open
      end
    end

    private def severity_badge(s : Store::Severity) : String
      case s
      when .critical? then "CRIT"
      when .high?     then "HIGH"
      when .medium?   then "MED"
      when .low?      then "LOW"
      else                 "INFO"
      end
    end

    private def severity_color(s : Store::Severity) : Color
      case s
      when .critical? then Theme.red
      when .high?     then Theme.orange
      when .medium?   then Theme.yellow
      when .low?      then Theme.accent
      else                 Theme.muted
      end
    end

    # An absolute-form target ("GET http://h/p") already carries the host, so don't
    # prepend it again; origin-form ("/p") gets the host prefixed. That is exactly
    # `Url.location` — re-deriving it as `starts_with?("http")` called `httpbin.org/x`
    # absolute and dropped the host, and missed `HTTP://` (schemes are case-insensitive)
    # so an uppercase target rendered doubled as `a.testHTTP://a.test/x`.
    private def flow_location(f : Store::FlowRow) : String
      Gori::Url.location(f.host, f.target)
    end
  end
end
