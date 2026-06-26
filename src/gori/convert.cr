require "base64"
require "./convert/converter"
require "./convert/registry"
require "./convert/codecs"
require "./convert/catalog"
require "./convert/chain"

module Gori::Convert
  # Output ceiling for any single step / decompression drain — lifted from
  # Proxy::Codec::ContentDecode::MAX_OUT (32 MiB) so a chained decompress can't bomb.
  MAX_OUT = 32 * 1024 * 1024

  # How a (possibly binary) value is rendered in the Output/pipeline panes.
  enum RenderAs
    Text
    Base64
    Hex
  end

  # Default display choice for a value: valid UTF-8 -> text, else base64 (the exact
  # decision mcp/serialize.cr makes). `prefer` overrides it (the ^X hex/base64
  # toggle). Returns the rendered string + the mode actually used.
  def self.display(data : Bytes, prefer : RenderAs? = nil) : {String, RenderAs}
    case prefer
    when RenderAs::Hex
      {data.hexstring, RenderAs::Hex}
    when RenderAs::Base64
      {Base64.strict_encode(data), RenderAs::Base64}
    else
      s = String.new(data)
      s.valid_encoding? ? {s, RenderAs::Text} : {Base64.strict_encode(data), RenderAs::Base64}
    end
  end

  def self.binary?(data : Bytes) : Bool
    !String.new(data).valid_encoding?
  end
end
