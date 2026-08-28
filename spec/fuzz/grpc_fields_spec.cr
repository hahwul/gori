require "../spec_helper"
require "../support/demo_descriptor"
require "file_utils"

private alias Fuzz = Gori::Fuzz
private alias Protobuf = Gori::Protobuf
private alias Grpc = Gori::Proxy::H2::Grpc

# A gRPC request carrying `msg` as its single unary frame, in the shape a `--flow` seed
# arrives in: wire CRLF, and every `§` the CAPTURED bytes happen to carry escaped to `§§` so
# the site's own text is not swept (`Template.escape_literal_markers`, which every seed path
# runs). `extra` is head text the EXAMPLE typed, so it is left alone — a `§…§` there is a
# marked position, which is exactly what a seeded-then-marked template looks like.
private def grpc_request(msg : Bytes, *, path : String = "/demo.Users/GetUser",
                         content_type : String = "application/grpc",
                         extra : String = "") : String
  # A real seed runs `Template.escape_literal_markers` over the capture, so a `§` the site's
  # own bytes carry becomes the `§§` literal rather than an unmarked position. The reference
  # message carries none, so the escape is an identity here and the bytes stay comparable.
  frame = Fuzz::Template.escape_literal_markers(Grpc.frame(false, msg))
  frame.should eq(Grpc.frame(false, msg))
  head = "POST #{path} HTTP/1.1\r\nHost: api.test\r\ncontent-type: #{content_type}\r\n" \
         "#{extra}content-length: #{frame.size}\r\n\r\n"
  io = IO::Memory.new
  io.write(head.to_slice)
  io.write(frame)
  String.new(io.to_slice)
end

# `a` then `b` in one slice — a couple of examples splice a deliberately-odd tail onto the
# reference message and need the bytes, not a String.
private def concat_bytes(*parts : Bytes) : Bytes
  io = IO::Memory.new
  parts.each { |p| io.write(p) }
  io.to_slice
end

# Does `haystack` carry `needle` as a contiguous run? The tag+payload of ONE re-encoded field
# inside a message whose other fields were copied through.
private def carries?(haystack : Bytes, needle : Bytes) : Bool
  return false if needle.size > haystack.size
  (0..(haystack.size - needle.size)).any? { |i| haystack[i, needle.size] == needle }
end

private def demo_user_bytes : Bytes
  Base64.decode(DEMO_USER_B64)
end

# A one-field `demo.User` — `name` only — for the examples that need `demo.User`'s own
# declarations over a message small enough to compare whole.
private def demo_user_name_message : Bytes
  Protobuf::Encoder.length_delimited(2_u32, "hahwul".to_slice)
end

private def demo_request_bytes : Bytes
  # `demo.GetUserRequest{name: "hahwul"}` — field 1, length-delimited.
  Protobuf::Encoder.length_delimited(1_u32, "hahwul".to_slice)
end

# Run `blk` with the demo descriptor set published as the process's schema registry.
private def with_demo_schema(&)
  dir = File.tempname("gori-fuzz-protos")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
  Protobuf::Schemas.apply(dir)
  yield
ensure
  Protobuf::Schemas.clear
  FileUtils.rm_rf(dir) if dir
end

private def build_template(text : String, specs : Array(String)) : Fuzz::GrpcFieldTemplate
  base = Fuzz::Template.parse(text)
  baseline, spans = base.render_spans(base.default_payloads)
  Fuzz::GrpcFieldTemplate.build(base, baseline, spans, specs,
    Gori::Outbound.request_target(baseline)).not_nil!
end

# `demo.User` bound as an rpc REQUEST message. The fixture's only rpc takes a one-field
# `GetUserRequest`, and the type variety this feature exists for (int64 / sint32 / enum /
# packed / bytes / nested) lives in `User` — which is why `build` takes a Binding as well as a
# path, for the reason `RepeaterView.grpc_form_rows` is class-level.
private def user_binding : Gori::Protobuf::Schemas::Binding
  s = demo_schema
  Gori::Protobuf::Schemas::Binding.new(s, s.method?("/demo.Users/GetUser").not_nil!,
    s.message?("demo.User").not_nil!, true)
end

private def build_user_template(text : String, specs : Array(String)) : Fuzz::GrpcFieldTemplate
  base = Fuzz::Template.parse(text)
  baseline, spans = base.render_spans(base.default_payloads)
  Fuzz::GrpcFieldTemplate.build(base, baseline, spans, specs, user_binding)
end

# The rendered request's single gRPC message payload — what the origin would parse.
private def rendered_message(bytes : Bytes) : Bytes
  body = Fuzz::GrpcVerdict.body(bytes).not_nil!
  msgs, residual = Grpc.scan(body)
  residual.should eq(0)
  msgs.size.should eq(1)
  msgs[0].data
end

private def build_plan(text : String, specs : Array(String),
                       sources : Array(Fuzz::PayloadSource)? = nil,
                       config : Fuzz::Config = Fuzz::Config.new) : Fuzz::Plan
  Fuzz::Plan.build(
    Fuzz::PlanOptions.new(text,
      evidence: true,
      default_target: "https://api.test",
      sources: sources || [Fuzz::InlineList.new(["zz"])] of Fuzz::PayloadSource,
      config: config, grpc_fields: specs),
    ungated_outbound)
end

describe Fuzz::GrpcFieldTemplate do
  describe "resolving a spec through the same Lens the Repeater form reads" do
    it "resolves a scalar by name, by number and through a nested message" do
      s = demo_schema
      t = s.message?("demo.User").not_nil!
      m = demo_user_message
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "name").defn.name.should eq("name")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "3").defn.name.should eq("role")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "profile.age").defn.name.should eq("age")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "outer.inner.label").defn.name.should eq("label")
    end

    it "seeds the position with the capture's own value, in the encoder's own syntax" do
      s = demo_schema
      t = s.message?("demo.User").not_nil!
      m = demo_user_message
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "name").seed.should eq("hahwul")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "role").seed.should eq("ROLE_ADMIN")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "delta").seed.should eq("-3")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "id").seed.should eq("-7")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "scores").seed.should eq("1, 2, 300")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "token").seed.should eq("de ad be ef")
    end

    it "carries the packed flag off the WIRE, not off the schema" do
      s = demo_schema
      t = s.message?("demo.User").not_nil!
      Fuzz::GrpcFieldTemplate.resolve(s, t, demo_user_message, "scores").packed?.should be_true
      Fuzz::GrpcFieldTemplate.resolve(s, t, demo_user_message, "name").packed?.should be_false
    end

    it "picks an occurrence of a repeated field with [i]" do
      s = demo_schema
      t = s.message?("demo.Profile").not_nil!
      m = demo_user_message.fields.find { |f| f.number == 4 }.not_nil!.message.not_nil!
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "tags[0]").seed.should eq("red")
      Fuzz::GrpcFieldTemplate.resolve(s, t, m, "tags[1]").seed.should eq("blue")
    end

    it "splits a ¦chain off the spec, the same delimiter §value¦chain§ uses" do
      s = demo_schema
      t = s.message?("demo.User").not_nil!
      pos = Fuzz::GrpcFieldTemplate.resolve(s, t, demo_user_message, "name¦base64-encode")
      pos.spec.should eq("name")
      pos.chain.should eq("base64-encode")
    end

    describe "refusals — the line #837 draws for its form, drawn again" do
      it "refuses an UNDECLARED field number and says there is no declaration" do
        s = demo_schema
        t = s.message?("demo.User").not_nil!
        extra = Protobuf::Encoder.length_delimited(99_u32, Bytes[1, 2, 3])
        m = Protobuf.decode(concat_bytes(demo_user_bytes, extra))
        expect_raises(Fuzz::GrpcFieldError, /does not declare field 99/) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, m, "99")
        end
      end

      it "refuses a field whose wire type the schema contradicts, naming both sides" do
        s = demo_schema
        t = s.message?("demo.User").not_nil!
        # field 2 is `string name`; send it as a varint.
        m = Protobuf.decode(Bytes[0x10, 0x07])
        expect_raises(Fuzz::GrpcFieldError, /schema declares name as string, but the wire carries a varint/) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, m, "name")
        end
      end

      it "refuses a message field as a leaf and points at the fields inside it" do
        s = demo_schema
        t = s.message?("demo.User").not_nil!
        expect_raises(Fuzz::GrpcFieldError, /profile\.<field>/) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, demo_user_message, "profile")
        end
      end

      it "refuses descending into a scalar" do
        s = demo_schema
        t = s.message?("demo.User").not_nil!
        expect_raises(Fuzz::GrpcFieldError, /not a\s+message/) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, demo_user_message, "name.inner")
        end
      end

      it "lists the fields the message DOES carry when a name does not resolve" do
        s = demo_schema
        t = s.message?("demo.User").not_nil!
        ex = expect_raises(Fuzz::GrpcFieldError) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, demo_user_message, "rolle")
        end
        ex.message.not_nil!.should contain("role")
        ex.message.not_nil!.should contain("profile")
      end

      it "refuses an out-of-range occurrence rather than silently taking the first" do
        s = demo_schema
        t = s.message?("demo.Profile").not_nil!
        m = demo_user_message.fields.find { |f| f.number == 4 }.not_nil!.message.not_nil!
        expect_raises(Fuzz::GrpcFieldError, /\[2\] is out of range \(0\.\.1\)/) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, m, "tags[2]")
        end
      end

      it "refuses a truncated packed run — seeding it would drop the leftover octets" do
        s = demo_schema
        t = s.message?("demo.User").not_nil!
        # field 6 (packed repeated int32) declaring 2 bytes but ending mid-varint.
        m = Protobuf.decode(Bytes[0x32, 0x02, 0x01, 0x80])
        expect_raises(Fuzz::GrpcFieldError, /mid-element/) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, m, "scores")
        end
      end

      it "refuses a string carrying a control byte — the row escapes it, the wire would not" do
        s = demo_schema
        t = s.message?("demo.User").not_nil!
        m = Protobuf.decode(Protobuf::Encoder.length_delimited(2_u32, Bytes[0x61, 0x0a, 0x62]))
        expect_raises(Fuzz::GrpcFieldError, /no single-line value/) do
          Fuzz::GrpcFieldTemplate.resolve(s, t, m, "name")
        end
      end
    end
  end

  describe "building over a request" do
    it "refuses a template that does not declare gRPC" do
      with_demo_schema do
        text = "POST /demo.Users/GetUser HTTP/1.1\r\nHost: api.test\r\ncontent-type: application/json\r\n\r\n{}"
        expect_raises(Fuzz::GrpcFieldError, /needs a gRPC request/) { build_template(text, ["name"]) }
      end
    end

    it "refuses grpc-web-text, whose frames are base64 on the wire" do
      with_demo_schema do
        text = grpc_request(demo_request_bytes, content_type: "application/grpc-web-text")
        expect_raises(Fuzz::GrpcFieldError, /grpc-web-text/) { build_template(text, ["name"]) }
      end
    end

    it "refuses a seed whose framing is already broken — that mis-framing is the test" do
      with_demo_schema do
        good = grpc_request(demo_request_bytes)
        text = good + "\x00\x00" # a tail that is not a complete frame
        expect_raises(Fuzz::GrpcFieldError, /does not frame cleanly/) { build_template(text, ["name"]) }
      end
    end

    it "refuses a client-streaming body: which message a payload belongs to has no answer" do
      with_demo_schema do
        two = IO::Memory.new
        two.write(Grpc.frame(false, demo_request_bytes))
        two.write(Grpc.frame(false, demo_request_bytes))
        frame = two.to_slice
        head = "POST /demo.Users/GetUser HTTP/1.1\r\nHost: api.test\r\n" \
               "content-type: application/grpc\r\ncontent-length: #{frame.size}\r\n\r\n"
        io = IO::Memory.new
        io.write(head.to_slice)
        io.write(frame)
        expect_raises(Fuzz::GrpcFieldError, /unary-only/) do
          build_template(String.new(io.to_slice), ["name"])
        end
      end
    end

    it "refuses a COMPRESSED message — the same carve-out every other gRPC pane makes" do
      with_demo_schema do
        frame = Grpc.frame(true, demo_request_bytes)
        head = "POST /demo.Users/GetUser HTTP/1.1\r\nHost: api.test\r\n" \
               "content-type: application/grpc\r\ncontent-length: #{frame.size}\r\n\r\n"
        io = IO::Memory.new
        io.write(head.to_slice)
        io.write(frame)
        expect_raises(Fuzz::GrpcFieldError, /COMPRESSED/) do
          build_template(String.new(io.to_slice), ["name"])
        end
      end
    end

    it "refuses when no descriptor set resolves the rpc" do
      text = grpc_request(demo_request_bytes)
      Protobuf::Schemas.clear
      expect_raises(Fuzz::GrpcFieldError, /no descriptor set resolves/) { build_template(text, ["name"]) }
    end

    it "refuses a §…§ position that lands in the gRPC body beside a field position" do
      with_demo_schema do
        # `--auto`'s urlencoded sniff can carve one out of a protobuf payload by accident.
        text = grpc_request(demo_request_bytes)
        head, _, body = text.partition("\r\n\r\n")
        marked = "#{head}\r\n\r\n#{body[0, 2]}§#{body[2..]}§"
        expect_raises(Fuzz::GrpcFieldError, /cannot combine with a field position/) do
          build_template(marked, ["name"])
        end
      end
    end

    it "refuses two specs naming the same occurrence" do
      with_demo_schema do
        text = grpc_request(demo_request_bytes)
        expect_raises(Fuzz::GrpcFieldError, /name the same field occurrence/) do
          build_template(text, ["name", "1"])
        end
      end
    end
  end

  describe "rendering (P7: everything not fuzzed is copied)" do
    it "reproduces the capture byte-for-byte when every position carries its default" do
      text = grpc_request(demo_user_bytes, path: "/demo.Users/GetUser")
      tmpl = build_user_template(text, ["id"])
      rendered, _, err = tmpl.render_spans(tmpl.default_payloads)
      err.should be_nil
      rendered.should eq(text.to_slice)
    end

    it "copies an undeclared field, a group and a truncated tail through untouched" do
      io = IO::Memory.new
      io.write(demo_user_bytes)
      io.write(Protobuf::Encoder.length_delimited(99_u32, Bytes[0xde, 0xad])) # undeclared
      io.write(Bytes[0xa3, 0x06, 0x08, 0x01, 0xa4, 0x06])                     # group 100 { 1: 1 }
      io.write(Bytes[0x81, 0x80])                                             # truncated tail
      seeded = io.to_slice
      text = grpc_request(seeded)
      tmpl = build_user_template(text, ["name"])
      rendered, _, err = tmpl.render_spans(["hahwul"])
      err.should be_nil
      rendered.should eq(text.to_slice)
      # …and with a DIFFERENT payload every byte outside the edited field still survives.
      changed = rendered_message(tmpl.render_spans(["zz"])[0])
      changed[(changed.size - 8)..].should eq(seeded[(seeded.size - 8)..])
    end

    it "keeps a NON-MINIMAL varint some other producer emitted" do
      # field 1 (`id`, int64) as a 2-byte NON-MINIMAL varint for the value 1, beside `name`.
      # A canonical encoder would emit `08 01`; this producer padded it, and re-encoding
      # `name` must not quietly repair the field beside it.
      odd = concat_bytes(Bytes[0x08, 0x81, 0x00],
        Protobuf::Encoder.length_delimited(2_u32, "hahwul".to_slice))
      text = grpc_request(odd)
      tmpl = build_user_template(text, ["name"])
      rendered, _, err = tmpl.render_spans(["hahwul"])
      err.should be_nil
      rendered.should eq(text.to_slice)
    end
  end

  describe "the type is the point" do
    it "encodes the same text differently per declaration" do
      text = grpc_request(demo_user_bytes)
      as_sint = build_user_template(text, ["delta"]) # sint32 → zigzag, one byte
      as_int = build_user_template(text, ["id"])     # int64 → sign-extended, ten bytes
      sint_msg = rendered_message(as_sint.render_spans(["-3"])[0])
      int_msg = rendered_message(as_int.render_spans(["-3"])[0])
      # sint32 -3 is `05`; int64 -3 is `fd ff ff ff ff ff ff ff ff 01`.
      carries?(sint_msg, Bytes[0x50, 0x05]).should be_true
      carries?(int_msg, Bytes[0x08, 0xfd, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01]).should be_true
    end

    it "takes an enum by NAME and by number" do
      text = grpc_request(demo_user_bytes)
      tmpl = build_user_template(text, ["role"])
      carries?(rendered_message(tmpl.render_spans(["ROLE_USER"])[0]), Bytes[0x18, 0x01]).should be_true
      carries?(rendered_message(tmpl.render_spans(["2"])[0]), Bytes[0x18, 0x02]).should be_true
    end

    it "re-emits a packed run packed" do
      text = grpc_request(demo_user_bytes)
      tmpl = build_user_template(text, ["scores"])
      msg = rendered_message(tmpl.render_spans(["7, 8"])[0])
      carries?(msg, Bytes[0x32, 0x02, 0x07, 0x08]).should be_true
    end

    it "reports — and does not send silently — a payload the declaration cannot hold" do
      text = grpc_request(demo_user_bytes)
      tmpl = build_user_template(text, ["id"])
      rendered, _, err = tmpl.render_spans(["abc"])
      err.not_nil!.should contain("is not an integer")
      # the field keeps the CAPTURE's own octets
      rendered.should eq(text.to_slice)
    end
  end

  describe "provenance: the payload spans a send seam must not rewrite" do
    # `Job#payload_spans` is what keeps `Fuzz::Sender` from expanding `$NAME` inside a payload
    # at the send seam — without it a payload of `$SESSION` goes out as the live credential
    # instead of as those eight characters. A typed field's payload has no span of its own (it
    # is octets inside a re-encoded message), so the exclusion is drawn around the message.
    it "marks the whole gRPC message, beside the head's own spans" do
      text = grpc_request(demo_user_name_message)
      tmpl = build_user_template(text, ["name"])
      rendered, spans, _ = tmpl.render_spans(["$SESSION"])
      spans.size.should eq(1)
      a, b = spans[0]
      b.should eq(rendered.size)
      String.new(rendered[a, b - a]).should contain("$SESSION")
      String.new(rendered[0, a]).should contain("Host: api.test") # the head is NOT excluded
    end

    it "keeps the head positions' own spans when both kinds are in play" do
      text = grpc_request(demo_user_name_message, extra: "x-key: §K§\r\n")
      tmpl = build_user_template(text, ["name"])
      rendered, spans, _ = tmpl.render_spans(["hdr", "body"])
      spans.size.should eq(2)
      String.new(rendered[spans[0][0], spans[0][1] - spans[0][0]]).should eq("hdr")
      spans[1][1].should eq(rendered.size)
    end
  end

  describe "framing" do
    it "recomputes the 5-byte prefix for a message that grew" do
      with_demo_schema do
        text = grpc_request(demo_request_bytes)
        tmpl = build_template(text, ["name"])
        rendered, _, _ = tmpl.render_spans(["a-much-longer-name-than-before"])
        body = Fuzz::GrpcVerdict.body(rendered).not_nil!
        msgs, residual = Grpc.scan(body)
        residual.should eq(0)
        msgs.size.should eq(1)
        msgs[0].data.size.should eq(body.size - 5)
      end
    end

    it "recomputes it for a message that shrank" do
      with_demo_schema do
        text = grpc_request(demo_request_bytes)
        tmpl = build_template(text, ["name"])
        rendered, _, _ = tmpl.render_spans([""])
        Fuzz::GrpcVerdict.residual(rendered).should eq(0)
      end
    end
  end
end

describe "Fuzz::Plan with gRPC field positions" do
  it "puts field positions after the template's own §…§ positions" do
    with_demo_schema do
      text = grpc_request(demo_request_bytes, extra: "x-key: §K§\r\n")
      plan = build_plan(text, ["name"])
      plan.template.position_count.should eq(1) # the header
      plan.position_count.should eq(2)          # + the field
      plan.grpc_fields.not_nil!.fields.map(&.spec).should eq(["name"])
      plan.grpc_fields.not_nil!.method_path.should eq("/demo.Users/GetUser")
      plan.grpc_fields.not_nil!.message_type.should eq("demo.GetUserRequest")
    end
  end

  it "makes a field position the ONLY position a run needs" do
    with_demo_schema do
      plan = build_plan(grpc_request(demo_request_bytes), ["name"])
      plan.position_count.should eq(1)
      plan.total.should eq(1_i64)
    end
  end

  it "leaves a run with no field position byte-identical to what it always was" do
    with_demo_schema do
      text = grpc_request(demo_request_bytes, extra: "x-key: §K§\r\n")
      plan = build_plan(text, [] of String)
      plan.grpc_fields.should be_nil
      plan.generator.baseline_raw.should eq(Fuzz::Template.parse(text).render(["K"]))
    end
  end

  it "refuses a payload the declaration cannot hold BEFORE the first dial" do
    with_demo_schema do
      # `string` is UTF-8 by declaration, so these bytes are a payload it cannot hold.
      sources = [Fuzz::InlineList.new(["ok", String.new(Bytes[0xff, 0xfe])])] of Fuzz::PayloadSource
      expect_raises(Fuzz::GrpcFieldError, /not valid UTF-8/) do
        build_plan(grpc_request(demo_request_bytes), ["name"], sources)
      end
    end
  end

  it "accepts a payload set the declaration CAN hold" do
    with_demo_schema do
      sources = [Fuzz::InlineList.new(["a", "b", "c"])] of Fuzz::PayloadSource
      build_plan(grpc_request(demo_request_bytes), ["name"], sources).total.should eq(3_i64)
    end
  end

  it "names the payload and the type when a NUMERIC declaration cannot hold it" do
    text = grpc_request(demo_user_bytes)
    tmpl = build_user_template(text, ["id"])
    sets = [Fuzz::PayloadSet.new(Fuzz::InlineList.new(["1", "2", "not-a-number"]))]
    ex = expect_raises(Fuzz::GrpcFieldError) do
      tmpl.refuse_unencodable(sets, 0, Gori::Decoder.shared_registry)
    end
    ex.message.not_nil!.should contain(%(cannot hold payload "not-a-number"))
    ex.message.not_nil!.should contain("int64")
  end

  it "lets a set the declaration CAN hold through, whatever its spelling" do
    text = grpc_request(demo_user_bytes)
    tmpl = build_user_template(text, ["id"])
    sets = [Fuzz::PayloadSet.new(Fuzz::InlineList.new(["1", "-2", "0x10", "9_000"]))]
    tmpl.refuse_unencodable(sets, 0, Gori::Decoder.shared_registry)
  end

  # The ambiguity #843 asks to settle: a chain over a TYPED value could transform the text or
  # the wire bytes. It transforms the TEXT, so the declaration still describes the octets that
  # go out. Driven through the generator rather than the composite, because the ORDER is the
  # claim and `Generator#emit` is where it is decided (chains, then the splice).
  it "runs a ¦chain over the payload BEFORE the declared type encodes it" do
    with_demo_schema do
      sources = [Fuzz::InlineList.new(["hi"])] of Fuzz::PayloadSource
      plan = build_plan(grpc_request(demo_request_bytes), ["name¦base64-encode"], sources)
      job = nil.as(Fuzz::Job?)
      plan.generator.each { |j| job = j }
      j = job.not_nil!
      j.chain_error.should be_nil
      # base64 of "hi" is "aGk=", and THAT string is what the `string` field carries — not the
      # base64 of the field's own `tag+len+"hi"` octets, which no declaration would describe.
      rendered_message(j.bytes).should eq(
        Protobuf::Encoder.length_delimited(1_u32, "aGk=".to_slice))
    end
  end

  it "refuses --race beside a field position" do
    with_demo_schema do
      expect_raises(Fuzz::GrpcFieldError, /--race/) do
        build_plan(grpc_request(demo_request_bytes), ["name"],
          config: Fuzz::Config.new(race_count: 4))
      end
    end
  end

  it "sweeps the field through the generator, framing every request" do
    with_demo_schema do
      sources = [Fuzz::InlineList.new(["a", "much-longer-value", ""])] of Fuzz::PayloadSource
      plan = build_plan(grpc_request(demo_request_bytes), ["name"], sources)
      jobs = [] of Fuzz::Job
      plan.generator.each { |j| jobs << j }
      jobs.size.should eq(3)
      jobs.each do |j|
        Fuzz::GrpcVerdict.residual(j.bytes).should eq(0)
        j.chain_error.should be_nil
      end
      rendered_message(jobs[1].bytes).should eq(
        Protobuf::Encoder.length_delimited(1_u32, "much-longer-value".to_slice))
      # The head outside the marked positions is copied through — only the length declaration
      # follows the body it now describes.
      String.new(jobs[1].bytes).should contain("Host: api.test")
    end
  end

  it "resyncs Content-Length to the re-encoded body" do
    with_demo_schema do
      sources = [Fuzz::InlineList.new(["much-longer-value"])] of Fuzz::PayloadSource
      plan = build_plan(grpc_request(demo_request_bytes), ["name"], sources)
      job = nil.as(Fuzz::Job?)
      plan.generator.each { |j| job = j }
      bytes = job.not_nil!.bytes
      body = Fuzz::GrpcVerdict.body(bytes).not_nil!
      String.new(bytes).downcase.should contain("content-length: #{body.size}")
    end
  end

  it "keeps a header §…§ position working beside a field position" do
    with_demo_schema do
      text = grpc_request(demo_request_bytes, extra: "x-key: §K§\r\n")
      sources = [Fuzz::InlineList.new(["p1"])] of Fuzz::PayloadSource
      plan = build_plan(text, ["name"], sources,
        config: Fuzz::Config.new(mode: Fuzz::Mode::BatteringRam))
      job = nil.as(Fuzz::Job?)
      plan.generator.each { |j| job = j }
      bytes = job.not_nil!.bytes
      String.new(bytes).should contain("x-key: p1")
      rendered_message(bytes).should eq(Protobuf::Encoder.length_delimited(1_u32, "p1".to_slice))
    end
  end

  it "calibrates without asking a typed field to hold a nonce" do
    with_demo_schema do
      text = grpc_request(demo_request_bytes, extra: "x-key: §K§\r\n")
      plan = build_plan(text, ["name"])
      samples = plan.generator.calibration_requests(2)
      samples.size.should eq(2)
      samples.each_with_index do |(bytes, plen), i|
        Fuzz::GrpcVerdict.residual(bytes).should eq(0)
        # ONE nonceable position (the header), so the injected length is one nonce long — the
        # typed field is not counted, because it was not filled with one.
        plen.should eq(Fuzz::Generator::CALIBRATION_BASE_LEN + i * Fuzz::Generator::CALIBRATION_STEP)
        # …and it kept the capture's own value.
        rendered_message(bytes).should eq(demo_request_bytes)
      end
    end
  end
end
