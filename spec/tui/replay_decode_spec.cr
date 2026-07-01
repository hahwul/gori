require "../spec_helper"
require "base64"
require "uri"
require "json"

include Gori::Tui

# A minimal Complete FlowDetail from raw head/body (no DB), enough to drive the
# split-decode Replay path (load_saml / load_graphql read only these bytes).
private def detail_of(target : String, head : String, body : String)
  row = Gori::Store::FlowRow.new(
    id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test",
    port: 443, target: target, status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head.to_slice, body.to_slice, nil, nil)
end

private def move_to_line_end(view : ReplayView)
  # A toggle/refresh leaves the caret at the top (line 1 = the query / single-line XML);
  # edit_end reaches its end WITHOUT an ↑ move (which would cross back to the envelope).
  view.edit_end
end

private def load_gql(head : String, body : String) : ReplayView
  detail = detail_of("/graphql", head, body)
  op = Gori::Graphql.from_flow("/graphql", head.to_slice, body.to_slice).not_nil!
  view = ReplayView.new
  view.load_graphql(detail, op)
  view
end

describe "ReplayView split-decode (SAML/GraphQL)" do
  before_each { Gori::Settings.pretty_bodies_default = false }

  describe "GraphQL" do
    gql_body = %({"query":"query Q { a }","variables":{"x":1}})
    gql_head = "POST /graphql HTTP/1.1\r\nHost: api.test\r\nContent-Type: application/json\r\nContent-Length: #{gql_body.bytesize}\r\n\r\n"

    it "opens on the ENVELOPE sub-pane with the full request editable" do
      view = load_gql(gql_head, gql_body)
      view.decode_mode?.should be_true
      view.req_pane.should eq(:envelope)
      view.focus.should eq(:request)
    end

    it "sends the request byte-faithfully when the decoded payload is untouched" do
      body_sent = String.new(load_gql(gql_head, gql_body).request_bytes).split("\r\n\r\n", 2)[1]
      JSON.parse(body_sent)["query"].as_s.should eq("query Q { a }") # unchanged
    end

    it "commits an edited decoded query back into the envelope JSON on ^T switch" do
      view = load_gql(gql_head, gql_body)
      view.toggle_req_pane.should eq(:decoded)
      move_to_line_end(view)
      " EDITED".each_char { |c| view.edit_insert(c) }
      view.toggle_req_pane.should eq(:envelope) # commit
      body = String.new(view.request_bytes).split("\r\n\r\n", 2)[1]
      j = JSON.parse(body)
      j["query"].as_s.should contain("EDITED") # the decoded edit reached the envelope body
      j["variables"]["x"].as_i.should eq(1)    # untouched variables survive
    end

    it "commits a decoded edit even without switching (on send)" do
      view = load_gql(gql_head, gql_body)
      view.toggle_req_pane
      move_to_line_end(view)
      " ONSEND".each_char { |c| view.edit_insert(c) }
      body = String.new(view.request_bytes).split("\r\n\r\n", 2)[1] # request_bytes commits first
      JSON.parse(body)["query"].as_s.should contain("ONSEND")
    end

    it "rewrites the URL query (not a phantom body) when the GraphQL op is GET-bound" do
      get_target = "/graphql?query=#{URI.encode_www_form("query Q { a }")}"
      get_head = "GET #{get_target} HTTP/1.1\r\nHost: api.test\r\n\r\n"
      detail = detail_of(get_target, get_head, "")
      op = Gori::Graphql.from_flow(get_target, get_head.to_slice, nil).not_nil!
      view = ReplayView.new
      view.load_graphql(detail, op)

      view.toggle_req_pane.should eq(:decoded)
      move_to_line_end(view)
      " EDITED".each_char { |c| view.edit_insert(c) }
      raw = String.new(view.request_bytes) # commits on send
      raw.should_not contain(%("query":))  # the edit must NOT be spliced into a phantom JSON body
      qs = raw.each_line.first.split(' ')[1].split('?', 2)[1]
      URI::Params.parse(qs)["query"].should contain("EDITED") # it reached the URL query
    end

    it "reflects an envelope-side query edit into DECODED, then merges a decoded edit (bidirectional)" do
      view = load_gql(gql_head, gql_body)
      # Edit the ENVELOPE directly: a new body whose query mentions ENVEDIT.
      view.replace_request("POST /graphql HTTP/1.1\nContent-Type: application/json\n\n" + %({"query":"query ENVEDIT { z }","variables":{"x":1}}))
      view.toggle_req_pane # → DECODED: refresh pulls the envelope's query out
      move_to_line_end(view)
      " PLUS".each_char { |c| view.edit_insert(c) } # decoded query gains PLUS
      view.toggle_req_pane                          # → ENVELOPE: commit merges it back
      q = JSON.parse(String.new(view.request_bytes).split("\r\n\r\n", 2)[1])["query"].as_s
      q.should contain("ENVEDIT") # the envelope edit reached decoded
      q.should contain("PLUS")    # the decoded edit merged back
    end
  end

  describe "SAML" do
    xml = %(<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="_x"><saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">https://idp.test/m</saml:Issuer></samlp:Response>)
    saml_body = "SAMLResponse=#{URI.encode_www_form(Base64.strict_encode(xml))}&RelayState=#{URI.encode_www_form("/dash")}"
    saml_head = "POST /acs HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: #{saml_body.bytesize}\r\n\r\n"

    it "re-encodes an edited XML into the param, preserving RelayState + resyncing CL" do
      detail = detail_of("/acs", saml_head, saml_body)
      doc = Gori::Saml.from_flow("/acs", saml_head.to_slice, saml_body.to_slice, nil, nil).not_nil!
      view = ReplayView.new
      view.load_saml(detail, doc)

      view.toggle_req_pane.should eq(:decoded)
      move_to_line_end(view) # end of the (single-line) XML
      "<!--x-->".each_char { |c| view.edit_insert(c) }
      view.toggle_req_pane

      raw = String.new(view.request_bytes)
      head, _, body = raw.partition("\r\n\r\n")
      body.should contain("RelayState=#{URI.encode_www_form("/dash")}") # sibling survives
      # Content-Length resynced to the new (longer) body
      cl = head.each_line.find(&.downcase.starts_with?("content-length:")).not_nil!.split(':')[1].strip.to_i
      cl.should eq(body.bytesize)
      # the re-encoded SAMLResponse decodes back to the edited XML
      pair = body.split('&').find(&.starts_with?("SAMLResponse=")).not_nil!
      decoded = Gori::Saml.decode_value(URI.decode_www_form(pair.split('=', 2)[1])).not_nil!
      decoded[0].should contain("<!--x-->")
    end
  end

  describe "vertical arrow-crossing between the split sub-panes" do
    gql_body = %({"query":"query Q { a }"})
    gql_head = "POST /graphql HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: #{gql_body.bytesize}\r\n\r\n"

    it "↓ off the ENVELOPE bottom crosses to DECODED; ↑ off the DECODED top crosses back" do
      detail = detail_of("/graphql", gql_head, gql_body)
      op = Gori::Graphql.from_flow("/graphql", gql_head.to_slice, gql_body.to_slice).not_nil!
      view = ReplayView.new
      view.load_graphql(detail, op)

      view.edit_move(999, 0) # to the ENVELOPE's last line (bottom)
      view.req_pane.should eq(:envelope)
      view.edit_move(1, 0) # ↓ off the bottom → DECODED
      view.req_pane.should eq(:decoded)
      view.edit_move(-1, 0) # ↑ off the DECODED top → ENVELOPE
      view.req_pane.should eq(:envelope)
    end
  end
end
