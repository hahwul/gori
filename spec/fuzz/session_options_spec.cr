require "../spec_helper"

describe Gori::Fuzz::SessionOptions do
  it "preserves every payload processor across JSON serialization" do
    processors = [Gori::Fuzz::Prefix.new("P"), Gori::Fuzz::Suffix.new("S"),
                  Gori::Fuzz::Encode.new(:url), Gori::Fuzz::Encode.new(:url_all),
                  Gori::Fuzz::Encode.new(:base64), Gori::Fuzz::Encode.new(:hex),
                  Gori::Fuzz::Case.new(:upper), Gori::Fuzz::Case.new(:lower),
                  Gori::Fuzz::Hasher.new(:md5), Gori::Fuzz::Hasher.new(:sha1),
                  Gori::Fuzz::Hasher.new(:sha256), Gori::Fuzz::RegexReplace.new(/a/, "X")]
    processors.each do |processor|
      saved = Gori::Fuzz::SavedProcessor.capture(processor)
      restored = Gori::Fuzz::SavedProcessor.from_json(saved.to_json).build
      restored.apply("a b").should eq(processor.apply("a b"))
    end
  end

  it "preserves shaped binary WebSocket bytes, including neutral and malformed shapes" do
    shape = Gori::Proxy::WS::Shape.new(false, 0, false, Bytes[0, 1, 2, 3], 2, 999)
    message = Gori::Fuzz::WsMessageSource.new(2, String.new(Bytes[0x80, 0x00, 0xff]), shape, true)
    saved = Gori::Fuzz::SavedMessage.capture(message)
    Gori::Fuzz::SavedMessage.from_json(saved.to_json).build.should eq(message)
  end

  it "rejects unknown options and leaves malformed frame payloads inert when clearing positions" do
    expect_raises(JSON::SerializableError) do
      Gori::Fuzz::SessionOptions.from_json(%({"future_option":true}))
    end
    message = Gori::Fuzz::SavedMessage.new(1, "%%%", false, true, 0, nil, nil, 1, nil)
    message.clear_marks
    message.payload.should eq("%%%")
    expect_raises(Base64::Error) { message.build }
  end

  # The prepared tab's preview counts what the plan counts: an env value is spliced as a literal,
  # so its marker pair is no position.
  it "previews the positions Plan.build counts when an env value carries a marker pair" do
    prev = Gori::Settings.project_env_vars
    Gori::Settings.project_env_vars = [{"TOK", "ab§cd§ef"}]
    Gori::Env.bump_highlight_rev
    begin
      template = "GET /q?a=§v§ HTTP/1.1\r\nHost: t.test\r\nX-Tok: $TOK\r\n\r\n"
      options = Gori::Fuzz::PlanOptions.new(template, target: "http://t.test",
        sources: [Gori::Fuzz::InlineList.new(["1"]).as(Gori::Fuzz::PayloadSource)],
        config: Gori::Fuzz::Config.new(keep_bodies: :none), verify: false)
      preview = Gori::Fuzz::SessionOptions.capture(options).position_count(template, false, false)
      preview.should eq(Gori::Fuzz::Plan.build(options, ungated_outbound).position_count)
      preview.should eq(1)
    ensure
      Gori::Settings.project_env_vars = prev
      Gori::Env.bump_highlight_rev
    end
  end
end
