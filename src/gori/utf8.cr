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

    # The compile option `tolerant` adds: PCRE2_MATCH_INVALID_UTF, or nothing where it is not
    # safe to use. It was introduced in PCRE2 10.34 and could loop forever until 10.36; the
    # legacy PCRE1 engine (`-Duse_pcre` / `USE_PCRE1`) rejects it outright. Every package gori
    # ships links a newer PCRE2 (Alpine for the static builds, Ubuntu 24.04 for the snap,
    # Homebrew, nixpkgs), so the fallback only covers a hand-built binary — which then keeps
    # today's validate-per-match behaviour instead of failing to boot.
    TOLERANT_OPTION =
      {% if flag?(:use_pcre) || !(env("USE_PCRE1") || "").empty? %}
        Regex::CompileOptions::None
      {% else %}
        begin
          major, minor = Regex::PCRE2.version_number
          major > 10 || (major == 10 && minor >= 36) ? Regex::CompileOptions::MATCH_INVALID_UTF : Regex::CompileOptions::None
        end
      {% end %}

    # A rule regex that is run over body-sized text, recompiled so PCRE2 does not validate
    # the whole subject as UTF-8 on every call.
    #
    # Without it, each `matches?` / `match` walks the ENTIRE subject once before matching, even
    # when the pattern's literal prefix would have skipped the body in memchr time — and a
    # passive scan runs dozens of patterns over the same 64-256 KiB body. A `sample` of `gori
    # run probe` put ~80% of its time in `_pcre2_valid_utf_8`. The subjects are already repaired
    # (`text` / `subject` above), so every one of those walks answered a settled question.
    #
    # MATCH_INVALID_UTF is the safe way to skip it, where a per-call `NO_UTF_CHECK` is not: that
    # one is undefined behaviour on an invalid subject, while this one still matches it memory-
    # safely (invalid bytes simply never match). A caller that forgets to repair gets a miss
    # where the default would have raised. On valid UTF-8 — every subject the callers hand it —
    # matching is unchanged.
    def self.tolerant(rx : Regex) : Regex
      return rx if TOLERANT_OPTION == Regex::CompileOptions::None
      Regex.new(rx.source, rx.options | TOLERANT_OPTION)
    end

    # The optional prefilter slot of a rule table.
    def self.tolerant(rx : Nil) : Nil
      nil
    end
  end
end
