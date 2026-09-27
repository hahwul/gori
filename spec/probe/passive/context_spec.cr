require "../../spec_helper"

# Context is the per-flow parse/decode cache every passive rule reads from. It needs no Store:
# a FlowDetail is a plain record, so these build one directly. What is pinned here is the two
# properties the rules depend on and that an optimisation of this file could silently break —
# the body text handed to PCRE is always valid UTF-8, and the two client-script views agree
# with the lexer whichever one a rule asks for first.

private alias Passive = Gori::Probe::Passive

private def ctx_for(body : Bytes?, content_type : String?, resp_head : String) : Passive::Context
  row = Gori::Store::FlowRow.new(
    1_i64, 1_i64, "https", "GET", "app.example", 443, "/",
    200, (body.try(&.size) || 0).to_i64, Gori::Store::FlowState::Complete,
    content_type: content_type)
  detail = Gori::Store::FlowDetail.new(
    row, "HTTP/1.1", "GET / HTTP/1.1\r\nHost: app.example\r\n\r\n".to_slice, nil,
    resp_head.to_slice, body)
  Passive::Context.new(detail)
end

private HTML_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n"
private PNG_HEAD  = "HTTP/1.1 200 OK\r\nContent-Type: image/png\r\n\r\n"
private TEXT_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n"

private DOC = <<-HTML
  <!doctype html><html><body><script>
  var s = "keep //me"; /* drop me */ el.innerHTML = location.hash; // drop me too
  </script></body></html>
  HTML

describe Gori::Probe::Passive::Context do
  describe "#body_text" do
    # The repair moved from a bare `String#scrub` to `Utf8.text`, which asks the cheap
    # `valid_encoding?` question first and only scrubs what actually needs it. Every rule then
    # hands this string to PCRE2, which RAISES on invalid UTF-8 rather than failing to match —
    # so "always valid" is a correctness property, not a nicety.
    it "repairs a body that is not valid UTF-8" do
      ctx = ctx_for(Bytes[0x41, 0xff, 0xfe, 0x42], "text/plain", TEXT_HEAD)
      text = ctx.body_text.not_nil!
      text.valid_encoding?.should be_true
      text.should eq(String.new(Bytes[0x41, 0xff, 0xfe, 0x42]).scrub)
    end

    it "hands back a valid body unchanged" do
      ctx = ctx_for("héllo = 1".to_slice, "text/plain", HTML_HEAD)
      ctx.body_text.should eq("héllo = 1")
    end

    it "is nil when there is no body" do
      ctx_for(nil, "text/html", HTML_HEAD).body_text.should be_nil
    end

    # Scrubbing a binary body turned each stray byte into a 3-byte U+FFFD that every body rule
    # then walked (~600µs per image) — see `bench/probe_passive_bench.cr`'s binary row.
    it "reads a declared-binary body that is not UTF-8 as no text" do
      png = Bytes[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff]
      ctx_for(png, "image/png", PNG_HEAD).body_text.should be_nil
      ctx_for(png, "font/woff2", PNG_HEAD).body_text.should be_nil
      ctx_for(png, "application/wasm", PNG_HEAD).body_text.should be_nil
    end

    # The skip needs BOTH halves: a text error page served under an image type is still read,
    # because what it carries (a stack trace, a key) is exactly what the body rules look for.
    it "still reads a text body mislabelled with a binary type" do
      ctx_for("Traceback (most recent call last):".to_slice, "image/png", PNG_HEAD)
        .body_text.should eq("Traceback (most recent call last):")
    end

    # SVG is XML text — and a script carrier — so it is never treated as binary; neither is
    # octet-stream, the sniffable type MimeConfusion reads.
    it "keeps repairing SVG and octet-stream bodies" do
      bad = Bytes[0x3c, 0x73, 0x76, 0x67, 0xff]
      ctx_for(bad, "image/svg+xml", PNG_HEAD).body_text.should eq(String.new(bad).scrub)
      ctx_for(bad, "application/octet-stream", PNG_HEAD).body_text.should eq(String.new(bad).scrub)
    end
  end

  # Both views come from ONE lex per fragment (JsScan.strip_both), filled by whichever getter is
  # asked first. A rule order that happens to ask for the comments-only view first must see the
  # same thing as one that asks for the stripped view first.
  describe "client script views" do
    it "matches the lexer when client_code is asked for first" do
      ctx = ctx_for(DOC.to_slice, "text/html", HTML_HEAD)
      ctx.client_code.should eq(ctx.client_scripts.map { |s| Passive::JsScan.strip(s) })
      ctx.client_scripts_nocomment.should eq(ctx.client_scripts.map { |s| Passive::JsScan.strip_comments(s) })
    end

    it "matches the lexer when client_scripts_nocomment is asked for first" do
      ctx = ctx_for(DOC.to_slice, "text/html", HTML_HEAD)
      ctx.client_scripts_nocomment.should eq(ctx.client_scripts.map { |s| Passive::JsScan.strip_comments(s) })
      ctx.client_code.should eq(ctx.client_scripts.map { |s| Passive::JsScan.strip(s) })
    end

    it "keeps the two views distinct — strings survive only in the comments-only one" do
      ctx = ctx_for(DOC.to_slice, "text/html", HTML_HEAD)
      ctx.client_code.first.includes?("keep //me").should be_false
      ctx.client_scripts_nocomment.first.includes?("keep //me").should be_true
      ctx.client_scripts_nocomment.first.includes?("drop me").should be_false
    end

    it "memoises both as empty for a response with no script" do
      ctx = ctx_for("image bytes".to_slice, "image/png", PNG_HEAD)
      ctx.client_code.should be_empty
      ctx.client_scripts_nocomment.should be_empty
    end
  end
end
