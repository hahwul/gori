require "../spec_helper"

# The MCP `decode` tool's input and output edges.

private def with_store(&)
  path = File.tempname("gori-mcp-decode", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

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
end
