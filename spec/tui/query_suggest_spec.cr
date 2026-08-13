require "../spec_helper"

include Gori::Tui

# The completion row and the standing hints beside it are now GENERATED, from `QL::FIELDS` /
# `QL::FIELD_HELP` and each backend's own sample. These pin the two properties that made them
# worth generating: the operators survive a narrow terminal, and the description shown is the
# BACKEND's rather than QL's by assumption.
describe Gori::Tui::QuerySuggest do
  describe ".cold_hint" do
    it "names the operators a field pool can never reveal" do
      hint = QuerySuggest.cold_hint
      hint.should contain("-term excludes") # the one an operator reported not being able to find
      hint.should contain("OR")
      hint.should contain("NOT")
      hint.should contain("~regex")
      hint.should contain("host:") # ...and still names the vocabulary
    end

    it "keeps the operators inside 80 columns, ahead of the truncation point" do
      # A bar is one row. If the field sample runs long the terminal eats the tail, and the tail
      # is the half that cannot be discovered by pressing Tab — so `-term excludes` has to land
      # before column 80 for every pool a caller might hand over, including an 18-name one.
      [Gori::QL::HINT_FIELDS, Gori::QL::FIELDS, Gori::InterceptFilter::HINT_FIELDS].each do |pool|
        idx = QuerySuggest.cold_hint(pool).index("-term excludes")
        idx.should_not be_nil
        idx.not_nil!.should be < 80
      end
    end

    it "samples a long pool rather than spilling it" do
      QuerySuggest.cold_hint(Gori::QL::FIELDS).should_not contain("stub:")
    end

    it "sheds field chips until the negation fits the caller's real width" do
      # The colour-rule form's band is 68 columns. A fixed six-chip sample pushed `-term excludes`
      # clean off it — on the surface where that mistake becomes a STANDING RULE rather than a
      # query you notice and retype.
      narrow = QuerySuggest.cold_hint(width: 68)
      narrow.index("-term excludes").not_nil!.should be <= 68 - "-term excludes".size
      narrow.should contain("host:") # ...without shedding so far that the vocabulary is gone

      # It sheds from the TAIL, so the names that cannot be guessed outlive the ones that can.
      QuerySuggest.cold_hint(width: 60).should contain("resp.body:")
      QuerySuggest.cold_hint(width: 60).should_not contain("header:")

      # And it degrades all the way to operators-only rather than looping or truncating them.
      QuerySuggest.cold_hint(width: 10).should start_with("-term excludes")
    end
  end

  describe ".idle_hint" do
    it "carries the caller's own prefix and still names the negation" do
      hint = QuerySuggest.idle_hint("/ filter")
      hint.should start_with("/ filter")
      hint.should contain("-term excludes")
    end
  end

  describe ".line" do
    it "explains the field Tab would take, and only while completing a NAME" do
      # A field candidate: the description is the point — `resp.body:` is not self-describing.
      line = QuerySuggest.line(["resp.body:", "resp.header:"])
      line.should contain("resp.body:")
      line.should contain(Gori::QL::FIELD_HELP["resp.body"])
      line.should contain("resp.header:") # the also-rans stay listed

      # A VALUE candidate: the values already are the explanation, and "exact method — GET POST
      # PUT …" would push them off a narrow bar.
      QuerySuggest.line(["method:POST", "method:PUT"]).should_not contain("exact method")
    end

    it "reads the help from the BACKEND, not from QL" do
      # Same field name, genuinely different semantics: `body:` at a hold gate is the payload in
      # hand, not the trigram index. Borrowing QL's wording here would be a confident lie.
      gate = QuerySuggest.line(["body:"], ->(f : String) { Gori::InterceptFilter.field_help(f) })
      gate.should contain("payload in hand")
      gate.should_not contain("8 KiB")

      QuerySuggest.line(["body:"]).should contain("8 KiB") # QL's own surfaces still say so
    end

    it "is empty with nothing to complete, so a caller can fall back to a hint" do
      QuerySuggest.line([] of String).should eq("")
    end
  end

  # match vs NON-match. The grammar has had `-`/`NOT`/`OR` all along; what it did not have was a
  # completion row that ever mentioned them. These three pin the ways it now does.
  describe "guidance for exclusion" do
    # `with_operators` takes the whole Cursor, so build one the way a bar does.
    cursor = ->(query : String) { Gori::FilterAst.token_at(query, query.size) }

    it "offers the boolean operators a field pool cannot" do
      # `NOT (` is the point: `-` negates a TERM and cannot negate a GROUP, so this was the one
      # form with zero discovery — and the only way to exclude a disjunction.
      QuerySuggest.with_operators([] of String, cursor.call("N")).should eq(["NOT ("])
      QuerySuggest.with_operators([] of String, cursor.call("NOT")).should eq(["NOT ("])
      QuerySuggest.with_operators([] of String, cursor.call("O")).should eq(["OR"])
      QuerySuggest.with_operators([] of String, cursor.call("A")).should eq(["AND"])

      # CASE-SENSITIVE, matching the grammar: `FilterAst` reads AND/OR/NOT as operators only in
      # uppercase, precisely so searching for the words "not"/"or" still works. Offering `NOT (`
      # for a typed `n` would advertise something that compiles as free text.
      QuerySuggest.with_operators([] of String, cursor.call("n")).should be_empty
      QuerySuggest.with_operators([] of String, cursor.call("not")).should be_empty

      # It stops as soon as the token diverges, so free text starting with N is barely disturbed.
      QuerySuggest.with_operators([] of String, cursor.call("Nginx")).should be_empty

      # Fields keep their slot; operators are appended.
      QuerySuggest.with_operators(["host:"], cursor.call("N")).should eq(["host:", "NOT ("])
      QuerySuggest.with_operators(["host:"], cursor.call("")).should eq(["host:"])
    end

    it "carries the token's punctuation, and declines where it cannot" do
      # A candidate is spliced over the token's WHOLE span. A bare "OR" over `(O` would delete the
      # opening paren and dissolve the group the operator was being typed to build.
      QuerySuggest.with_operators([] of String, cursor.call("host:a (O")).should eq(["(OR"])
      QuerySuggest.with_operators([] of String, cursor.call("((N")).should eq(["((NOT ("])

      # A `-` prefix disqualifies them instead: `-NOT (` lexes as ONE WORD, so completing it would
      # produce free text wearing an operator's clothes.
      QuerySuggest.with_operators([] of String, cursor.call("-N")).should be_empty
      QuerySuggest.with_operators([] of String, cursor.call("(-O")).should be_empty
    end

    it "says a negated candidate EXCLUDES, where the description alone would not" do
      # `-host:` used to render the same sentence as `host:` — the row explaining the field never
      # mentioned the polarity the operator had just chosen.
      QuerySuggest.line(["-host:"]).should contain("excludes")
      QuerySuggest.line(["host:"]).should_not contain("excludes")
      QuerySuggest.line(["(-host:acme"]).should contain("excludes") # inside a group too

      # On a VALUE list there is no description at all, which is exactly where the lone dash is
      # easiest to miss — the eye is on the values.
      QuerySuggest.line(["-method:GET", "-method:POST"]).should contain("excludes")

      # A bare `-` is not a negation (`FilterAst` needs something after it), so nothing claims it is.
      QuerySuggest.negated?("-").should be_false
      QuerySuggest.negated?("-host:").should be_true
    end

    it "explains the operator Tab would take" do
      QuerySuggest.line(["NOT ("]).should contain("excludes a whole group")
      QuerySuggest.line(["OR"]).should contain("either side matches")
    end

    it "keeps the standing hint on a lone dash, the keystroke that commits to an exclusion" do
      # `FilterAst.token_at` peels a `-` into the token prefix only when something FOLLOWS it, so
      # a bare dash arrives as `core` and looks like a free-text word — which every bar answered
      # by blanking the row, removing all guidance at the exact moment it was wanted.
      QuerySuggest.hint_slot?("").should be_true
      QuerySuggest.hint_slot?("-").should be_true
      QuerySuggest.hint_slot?("ho").should be_false # a real word still blanks the row
    end
  end

  describe ".field_of" do
    it "peels the grammar's punctuation so a negated or grouped candidate still finds its help" do
      QuerySuggest.field_of("resp.body:").should eq("resp.body")
      QuerySuggest.field_of("-resp.body:").should eq("resp.body")
      QuerySuggest.field_of("(-host:acme").should eq("host")
      QuerySuggest.field_of("body~re").should eq("body")
      QuerySuggest.field_of("login").should eq("login")
    end
  end
end
