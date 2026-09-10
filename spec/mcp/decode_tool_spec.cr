require "../spec_helper"

# The MCP `decode` tool's input and output edges.

private def call(tools : Gori::MCP::Tools, args : String) : Gori::MCP::Tools::Result
  tools.call("decode", JSON.parse(args))
end

describe "MCP decode" do
  # Raw `Base64.decode` refused a leading space or a wrapped line that the `base64-decode`
  # converter one argument over takes; the two now share the tolerant decoder.
  it "accepts input_base64 with the whitespace the base64-decode converter tolerates" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      r = call(tools, %({"input":" aG\\nk= ","spec":"hex","input_base64":true}))
      r.is_error.should be_false
      JSON.parse(r.text)["output"].as_s.should eq "6869"
      call(tools, %({"input":"!!","spec":"hex","input_base64":true})).is_error.should be_true
    end
  end

  it "never returns more than DECODER_MAX_OUTPUT bytes, even across a split multibyte char" do
    with_store do |store|
      tools = Gori::MCP::Tools.new(store, allow_actions: false, verify_upstream: false)
      cap = Gori::MCP::Tools::DECODER_MAX_OUTPUT
      (cap % 3).should_not eq 0 # so the byte cut lands INSIDE a 3-byte char
      r = call(tools, %({"input":"#{"あ" * (cap // 3 + 10)}","spec":"reverse"}))
      r.is_error.should be_false
      doc = JSON.parse(r.text)
      doc["output_truncated"].as_bool.should be_true
      doc["output"].as_s.bytesize.should be <= cap
    end
  end

  # The "a bare name ENCODED" note can only warn about a converter it can name the inverse of,
  # and it derives that inverse from a name SUFFIX — which is right for seventeen of the
  # catalog's nineteen encoders and reaches neither of the two named for what they DO
  # (`raw-deflate`, `url-encode-all`). That is what `INVERSE_NAME` is for, and this is the
  # sweep that makes the pair of them a closed set: an encoder added later with a real inverse
  # and no rule for it fails HERE, rather than going quiet in the note.
  it "can name the inverse of every ENCODE converter the catalog has one for" do
    # The genuinely one-way transforms: nothing in the catalog undoes them, so the note has
    # nothing to offer and correctly stays silent.
    one_way = %w[shell-escape powershell-escape homoglyph typo]
    reg = Gori::Decoder.default_registry
    missing = [] of String
    reg.each do |c|
      next unless c.direction.encode?
      next if one_way.includes?(c.name)
      missing << c.name unless Gori::MCP::Tools.inverse_of(reg, c.name)
    end
    missing.should be_empty
    # ...and each one-way name really has no inverse, so the list above cannot rot into a way
    # of hiding a converter whose counterpart was added later.
    one_way.each { |n| Gori::MCP::Tools.inverse_of(reg, n).should be_nil, n }
  end
end
