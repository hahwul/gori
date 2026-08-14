require "./screen"
require "./theme"
require "../ql"

module Gori::Tui
  # The completion row under a filter bar: what Tab would take, what it MEANS, and what else is
  # on offer — plus the standing hints that stand in when there is nothing to complete.
  #
  # It exists because the row used to be one muted string per surface (`"↹ #{sugg.first(8)…}"`,
  # copied five times) and the hints beside it were hand-written prose (copied three times, and
  # disagreeing: History's listed `AND OR NOT` and not `-`, Intercept's listed both, Sitemap's and
  # Issues' listed neither). A filter bar is where this language is LEARNED — it is the only place
  # most operators ever see the grammar — so the row that teaches it should not be the part of the
  # codebase most likely to be stale.
  #
  # Two things the flat row could never say, and this one does:
  #
  #   * WHICH candidate Tab takes. Every surface splices `sugg.first` and every surface painted
  #     all eight identically, so the row showed the outcome of pressing Tab nowhere in it.
  #   * WHAT the candidate means. `resp.body:` is not self-describing, and a field pool can only
  #     ever list names — the meanings live in `QL::FIELD_HELP`, beside the parser that implements
  #     them, and are read from there rather than restated here.
  module QuerySuggest
    MAX_SHOWN = 8

    # The default help source, hoisted out of the parameter lists below: a default argument that
    # is a literal proc allocates a fresh closure on EVERY call, and these run on the draw path.
    QL_HELP = ->(f : String) { QL.field_help(f) }

    # The boolean operators, offered as completion candidates. A field pool can only ever list
    # field names, so `NOT` and `OR` had no completion at all: typing `N` matched nothing and the
    # row went blank under the "deliberately free-texting a word" policy. They lived only in the
    # standing hint, which disappears the moment you type — so the grammar's two most useful
    # spellings were reachable only by already knowing them.
    #
    # `NOT (` matters most and is the reason this exists: `-` negates a TERM and cannot negate a
    # GROUP, so `NOT ( … )` is the only way to exclude a disjunction and it was the one form with
    # zero discovery. The trailing `(` is part of the candidate because the shape is the lesson.
    #
    # Matched CASE-SENSITIVELY, which is not a detail: `FilterAst` recognises these uppercase and
    # unquoted only, precisely so searching for the words "and"/"or"/"not" still works. Offering
    # `NOT (` for a typed `n` would advertise an operator that would compile as free text. No QL
    # field begins with n/o/a either, so an uppercase prefix collides with nothing.
    OPERATORS = {
      "NOT (" => "excludes a whole group — close with )",
      "OR"    => "either side matches",
      "AND"   => "both match — the same as a space",
    }

    # `candidates` plus any operator the typed token could still become. Appended AFTER the field
    # candidates so a field never loses its slot; in practice the two sets never overlap.
    #
    # Takes the whole `Cursor`, not just `core`, because completion SPLICES OVER the token's full
    # span — punctuation included. A bare `"OR"` spliced over `(O` deletes the opening paren and
    # silently dissolves the group the operator was being typed to build, so an operator candidate
    # has to carry `cur.prefix` exactly as a field candidate does.
    #
    # And a `-` in that prefix disqualifies operators outright rather than carrying: `-NOT (`
    # lexes as one WORD (`word_tok` tests the whole chunk, which is not `NOT`), so offering it
    # would complete a token the grammar reads as free text — the very thing the case-sensitive
    # match above exists to prevent.
    def self.with_operators(candidates : Array(String), cur : Gori::FilterAst::Cursor) : Array(String)
      return candidates if cur.core.empty? || cur.prefix.includes?('-')
      candidates + OPERATORS.keys.select(&.starts_with?(cur.core)).map { |op| "#{cur.prefix}#{op}" }
    end

    # Should a standing hint stand in for an empty candidate list? A blank row is the deliberate
    # answer to a non-empty token nothing matches — the human is free-texting a word — but a lone
    # `-` is not a word, it is an operator mid-typing, and blanking there removed all guidance at
    # the exact keystroke where the operator committed to an exclusion. `FilterAst.token_at`
    # cannot help: it peels a `-` into the token prefix only when something follows it, so a bare
    # dash arrives as `core` and looks like free text.
    def self.hint_slot?(core : String) : Bool
      core.empty? || core == "-"
    end

    # Draw the row at (x, y) within `w` columns. `suggestions` is the surface's candidate list,
    # already in Tab order — the first entry is what Tab splices, so it is the one painted bright
    # and the one described. Returns nothing; a caller with no candidates should draw a hint
    # instead (see `cold_hint`), or nothing at all when the token is a deliberate free-text word.
    # `help` is the BACKEND's explanation of a field name, not QL's by assumption: the grammar is
    # shared and the semantics are not. `body:` at a hold gate reads the bytes in hand, so QL's
    # "via index: 8 KiB/side, no compressed" would be a confident lie on the Intercept bar — see
    # `InterceptFilter::FIELD_HELP`. Defaulting to QL keeps the store-backed surfaces (History,
    # Sitemap, colour rules) on one line of wiring.
    def self.render(screen : Screen, x : Int32, y : Int32, w : Int32,
                    suggestions : Array(String),
                    help : Proc(String, String?) = QL_HELP) : Nil
      return if suggestions.empty? || w <= 2
      right = x + w
      cx = screen.text(x, y, "↹ ", Theme.muted, width: w)
      head = suggestions.first
      cx = screen.text(cx, y, head, Theme.text_bright, width: {right - cx, 0}.max)

      # POLARITY, in its own colour, before the meaning. A negated candidate used to render
      # byte-identically to its positive twin apart from one leading `-`: `-host:` said
      # "server host — substring", the same sentence `host:` said, so the row explaining the
      # field never mentioned the half the operator had just chosen. On a VALUE list
      # (`-method:GET  -method:POST …`) it matters more, not less — the eye is on the values and
      # the dash is four characters behind them.
      if negated?(head)
        cx = screen.text(cx, y, "  excludes", Theme.focus_gold, width: {right - cx, 0}.max)
      end

      # The meaning, but only while completing a FIELD NAME. On a value list the candidates
      # already are the explanation, and spending the row on "exact method — GET POST PUT …"
      # would push the values themselves off a narrow bar.
      if why = describe_for(head, help)
        cx = screen.text(cx, y, "  #{why}", Theme.muted, width: {right - cx, 0}.max)
      end

      rest = suggestions[1, MAX_SHOWN - 1]? || [] of String
      return if cx >= right
      # The also-rans, then the affordance for the roomier view. `↓ list` is the only place the
      # dropdown announces itself — it is opt-in, so nothing else would ever mention it — and it
      # goes LAST because it is the least urgent thing on the row and the first that should be
      # truncated away on a narrow bar.
      tail = rest.empty? ? "" : "   #{rest.join("  ")}"
      screen.text(cx, y, "#{tail}   ↓ list", Theme.muted, width: {right - cx, 0}.max)
    end

    # `render` as one flat string, for a caller that paints a single band rather than a bar row
    # (the colour-rule overlay fills its own background first). Loses the bright/muted split — so
    # "what Tab takes" is carried by position alone — but keeps the description, which is the part
    # a modal with no room for a second row most needs.
    def self.line(suggestions : Array(String),
                  help : Proc(String, String?) = QL_HELP) : String
      return "" if suggestions.empty?
      head = suggestions.first
      why = describe_for(head, help)
      rest = suggestions[1, MAX_SHOWN - 1]? || [] of String
      String.build do |io|
        io << "↹ " << head
        io << "  ·  excludes" if negated?(head)
        io << "  ·  " << why if why
        io << "   " << rest.join("  ") unless rest.empty?
      end
    end

    # Is this candidate an EXCLUSION? Reads the grammar's own rule rather than "starts with a
    # dash": `FilterAst` negates on a leading unquoted `-` that has something after it, and a
    # candidate may carry an opening paren in front of it (`(-host:`).
    def self.negated?(candidate : String) : Bool
      core = candidate.lstrip('(')
      core.starts_with?('-') && core.size > 1
    end

    # The one-line meaning of a candidate, or nil when it speaks for itself. A field NAME gets the
    # BACKEND's explanation; an operator gets ours (a backend has no opinion about `OR` — it is
    # `FilterAst`'s, shared by every surface); a VALUE gets none, because the candidate list beside
    # it already is the explanation. Read by the inline row (for the one candidate Tab would take)
    # and by the dropdown (for every row, which is the reason a row each is worth the occlusion).
    def self.describe_for(candidate : String, help : Proc(String, String?)) : String?
      return OPERATORS[candidate]? if OPERATORS.has_key?(candidate)
      candidate.ends_with?(':') ? help.call(field_of(candidate)) : nil
    end

    # The field name inside a candidate, with the grammar's punctuation peeled off — `(-resp.body:`
    # is the field `resp.body`. Mirrors what `FilterAst::Cursor#prefix` carries, so a candidate
    # produced under a negation or inside a group still finds its help entry.
    def self.field_of(candidate : String) : String
      core = candidate.lstrip('(').lstrip('-')
      sep = core.index(':') || core.index('~')
      sep ? core[0...sep] : core
    end

    # The row shown while EDITING with nothing to complete yet — a cold start, or the caret just
    # after a space. Fields lead (they are the vocabulary, and two specs assert a bar names them),
    # but `-term excludes` sits immediately after them rather than at the end: the operators are
    # the half a completion pool can NEVER reveal — you discover `host:` by typing `h` and pressing
    # Tab, and you discover `-` only by being told — so they must survive an 80-column truncation.
    # That is what caps `fields` at a handful; see `QL::HINT_FIELDS`.
    #
    # `width`, when given, is the caller's real column budget and the sample SHRINKS to fit it —
    # dropping field chips one at a time until `-term excludes` lands inside the row. Without it
    # the operators are simply first-after-the-fields and the terminal truncates whatever spills,
    # which is right for a full-width bar and wrong for a 68-column modal band (the colour-rule
    # form), where a fixed six-chip sample pushed the negation off the end entirely — on the one
    # surface where the mistake it prevents becomes a standing rule rather than a re-typed query.
    # `note` is a backend-specific clause no generator over a field list could produce (Intercept's
    # `proto:ws` opt-in). It goes INSIDE `compose` rather than being appended by the caller: an
    # appended note lands past the operator tail, which is already ~120 columns, so it was
    # permanently truncated on every real terminal — and the shrink below can only protect what it
    # composes itself.
    # `help_key` advertises the `?`-opens-the-QL-reference affordance (TabController#ql_help_key?).
    # A flag rather than always-on, because `cold_hint` also dresses the Colormarker rule form's
    # `when:` band — a plain text field where `?` types a `?`. An unconditional chip would make
    # this generator advertise a key on a surface that does not have it, which is the exact
    # failure the hand-written FILTER_HINT/QUERY_HINT pair was replaced for.
    def self.cold_hint(fields : Array(String) = QL::HINT_FIELDS, width : Int32? = nil,
                       note : String? = nil, help_key : Bool = false) : String
      n = {fields.size, HINT_MAX}.min
      loop do
        line = compose(fields.first(n), note, help_key)
        return line if width.nil? || n == 0 || fits?(line, width)
        n -= 1
      end
    end

    # `>= <` earns its place beside the operators: the old hand-written hints carried example
    # VALUES (`status:>=500`, `dur:>500`, `size:>10000`) as syntax cues, and generating from a
    # field-name pool dropped every one of them. Completion cannot teach comparison either — Tab
    # offers names until a `:` is typed — so without this nothing on the bar shows that `status:`
    # takes an operator at all.
    private def self.compose(fields : Array(String), note : String? = nil,
                             help_key : Bool = false) : String
      # AFTER `-term excludes`, not before it. Leading with the chip read better and was wrong:
      # it is 16 columns, and `fits?` below protects `-term excludes` by INDEX, so putting
      # anything ahead of that token pushes it right on every surface at once — measured, it
      # moved from column 78 to 94 on History, newly cutting it off on any terminal 84-99 wide.
      # None of the three bars passes `width`, so the shrink loop cannot claw that back either.
      #
      # Behind it, every pre-existing token sits exactly where it did, and the new chip takes
      # its chances with the tail — which is the right trade: a new affordance must not cost an
      # existing one its place.
      help = help_key ? "? reference  ·  " : ""
      chips = fields.empty? ? "" : "fields: #{sample(fields)}  ·  "
      tail = note ? "#{note}  ·  " : ""
      "#{chips}-term excludes  ·  #{help}#{tail}OR NOT ( ) group  ·  ~regex  ·  >= < on status size dur"
    end

    # Does the operator that matters survive this width? Not "does the whole line fit" — the tail
    # is meant to be truncated. `-term excludes` is the one piece a completion pool can never
    # teach, so it is the one the shrink loop protects.
    private def self.fits?(line : String, width : Int32) : Bool
      idx = line.index("-term excludes")
      !idx.nil? && idx + "-term excludes".size <= width
    end

    # The row shown on the IDLE bar, before the filter is even open. Shorter than `cold_hint` —
    # it shares the line with the row count — and still names the negation, which is the one piece
    # of the grammar an operator reported not being able to find.
    def self.idle_hint(prefix : String, fields : Array(String) = QL::HINT_FIELDS) : String
      "#{prefix}  ·  #{sample(fields)}  ·  -term excludes  ·  AND OR NOT ( )"
    end

    # `fields` as `name:` chips. Capped rather than trusted: a caller may hand over its whole pool
    # (the colour-rule overlay's is eighteen names long), and an uncapped sample would push the
    # operator tail past the right edge of every bar in the app.
    HINT_MAX = 6

    private def self.sample(fields : Array(String)) : String
      fields.first(HINT_MAX).map { |f| "#{f}:" }.join("  ")
    end
  end
end
