module Gori
  # Turning wire bytes into a String a PCRE2 subject can be run over, without paying for the
  # repair on the bodies that do not need one.
  #
  # `String.new` validates NOTHING, and a `Regex` over invalid UTF-8 does not simply fail to
  # match — PCRE2 RAISES `ArgumentError: UTF-8 error: illegal byte`, which on a fuzz worker or
  # a proxy hold gate is a dead fiber, not a false negative. So a scrub is mandatory before any
  # regex touches a captured body.
  #
  # `String#scrub` is the obvious spelling and the expensive one: it walks the whole string a
  # CHARACTER at a time through a `Char::Reader` and returns `self` at the end, so a body that
  # was already valid — which is nearly all of them — pays the full decode to be told there was
  # nothing to fix. `String#valid_encoding?` answers the same question with `Unicode.valid?`, an
  # unrolled DFA over the raw bytes. Measured on a valid 216 KB response body: 681µs for
  # `scrub`, 81µs for `valid_encoding?` — 8.4x, per response, on every path that sets a regex.
  #
  # So: ask the cheap question first, and scrub only what needs it. An invalid body re-walks
  # (`valid_encoding?` then `scrub`), which is the right trade at roughly one body in a run.
  #
  # This lived as a private helper inside `Discover::Extract` while the fuzz matcher and the
  # intercept filter each carried the slow spelling; one home is what keeps the reasoning
  # attached to every caller.
  module Utf8
    # A response/message body as a String safe to hand to PCRE2.
    def self.text(bytes : Bytes) : String
      subject(String.new(bytes))
    end

    # The same guarantee for a String that already exists — a haystack assembled from wire
    # bytes somewhere upstream. Returns `str` itself when it is already valid, so the common
    # path allocates nothing at all.
    def self.subject(str : String) : String
      str.valid_encoding? ? str : str.scrub
    end
  end
end
