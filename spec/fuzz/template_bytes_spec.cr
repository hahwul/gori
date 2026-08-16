require "../spec_helper"

private alias T = Gori::Fuzz::Template

# `Template.parse` iterated `marked.chars`, and Crystal's char iteration substitutes U+FFFD
# for every byte that is not valid UTF-8. So the template layer — which every fuzz run passes
# through, on every surface, whether or not anything is marked — silently rewrote any request
# body carrying raw 0x80-0xFF: a protobuf/gRPC frame, a gzip'd or otherwise binary POST, a
# latin-1 form field. Each such byte became the THREE bytes of the replacement character, so
# every request the sweep sent differed in length from the one it was seeded with, under a
# Content-Length recomputed to match the corruption, and nothing anywhere said so.
#
# `gori run fuzz --request FILE` and a piped stdin reach this with no scrub in front of them,
# so it is directly reachable, not only via a capture.
describe "Gori::Fuzz::Template — byte fidelity" do
  it "round-trips a body with invalid UTF-8 through parse → render unchanged" do
    raw = "POST /u HTTP/1.1\r\nHost: h\r\nContent-Length: 5\r\n\r\n" +
          String.new(Bytes[0x80, 0xFE, 0x00, 0xFF, 0xC0])
    tmpl = T.parse(raw)
    tmpl.position_count.should eq(0)
    tmpl.render([] of String).to_a.should eq(raw.to_slice.to_a)
  end

  it "splices a payload into a marked position while the binary body around it survives" do
    prefix = "POST /u?id=".to_slice
    marked = String.new(prefix) + "§1§" + " HTTP/1.1\r\nHost: h\r\n\r\n" +
             String.new(Bytes[0xC3, 0x28, 0x9F, 0x0A])
    tmpl = T.parse(marked)
    tmpl.position_count.should eq(1)
    rendered = tmpl.render(["99"])
    String.new(rendered).should start_with("POST /u?id=99 HTTP/1.1")
    rendered[-4..].to_a.should eq([0xC3, 0x28, 0x9F, 0x0A])
  end

  it "keeps a lone 0xA7 byte — the second half of §'s encoding — as itself" do
    # 0xA7 alone is not §; only the C2 A7 pair is. A char scan turned the bare byte into
    # U+FFFD; a byte scan that matched on 0xA7 alone would instead open a bogus position.
    raw = "POST /x HTTP/1.1\r\n\r\n" + String.new(Bytes[0xA7, 0x41, 0xC2])
    tmpl = T.parse(raw)
    tmpl.position_count.should eq(0)
    tmpl.render([] of String).to_a.should eq(raw.to_slice.to_a)
  end

  it "still honours §§ escapes, ¦chains and an unbalanced trailing § over bytes" do
    tmpl = T.parse("A§§B§v¦b64§C§tail")
    tmpl.position_count.should eq(1)
    tmpl.positions[0].default.should eq("v")
    tmpl.positions[0].chain.should eq("b64")
    # `A§B` literal, the position, then the unbalanced trailing § folded back as text.
    String.new(tmpl.render(["X"])).should eq("A§BXC§tail")
  end

  it "keeps a ¦¦ escape and a second bare ¦ literal inside the chain" do
    tmpl = T.parse("§a¦¦b¦c¦d§")
    tmpl.positions[0].default.should eq("a¦b")
    tmpl.positions[0].chain.should eq("c¦d")
  end

  it "renders the defaults back to the original bytes when nothing is substituted" do
    src = "GET /p?a=§1§&b=§two§ HTTP/1.1\r\nHost: h\r\n\r\n"
    tmpl = T.parse(src)
    String.new(tmpl.render(tmpl.default_payloads)).should eq("GET /p?a=1&b=two HTTP/1.1\r\nHost: h\r\n\r\n")
  end

  it "does not lose the byte count on a body that is entirely high bytes" do
    body = Bytes.new(256) { |i| i.to_u8 }
    raw = "POST /b HTTP/1.1\r\nContent-Length: 256\r\n\r\n" + String.new(body)
    T.parse(raw).render([] of String).size.should eq(raw.to_slice.size)
  end

  # `parse`/`render` were made byte-oriented (see the header above); the MARKING helpers
  # next door were not. `mark_word`, `strip_marker` and `set_chain` each rebuilt the whole
  # buffer with `text.chars` + `.join`, and Crystal's char iteration substitutes U+FFFD for
  # every invalid byte — so pressing ^K on a token in a captured binary request rewrote the
  # rest of that request. These run BEFORE the send, on the operator's own buffer, so no
  # amount of byte-exactness downstream can recover what they threw away.
  #
  # Measured on `x=1 bin=<ff fe 01 02>` with the cursor on `1`:
  #   in  78 3d 31 20 62 69 6e 3d ff fe 01 02
  #   out 78 3d c2 a7 31 c2 a7 20 62 69 6e 3d ef bf bd ef bf bd 01 02   (+8 bytes, not +4)
  describe "the marking helpers over bytes" do
    # `x=1 bin=\xff\xfe\x01\x02` — a latin-1/binary form field beside a markable token.
    raw = String.new(Bytes[0x78, 0x3D, 0x31, 0x20, 0x62, 0x69, 0x6E, 0x3D, 0xFF, 0xFE, 0x01, 0x02])
    tail = Bytes[0xFF, 0xFE, 0x01, 0x02]
    # Searched BYTE-wise: the fixture is deliberately not valid UTF-8, so no String-level
    # `includes?` may be used to look for it.
    keeps_tail = ->(s : String) do
      b = s.to_slice
      b.size >= tail.size && (0..(b.size - tail.size)).any? { |i| b[i, tail.size] == tail }
    end

    it "mark_word wraps the token and leaves every other byte alone" do
      marked = T.mark_word(raw, 2) # cursor on the `1`
      keeps_tail.call(marked).should be_true
      # Exactly the two § (2 bytes each) were added — nothing was re-encoded.
      marked.bytesize.should eq(raw.bytesize + 4)
      T.parse(marked).position_count.should eq(1)
      # …and the template still renders back to the captured bytes.
      String.new(T.parse(marked).render(T.parse(marked).default_payloads)).to_slice.to_a
        .should eq(raw.to_slice.to_a)
    end

    it "mark_word UNmarks byte-safely too" do
      marked = T.mark_word(raw, 2)
      T.mark_word(marked, 3).to_slice.to_a.should eq(raw.to_slice.to_a)
    end

    it "mark_word leaves a cursor on a delimiter byte-identical" do
      # The `no token here` branch returned `chars.join`, i.e. it corrupted the buffer while
      # the caller — which compares `after == before` to decide whether anything happened —
      # saw a CHANGED string and reported "marked position" over a request it had wrecked.
      between = "a=&bin=" + String.new(tail) # cursor 2, wedged between `=` and `&`
      T.mark_word(between, 2).to_slice.to_a.should eq(between.to_slice.to_a)
    end

    it "strip_marker keeps the bytes around the marker it removes" do
      src = "a=§v§ bin=" + String.new(tail)
      stripped, caret = T.strip_marker(src, {2, 5})
      stripped.should start_with("a=v bin=")
      keeps_tail.call(stripped).should be_true
      stripped.bytesize.should eq(src.bytesize - 4)
      caret.should eq(3)
    end

    it "set_chain keeps the bytes around the marker it edits" do
      src = "a=§v§ bin=" + String.new(tail)
      out_text = T.set_chain(src, 3, "base64-encode").not_nil!
      keeps_tail.call(out_text).should be_true
      T.parse(out_text).positions[0].chain.should eq("base64-encode")
    end

    # COMPLEMENT: valid UTF-8 — including multibyte — must behave exactly as before.
    it "is unchanged on valid multibyte text" do
      T.mark_word("이름=관리자", 4).should eq("이름=§관리자§")
      T.mark_word("emoji=🐿️x", 6).should eq("emoji=§🐿️x§")
      T.mark_word("user=admin", 7).should eq("user=§admin§")
      T.mark_word("user=§admin§", 8).should eq("user=admin")
      T.mark_word("tok=§secret¦base64-encode§", 8).should eq("tok=secret")
      T.strip_marker("a=§v¦b64§b", {2, 9}).should eq({"a=vb", 3})
      T.set_chain("a=§v§b", 3, "rot13").should eq("a=§v¦rot13§b")
    end

    # CONTROL: `auto_mark` was already byte-safe (it slices the String rather than walking
    # its chars) and must stay that way — it is the shape the three above now mirror.
    it "auto_mark stays byte-safe" do
      src = "POST /x?a=1 HTTP/1.1\r\nHost: h\r\n\r\nq=" + String.new(tail)
      marked = T.auto_mark(src)
      keeps_tail.call(marked).should be_true
      marked.should contain("?a=§1§ HTTP/1.1")
    end
  end
end
