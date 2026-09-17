require "../spec_helper"

private alias SS = Gori::Screenshot

private JWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"

# `Redact.salt` is process-wide and the tags below have to be reproducible, so every example
# pins one and restores what it found (the shape `spec/redact_spec.cr` and
# `spec/tui/copy_redaction_spec.cr` both use).
private def with_salt(salt = "spec-salt", &)
  before = Gori::Redact.salt
  Gori::Redact.salt = salt
  begin
    yield
  ensure
    Gori::Redact.salt = before
  end
end

private def screen(*lines : String, wraps = [] of SS::WrapSpan) : SS::Frame
  f = SS::Frame.from_ansi(lines.join('\n') + "\n")
  wraps.empty? ? f : f.with(continuations: wraps)
end

# The shipped profile, whose built-in shapes carry the JWT.
private def default_matcher : Gori::Redact::Matcher
  Gori::Redact::Matcher.new(Gori::Redact::DEFAULT_PROFILE)
end

private def pattern_matcher(pattern : String) : Gori::Redact::Matcher
  Gori::Redact::Matcher.new(Gori::Redact::Profile.new(name: "spec", patterns: [pattern]))
end

module Gori::Screenshot
  describe Mask do
    it "hands back the very same frame when the project does not redact" do
      f = screen("Bearer #{JWT}")
      masked = Mask.apply(f, nil)
      masked.should be(f)
      # nil is "never masked", which is NOT the same claim as "masked, nothing matched".
      masked.sanitized.should be_nil
    end

    it "takes no matcher from a profile that would sanitize nothing" do
      with_store do |store|
        # Policy already refuses an empty profile — a picture stamped "sanitized" by a
        # profile with no rules is a lie, and this is where that would surface.
        Redact::Policy.write_project_scope(store, Redact::Policy::ProjectScope.new(
          default: true, active: "blank",
          profiles: [Redact::Profile.new(name: "blank")]))
        Redact::Policy.ambient(store).should be_nil

        Redact::Policy.write_project_scope(store,
          Redact::Policy::ProjectScope.new(default: true))
        with_salt { Redact::Policy.ambient(store).should_not be_nil }
      end
    end

    it "covers a wide enough region with the correlation tag" do
      with_salt do
        f = screen("Bearer #{JWT}")
        masked = Mask.apply(f, default_matcher)
        masked.sanitized.should eq(1)
        tag = Redact.placeholder(JWT)
        tag.size.should eq(Mask::TAG_WIDTH)
        masked.row_text(0).should eq("Bearer #{tag}#{" " * (JWT.size - tag.size)}")
        # Two screenshots of the same token carry the same tag, which is the whole point of
        # spending 19 columns on one.
        masked.row_text(0).should match(/\[REDACTED:[0-9a-f]{8}\]/)
      end
    end

    it "keeps each covered cell's own background so the layout survives" do
      with_salt do
        # The token sits inside a selection band; the band has to still be a band afterwards.
        f = Frame.from_ansi("\e[48;2;38;38;44mBearer #{JWT}\e[0m\n")
        masked = Mask.apply(f, default_matcher)
        band = RGB.hex("#26262c")
        masked.at(7, 0).bg.should eq(band)  # first cell of the tag
        masked.at(20, 0).bg.should eq(band) # inside the covered run
        masked.at(7, 0).grapheme.should eq("[")
      end
    end

    it "fills a region too narrow for a tag" do
      with_salt do
        f = screen("pw=secret123456 ok")
        masked = Mask.apply(f, pattern_matcher("secret[0-9]{6}"))
        masked.sanitized.should eq(1)
        masked.row_text(0).should eq("pw=#{"▒" * 12} ok")
      end
    end

    it "maps columns past a wide glyph exactly" do
      with_salt do
        # 한 and 글 are two columns each, so the match starts at column 5, not at column 3.
        f = screen("한글 secret123456")
        masked = Mask.apply(f, pattern_matcher("secret[0-9]{6}"))
        masked.row_text(0).should eq("한글 #{"▒" * 12}")
        masked.at(0, 0).grapheme.should eq("한")
        masked.at(1, 0).cont?.should be_true
        masked.at(5, 0).grapheme.should eq("▒")
        masked.at(4, 0).grapheme.should eq(" ")
      end
    end

    it "finds a secret soft-wrapped across two rows and counts it once" do
      with_salt do
        head = JWT[0, 45]
        tail = JWT[45..]
        # Neither half is a JWT on its own — row-at-a-time would find nothing at all.
        Mask.apply(screen(head, tail), default_matcher).sanitized.should eq(0)

        f = screen(head, tail, wraps: [WrapSpan.new(1, 0, 46)])
        masked = Mask.apply(f, default_matcher)
        masked.sanitized.should eq(1) # one secret, not one per row
        masked.row_text(0).should start_with("[REDACTED:")
        masked.row_text(1).should start_with("[REDACTED:")
        masked.row_text(0).should_not contain("eyJ")
        masked.row_text(1).should_not contain("dBjft")
      end
    end

    it "counts spans, not rows, and finds several on one row" do
      with_salt do
        f = screen("a #{JWT} b #{JWT} c", "pw=secret123456")
        masked = Mask.apply(f, pattern_matcher("secret[0-9]{6}"))
        # Two JWTs from the built-in shape on row 0, one profile pattern on row 1.
        masked.sanitized.should eq(3)
        masked.row_text(0).scan("[REDACTED:").size.should eq(2)
      end
    end

    it "leaves a clean frame alone but still says it was masked" do
      with_salt do
        f = screen("GET /health", "200 OK")
        masked = Mask.apply(f, default_matcher)
        masked.same_cells?(f).should be_true
        # 0, not nil: this frame WAS masked and nothing matched, and the SVG says so.
        masked.sanitized.should eq(0)
      end
    end

    it "covers the region even when no salt is armed to tag it with" do
      with_salt("") do
        masked = Mask.apply(screen("Bearer #{JWT}"), default_matcher)
        masked.sanitized.should eq(1)
        masked.row_text(0).should eq("Bearer #{"▒" * JWT.size}")
      end
    end
  end
end
