require "../../spec_helper"

# `HeaderList#lists?` — "does this list-valued field carry this token", the one home for a
# question two connection-lifetime decisions turn on (`Connection`, and the WebSocket
# handshake's `Upgrade`).
#
# Its whole reason to exist is the field LINE dimension. RFC 9110 §5.3 makes repeated field
# lines of a list-valued field exactly equivalent to one comma-joined line, and both callers
# used to ask `get?` — the LAST line — so a token sitting in an earlier one was invisible.
private def headers(*pairs : {String, String}) : Gori::Proxy::Codec::HeaderList
  list = Gori::Proxy::Codec::HeaderList.new
  pairs.each { |(n, v)| list << Gori::Proxy::Codec::Header.new(n, v) }
  list
end

describe Gori::Proxy::Codec::HeaderList do
  describe "#lists?" do
    it "reads every field line of the name, not only the last" do
      # The order that used to answer correctly…
      headers({"Connection", "keep-alive"}, {"Connection", "close"})
        .lists?("Connection", "close").should be_true
      # …and the one that did not: `get?` returns "keep-alive" and the close was lost.
      headers({"Connection", "close"}, {"Connection", "keep-alive"})
        .lists?("Connection", "close").should be_true
      headers({"Upgrade", "websocket"}, {"Upgrade", "h2c"})
        .lists?("Upgrade", "websocket").should be_true
    end

    it "splits one line's comma list and trims OWS around each member" do
      headers({"Connection", "keep-alive, close"}).lists?("Connection", "close").should be_true
      headers({"Connection", "TE,\tclose ,foo"}).lists?("Connection", "close").should be_true
      headers({"Connection", "keep-alive"}).lists?("Connection", "close").should be_false
    end

    it "matches the field NAME and the TOKEN case-insensitively" do
      headers({"CONNECTION", "Close"}).lists?("Connection", "close").should be_true
      headers({"upgrade", "WebSocket"}).lists?("Upgrade", "websocket").should be_true
    end

    it "matches a WHOLE member, never a substring of one" do
      # `Connection: no-close` and `Connection: closely` are not `close`; a substring test
      # here would park (or tear down) a connection on a token the peer never sent.
      headers({"Connection", "no-close"}).lists?("Connection", "close").should be_false
      headers({"Connection", "closely"}).lists?("Connection", "close").should be_false
      headers({"Upgrade", "websocket-draft"}).lists?("Upgrade", "websocket").should be_false
    end

    it "answers false for an absent field, an empty value and empty members" do
      headers({"Host", "a.test"}).lists?("Connection", "close").should be_false
      headers({"Connection", ""}).lists?("Connection", "close").should be_false
      headers({"Connection", " , , "}).lists?("Connection", "close").should be_false
      headers({"Connection", ",close,"}).lists?("Connection", "close").should be_true
    end
  end
end
