require "./spec_helper"

private def head(*lines : String) : Bytes
  (lines.join("\r\n") + "\r\n\r\n").to_slice
end

describe Gori::AltSvc do
  describe ".h3_evidence" do
    it "returns the h3 alternative, and nothing for a value that names none" do
      Gori::AltSvc.h3_evidence(%(h3=":443"; ma=2592000)).should eq(%(h3=":443"; ma=2592000))
      Gori::AltSvc.h3_evidence(%(h2=":443"; ma=86400, h3=":443")).should eq(%(h3=":443"))
      Gori::AltSvc.h3_evidence(%(h3-29=":443")).should eq(%(h3-29=":443"))
      Gori::AltSvc.h3_evidence(%(h2=":443")).should be_nil
    end

    it "never matches `clear`, which is the one spelling that helps" do
      # RFC 7838 §3: `clear` tells the client to FORGET the alternatives it cached. Stripping
      # it would leave a client holding an h3 route gori had just taken the invitation for.
      Gori::AltSvc.h3_evidence("clear").should be_nil
      Gori::AltSvc.advertises_h3?("clear").should be_false
    end

    it "matches the protocol-id as a whole token, never a substring" do
      Gori::AltSvc.h3_evidence(%(fooh3=":443")).should be_nil
      Gori::AltSvc.h3_evidence(%(h32=":443")).should be_nil
    end

    it "does not read a list separator out of a comma inside a quoted-string" do
      # RFC 9110 §5.6.4: `alt-authority` and a parameter value are quoted-strings, in which a
      # comma is DATA. Splitting on every comma cut `p="a, h3=x"` in two and read `h3=x"` out of
      # the second half — so gori removed a field advertising no HTTP/3 at all, while the flow
      # advisory claimed it had removed an h3 advertisement.
      Gori::AltSvc.h3_evidence(%(fake=":443"; p="a, h3=x")).should be_nil
      Gori::AltSvc.advertises_h3?(%(fake=":443"; p="a, h3=x")).should be_false
      # A backslash escapes the next octet inside the quotes, so the run does not end early.
      Gori::AltSvc.h3_evidence(%(fake=":443"; p="a\\", h3=x")).should be_nil
      # …and the separators that ARE separators still separate.
      Gori::AltSvc.h3_evidence(%(fake="a, b", h3=":443")).should eq(%(h3=":443"))
    end

    it "strips nothing for a quoted comma reaching the whole way through the proxy seam" do
      original = head("HTTP/1.1 200 OK", %(Alt-Svc: fake=":443"; p="a, h3=x"), "Content-Length: 3")
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should be_empty
      stripped.to_unsafe.should eq(original.to_unsafe)
    end

    it "survives a value that is not valid UTF-8" do
      Gori::AltSvc.h3_evidence(String.new(Bytes[0xff, 0xfe]) + %(, h3=":443")).should eq(%(h3=":443"))
    end
  end

  describe ".removal_note" do
    it "always counts exactly, and quotes a bounded number of them" do
      # The evidence is remote-chosen: one head packed with `Alt-Svc` fields produced a 220 KB
      # advisory, written to the flow on every such response. The COUNT stays exact — a bound
      # that hid how many were removed would be worse than the flood it prevents.
      note = Gori::AltSvc.removal_note((1..9).map { |i| %(h3=":#{i}") })
      note.should contain("removed 9 Alt-Svc HTTP/3 advertisements")
      note.should contain(%(h3=":1"))
      note.should contain(%(h3=":4"))
      note.should_not contain(%(h3=":5"))
      note.should contain("and 5 more")
    end

    it "reads as one advertisement when there was one" do
      note = Gori::AltSvc.removal_note([%(h3=":443")])
      note.should contain("removed 1 Alt-Svc HTTP/3 advertisement (")
      note.should_not contain("advertisements")
      note.should_not contain("more")
    end
  end

  describe ".strip_h3" do
    it "removes the advertising field and copies every other byte verbatim" do
      original = head("HTTP/1.1 200 OK", "Content-Type: text/html", %(Alt-Svc: h3=":443"; ma=86400),
        "Content-Length: 3")
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should eq([%(h3=":443"; ma=86400)])
      String.new(stripped).should eq("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 3\r\n\r\n")
    end

    it "returns the INPUT slice when nothing advertised h3, so the caller keeps the origin's bytes" do
      original = head("HTTP/1.1 200 OK", %(Alt-Svc: h2=":8443"), "Alt-Svc: clear")
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should be_empty
      # Not merely equal: the same memory. A copy here would mean every response carrying an
      # `Alt-Svc` silently left the byte-exact path (P7).
      stripped.to_unsafe.should eq(original.to_unsafe)
    end

    it "takes only the fields that advertise h3, leaving the siblings alone" do
      original = head("HTTP/1.1 200 OK", %(Alt-Svc: h2=":8443"), %(alt-svc: h3-29=":443"),
        %(Alt-Svc: clear))
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should eq([%(h3-29=":443")])
      text = String.new(stripped)
      text.should contain(%(Alt-Svc: h2=":8443"))
      text.should contain(%(Alt-Svc: clear))
      text.should_not contain("h3-29")
    end

    it "takes the WHOLE field when one value carries both an h2 and an h3 alternative" do
      # A field is rewritten whole or not at all: value surgery would put gori's own spelling
      # of a remote-chosen header on the wire, and the h2 half costs no visibility anyway.
      original = head("HTTP/1.1 200 OK", %(Alt-Svc: h2=":443", h3=":443"))
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.size.should eq(1)
      String.new(stripped).should eq("HTTP/1.1 200 OK\r\n\r\n")
    end

    it "matches the field-name case-insensitively" do
      original = head("HTTP/1.1 200 OK", "X-A: 1", %(ALT-SVC: h3=":443"), "X-B: 2")
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.size.should eq(1)
      String.new(stripped).should eq("HTTP/1.1 200 OK\r\nX-A: 1\r\nX-B: 2\r\n\r\n")
    end

    it "leaves a head with no CRLF alone — it has no header block to read" do
      # The scan takes `parse_headers`' view, and by that view a bare-LF head has no headers at
      # all. Reading lines on LF instead made this scan see fields the parser never did.
      original = "HTTP/1.1 200 OK\nALT-SVC: h3=\":443\"\n\n".to_slice
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should be_empty
      stripped.to_unsafe.should eq(original.to_unsafe)
    end

    it "does not reach inside a field value that smuggles a bare LF" do
      # The defect this pins: an LF-framed scan saw `alt-svc: …` INSIDE X-Foo's value, cut it
      # out, and left `X-Foo: a\n` dangling — gori's own re-parse then lost `Content-Length`
      # and refused the response it had already been forwarding fine with the switch off.
      original = ("HTTP/1.1 200 OK\r\nX-Foo: a\nalt-svc: h3=\":443\"\r\n" \
                  "Content-Length: 4\r\n\r\n").to_slice
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should be_empty
      stripped.to_unsafe.should eq(original.to_unsafe)
    end

    it "takes an obs-fold continuation with the field it belongs to, and reads the joined value" do
      # Two halves of one defect. Dropping only the first line orphans `\th2=…` onto the status
      # line — gori manufacturing a malformed head out of a well-formed one — and matching only
      # the first line misses an h3 a lenient client would still unfold and act on.
      original = ("HTTP/1.1 200 OK\r\nAlt-Svc: h2=\":443\",\r\n\th3=\":443\"\r\n" \
                  "Content-Length: 4\r\n\r\n").to_slice
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.size.should eq(1)
      String.new(stripped).should eq("HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\n")
    end

    it "keeps a folded field that advertises no h3, continuation included" do
      original = ("HTTP/1.1 200 OK\r\nAlt-Svc: h2=\":443\",\r\n\th2=\":8443\"\r\n" \
                  "Content-Length: 4\r\n\r\n").to_slice
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should be_empty
      stripped.to_unsafe.should eq(original.to_unsafe)
    end

    it "leaves a non-UTF-8 sibling header byte-exact" do
      io = IO::Memory.new
      io << "HTTP/1.1 200 OK\r\nX-Raw: "
      io.write(Bytes[0xff, 0xfe])
      io << "\r\nAlt-Svc: h3=\":443\"\r\n\r\n"
      original = io.to_slice
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.size.should eq(1)
      stripped.should eq("HTTP/1.1 200 OK\r\nX-Raw: ".to_slice + Bytes[0xff, 0xfe] + "\r\n\r\n".to_slice)
    end

    it "never touches a request-shaped head that merely mentions the name in a value" do
      original = head("GET / HTTP/1.1", "Host: acme.test", %(X-Note: Alt-Svc: h3=":443"))
      stripped, removed = Gori::AltSvc.strip_h3(original)
      removed.should be_empty
      stripped.to_unsafe.should eq(original.to_unsafe)
    end
  end
end
