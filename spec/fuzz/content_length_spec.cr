require "../spec_helper"

private alias F = Gori::Fuzz

# Byte-fidelity regressions for the bare-LF / mixed-EOL blind spots in `Fuzz::ContentLength`.
# The module's contract is byte-level and zero-allocation (content_length.cr:11-16); these
# specs pin the exact wire bytes, because the whole point of a smuggling/desync primitive is
# that ONE hidden byte changes how a downstream parser frames the message.
describe F::ContentLength do
  # ADDING a header is held to a higher bar than recomputing one, and `Transfer-Encoding` is
  # where the two come apart. `chunked?` answers "is the FINAL coding chunked" (RFC 7230
  # §3.3.1), which is right for leaving an existing Content-Length alone — but it reads
  # `chunked, gzip` as NOT chunked and looks only at the FIRST TE header, so using it to gate
  # the ADD path would let gori invent a Content-Length beside a TE line. That pair is the
  # canonical CL+TE smuggling primitive, and here it would be one the operator never wrote,
  # manufactured on every request of a sweep. `FlowRequest.resync_content_length` refuses on
  # any `transfer-encoding:` line; this is the same rule in the fuzz module.
  describe "add_when_missing beside a Transfer-Encoding" do
    it "adds nothing to a TE-framed body, whatever the codings say" do
      # Each of these has a body and NO Content-Length, so only the TE line stands between it
      # and an invented header. The last two are exactly what `chunked?` answers `false` for.
      {
        "POST /a HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nZ\r\n0\r\n\r\n",
        "POST /b HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: chunked, gzip\r\n\r\n1\r\nZ\r\n0\r\n\r\n",
        "POST /c HTTP/1.1\r\nHost: t\r\nTransfer-Encoding: gzip\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nZ\r\n0\r\n\r\n",
        # A bare-LF-terminated TE line, the shape the head scan tokenizes on LF to catch.
        "POST /d HTTP/1.1\r\nHost: t\nTransfer-Encoding: chunked, gzip\r\n\r\n1\r\nZ\r\n0\r\n\r\n",
      }.each do |req|
        out = String.new(F::ContentLength.sync(req.to_slice, add_when_missing: true))
        out.should eq(req)                                # byte-identical: nothing was invented
        out.downcase.should_not contain("content-length") # …and specifically not this
      end
    end

    it "still adds one to a body that declares no framing at all" do
      req = "POST /e HTTP/1.1\r\nHost: t\r\nContent-Type: application/json\r\n\r\n{\"k\":1}"
      String.new(F::ContentLength.sync(req.to_slice, add_when_missing: true))
        .should contain("Content-Length: 7\r\n")
    end
  end

  describe "duplicate Content-Length (a desync primitive must survive the resync)" do
    it "leaves a bare-LF-hidden second Content-Length byte-intact (only the first is rewritten)" do
      # The second `Content-Length: 100` is terminated by a BARE LF, so a CRLF-only line split
      # would merge it into the first line and DELETE it on rewrite — silently disarming the
      # exact desync vector the fuzzer crafted. Tokenizing on LF (like an LF-lenient backend,
      # and like the file's own `chunked?`) keeps it a distinct line: the first CL is resynced
      # to the real body length (3), the hidden CL is preserved verbatim.
      req = "POST / HTTP/1.1\r\nContent-Length: 6\nContent-Length: 100\r\n\r\nabc".to_slice
      out = String.new(F::ContentLength.sync(req))
      out.should eq("POST / HTTP/1.1\r\nContent-Length: 3\nContent-Length: 100\r\n\r\nabc")
      out.should contain("Content-Length: 100") # the hidden header is NOT dropped
    end

    it "leaves a CRLF-visible second Content-Length intact too (parity = proof the bug was a bug)" do
      # The CRLF-visible duplicate was ALREADY handled correctly (the `\r\n` after the first CL
      # is a line boundary under either split). Asserting the same outcome as the bare-LF case
      # is what makes the bare-LF deletion a bug rather than a policy — the two must agree.
      req = "POST / HTTP/1.1\r\nContent-Length: 6\r\nContent-Length: 100\r\n\r\nabc".to_slice
      out = String.new(F::ContentLength.sync(req))
      out.should eq("POST / HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 100\r\n\r\nabc")
      out.should contain("Content-Length: 100")
    end
  end

  # `sync_edit` (an Intercept edit) keeps a CL.CL pair whole where `sync` (the Fuzzer, pinned
  # above) rewrites the first; a lone header is still resynced and a missing one added.
  describe ".sync_edit" do
    it "leaves a CL.CL pair alone, a bare-LF-hidden one included" do
      {
        "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nContent-Length: 7\r\n\r\nhello!!",
        "POST / HTTP/1.1\r\nContent-Length: 6\nContent-Length: 100\r\n\r\nabc",
      }.each { |req| String.new(F::ContentLength.sync_edit(req.to_slice)).should eq(req) }
    end

    it "resyncs a single Content-Length and adds a missing one" do
      String.new(F::ContentLength.sync_edit("POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\nabc".to_slice))
        .should eq("POST / HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc")
      String.new(F::ContentLength.sync_edit("POST / HTTP/1.1\r\nHost: a\r\n\r\nabc".to_slice))
        .should eq("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 3\r\n\r\nabc")
    end
  end

  # A malformed length is a probe: found (so nothing is added beside it) but never rewritten,
  # the rule `FlowRequest.resync_content_length` applies through the same predicate.
  describe "a Content-Length that rewriting would change the meaning of" do
    it "leaves an obs-fold, a non-decimal value and whitespace before the colon alone" do
      {
        "POST / HTTP/1.1\r\nX-A: 1\r\n Content-Length: 99\r\n\r\nabc",
        "POST / HTTP/1.1\r\nContent-Length: 0abc\r\n\r\nabc",
        "POST / HTTP/1.1\r\nContent-Length : 99\r\n\r\nabc",
      }.each do |req|
        String.new(F::ContentLength.sync(req.to_slice, add_when_missing: true)).should eq(req)
      end
    end

    it "adds nothing when only blank lines precede the separator" do
      req = "\r\n\r\nGET / HTTP/1.1\r\nHost: h\r\n\r\n"
      String.new(F::ContentLength.sync(req.to_slice, add_when_missing: true)).should eq(req)
    end
  end

  describe "mixed `\\n\\r\\n` head/body separator" do
    it "recomputes the CL and splices the mixed separator back verbatim" do
      # Last header line ended in a bare LF, the blank line itself was CRLF: the separator is
      # `\n\r\n`, NOT a repeated `eol`. `boundary` must recognize the 3-byte spelling (else no
      # boundary is found and the stale CL 5 is never resynced), and the rewrite must splice
      # `\n\r\n` back byte-for-byte rather than rebuild it as `\n\n` / `\r\n\r\n`.
      req = "POST / HTTP/1.1\r\nContent-Length: 5\n\r\nabc".to_slice
      out = String.new(F::ContentLength.sync(req))
      out.should eq("POST / HTTP/1.1\r\nContent-Length: 3\n\r\nabc")
    end

    it "picks the earliest blank line when the BODY also holds a CRLFCRLF" do
      # The body contains its own `\r\n\r\n`; the head's earlier mixed `\n\r\n` must win so the
      # CL counts the whole body, and the body is spliced back byte-exact.
      req = "POST / HTTP/1.1\r\nContent-Length: 0\n\r\nX\r\n\r\nY".to_slice
      out = String.new(F::ContentLength.sync(req))
      out.should eq("POST / HTTP/1.1\r\nContent-Length: 6\n\r\nX\r\n\r\nY") # body "X\r\n\r\nY" = 6 bytes
    end

    it "preserves a mixed-separator body byte-exact on the no-op (already-canonical) path" do
      # CL already equals the body length: sync is a no-op, but only if `boundary` found the
      # `\n\r\n` at all. Returns the input unchanged.
      req = "POST / HTTP/1.1\r\nContent-Length: 3\n\r\nabc".to_slice
      F::ContentLength.sync(req).should eq(req)
    end

    it "appends a fresh CL keeping the mixed separator's bare-LF spelling" do
      # add_when_missing on a `\n\r\n` head: the inserted CL line is terminated by the bare LF
      # that the separator leads with, so the operator's blank-line spelling survives the insert.
      req = "POST / HTTP/1.1\n\r\nabc".to_slice
      out = String.new(F::ContentLength.sync(req, add_when_missing: true))
      out.should eq("POST / HTTP/1.1\nContent-Length: 3\n\r\nabc")
    end
  end

  describe "sync_at {at, delta} — the contract Generator#shift_spans remaps §-spans by" do
    it "reports at/delta so a §-span AFTER the CL line remaps onto the same output bytes" do
      # The authored CL grows 1 → 12 (one extra digit), so every byte from the CL line's
      # terminator on shifts by +1. A payload span living in the body (offset >= at) must be
      # relocated by exactly delta — that is the whole `shift_spans(a >= at ? a+delta : a)` rule.
      head = "POST / HTTP/1.1\r\nContent-Length: 1\r\n\r\n"
      body = "0123456789ab" # 12 bytes → CL becomes "12", delta = +1
      req = (head + body).to_slice
      body_at = head.bytesize

      synced, at, delta = F::ContentLength.sync_at(req)
      delta.should eq(1)
      at.should be < body_at # the edit is up in the head, before any body span

      # Emulate Generator#shift_spans for a body span and prove it lands on the exact body bytes.
      new_body_at = body_at >= at ? body_at + delta : body_at
      new_body_at.should eq(body_at + delta)
      String.new(synced[new_body_at, body.bytesize]).should eq(body)
    end

    it "bounds the CORRECT (bare-LF-terminated) line, so at/delta track the real edited span" do
      # With a bare-LF-hidden duplicate, `at` must be the bare-LF position that ends the FIRST
      # CL line — not the far-away CRLF after the hidden second CL. Here the first CL grows
      # 6 → 12 (delta +1); the hidden `Content-Length: 100` is preserved and a body span still
      # remaps by the true head growth.
      head = "POST / HTTP/1.1\r\nContent-Length: 6\nContent-Length: 100\r\n\r\n"
      body = "0123456789ab" # 12 bytes
      req = (head + body).to_slice
      body_at = head.bytesize

      synced, at, delta = F::ContentLength.sync_at(req)
      delta.should eq(1)
      at.should be < body_at
      String.new(synced).should contain("Content-Length: 100") # hidden CL survived the rewrite

      new_body_at = body_at >= at ? body_at + delta : body_at
      String.new(synced[new_body_at, body.bytesize]).should eq(body)
    end
  end
end

private def only_job(template : String, payload : String) : F::Job
  gen = F::Generator.new(F::Template.parse(template), [F::PayloadSet.new(F::InlineList.new([payload]))], F::Config.new)
  job = nil.as(F::Job?)
  gen.each { |j| job = j }
  job.not_nil!
end

describe "the Content-Length pass and a payload that writes its own framing" do
  # A header-injection payload carrying its own blank line is a smuggling test: gori used to
  # insert `Content-Length:` in the middle of it, and the span then lost the payload's tail.
  it "leaves a payload's own blank line, and the span over it, alone" do
    j = only_job("POST / HTTP/1.1\r\nHost: t\r\nX: §v§\r\n\r\n", "a\r\n\r\n$TOKEN")
    String.new(j.bytes).should eq("POST / HTTP/1.1\r\nHost: t\r\nX: a\r\n\r\n$TOKEN\r\n\r\n")
    a, b = j.payload_spans[0]
    String.new(j.bytes[a, b - a]).should eq("a\r\n\r\n$TOKEN")
  end

  it "sends a marked Content-Length value as the payload, not the measured length" do
    j = only_job("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: §5§\r\n\r\nhello", "0")
    String.new(j.bytes).should eq("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 0\r\n\r\nhello")
  end

  it "keeps an EMPTY marked Content-Length value" do
    j = only_job("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: §5§\r\n\r\nhello", "")
    String.new(j.bytes).should eq("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: \r\n\r\nhello")
  end

  # Sniper fills one position; a marked Content-Length left at its default is gori's to resync
  # while the body position grows.
  it "resyncs a marked Content-Length that this Sniper variation did not fill" do
    cfg = F::Config.new(mode: F::Mode::Sniper)
    gen = F::Generator.new(F::Template.parse("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: §3§\r\n\r\na=§b§"),
      [F::PayloadSet.new(F::InlineList.new(["xxxxxx"]))], cfg)
    js = [] of F::Job
    gen.each { |j| js << j }
    String.new(js.find { |j| j.position == 1 }.not_nil!.bytes)
      .should eq("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 8\r\n\r\na=xxxxxx")
    String.new(js.find { |j| j.position == 0 }.not_nil!.bytes)
      .should eq("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: xxxxxx\r\n\r\na=b")
  end

  it "still measures a body payload" do
    j = only_job("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 1\r\n\r\n§x§", "abc")
    String.new(j.bytes).should eq("POST / HTTP/1.1\r\nHost: t\r\nContent-Length: 3\r\n\r\nabc")
  end
end
