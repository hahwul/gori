require "../spec_helper"
require "../support/memory_backend"
require "base64"
require "uri"
require "json"

include Gori::Tui

# A minimal Complete FlowDetail from raw head/body (no DB), enough to drive the
# split-decode Repeater path (load_saml / load_graphql read only these bytes).
private def detail_of(target : String, head : String, body : String)
  row = Gori::Store::FlowRow.new(
    id: 1_i64, created_at: 0_i64, scheme: "https", method: "POST", host: "api.test",
    port: 443, target: target, status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head.to_slice, body.to_slice, nil, nil)
end

private def move_to_line_end(view : RepeaterView)
  # A toggle/refresh leaves the caret at the top (line 1 = the query / single-line XML);
  # edit_end reaches its end WITHOUT an ↑ move (which would cross back to the envelope).
  view.edit_end
end

private def load_gql(head : String, body : String) : RepeaterView
  detail = detail_of("/graphql", head, body)
  op = Gori::Graphql.from_flow("/graphql", head.to_slice, body.to_slice).not_nil!
  view = RepeaterView.new
  view.load_graphql(detail, op)
  view
end

# An edit made the way the operator makes it: switch to DECODED, rewrite the pane, send.
# `replace_edit_buffer` targets whichever sub-pane is active and marks it dirty, so this is
# the keystroke path without the keystrokes. Returns the raw request bytes as text.
private def edit_decoded(view : RepeaterView, &) : String
  view.toggle_req_pane.should eq(:decoded)
  view.replace_edit_buffer(yield view.edit_buffer_text)
  String.new(view.request_bytes) # commits the decoded edit on the way out
end

describe "RepeaterView split-decode (SAML/GraphQL)" do
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
      view = RepeaterView.new
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

  # The shapes that used to open as an ordinary raw tab because nothing could write the pane
  # back. Each has its own inverse now, and each writes a DIFFERENT grammar into the body —
  # so what these pin is that the splice picks the right one and that the untouched request
  # still goes out byte-faithfully.
  describe "GraphQL shapes with their own inverse" do
    it "writes a batch back as the ARRAY it was, with the edit in its own element" do
      body = %([{"query":"query A { a }"},{"query":"query B { b }"}])
      head = "POST /graphql HTTP/1.1\r\nHost: api.test\r\nContent-Type: application/json\r\n" \
             "Content-Length: #{body.bytesize}\r\n\r\n"
      raw = edit_decoded(load_gql(head, body), &.sub("query B { b }", "query B { EDITED }"))
      sent = raw.split("\r\n\r\n", 2)[1]
      arr = JSON.parse(sent).as_a
      arr.size.should eq(2) # NOT collapsed into one object
      arr[0]["query"].as_s.should eq("query A { a }")
      arr[1]["query"].as_s.should eq("query B { EDITED }")
      raw.should contain("Content-Length: #{sent.bytesize}") # resynced
    end

    it "edits a persisted query's hash without inventing a document" do
      body = %({"operationName":"Q","extensions":{"persistedQuery":{"version":1,"sha256Hash":"abc"}}})
      head = "POST /graphql HTTP/1.1\r\nHost: api.test\r\nContent-Type: application/json\r\n" \
             "Content-Length: #{body.bytesize}\r\n\r\n"
      sent = edit_decoded(load_gql(head, body), &.sub("abc", "deadbeef")).split("\r\n\r\n", 2)[1]
      j = JSON.parse(sent)
      j["extensions"]["persistedQuery"]["sha256Hash"].as_s.should eq("deadbeef")
      j.as_h.has_key?("query").should be_false # gori writes no document the client never sent
    end

    it "writes an application/graphql document back as the BODY, not as JSON" do
      body = "query Hero { hero { name } }"
      head = "POST /graphql HTTP/1.1\r\nHost: api.test\r\nContent-Type: application/graphql\r\n" \
             "Content-Length: #{body.bytesize}\r\n\r\n"
      raw = edit_decoded(load_gql(head, body), &.sub("name", "name id"))
      sent = raw.split("\r\n\r\n", 2)[1]
      sent.should eq("query Hero { hero { name id } }") # the pane IS the body
      raw.should contain("Content-Length: #{sent.bytesize}")
    end

    it "sends a multipart upload exactly as captured — the one shape with no inverse" do
      b = "----X"
      body = ["--#{b}", %(Content-Disposition: form-data; name="operations"), "",
              %({"query":"mutation($f: Upload!){ upload(file: $f){ id } }","variables":{"f":null}}),
              "--#{b}--", ""].join("\r\n")
      head = %(POST /graphql HTTP/1.1\r\nHost: api.test\r\nContent-Type: multipart/form-data; boundary="#{b}"\r\nContent-Length: #{body.bytesize}\r\n\r\n)
      view = load_gql(head, body)
      # Even after a decoded-pane edit the envelope is untouched: `location` says :none, so
      # the splice has nothing to write and the captured bytes go out as they came in.
      edit_decoded(view, &.sub("upload", "pwned"))
        .split("\r\n\r\n", 2)[1].should eq(body)
    end
  end

  describe "SAML" do
    xml = %(<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="_x"><saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">https://idp.test/m</saml:Issuer></samlp:Response>)
    saml_body = "SAMLResponse=#{URI.encode_www_form(Base64.strict_encode(xml))}&RelayState=#{URI.encode_www_form("/dash")}"
    saml_head = "POST /acs HTTP/1.1\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: #{saml_body.bytesize}\r\n\r\n"

    it "re-encodes an edited XML into the param, preserving RelayState + resyncing CL" do
      detail = detail_of("/acs", saml_head, saml_body)
      doc = Gori::Saml.from_flow("/acs", saml_head.to_slice, saml_body.to_slice, nil, nil).not_nil!
      view = RepeaterView.new
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
      view = RepeaterView.new
      view.load_graphql(detail, op)

      view.edit_move(999, 0) # to the ENVELOPE's last line (bottom)
      view.req_pane.should eq(:envelope)
      view.edit_move(1, 0) # ↓ off the bottom → DECODED
      view.req_pane.should eq(:decoded)
      view.edit_move(-1, 0) # ↑ off the DECODED top → ENVELOPE
      view.req_pane.should eq(:envelope)
    end

    # The same crossing in READ mode, which is where it did not exist: the step lived inline
    # in `edit_move` (INS only), so `request_read_move` clamped at each sub-pane's edge and
    # `^T` was the only way across. Both modes call `try_cross_req_pane` now.
    it "crosses in READ mode too, and drops the read selection when it does" do
      detail = detail_of("/graphql", gql_head, gql_body)
      op = Gori::Graphql.from_flow("/graphql", gql_head.to_slice, gql_body.to_slice).not_nil!
      view = RepeaterView.new
      view.load_graphql(detail, op)
      view.request_insert?.should be_false # a decode tab opens in READ, like every other tab

      view.pane_select_line
      view.pane_selection?.should be_true

      10.times { view.request_read_move(1, 0) } # past the ENVELOPE's last line
      view.req_pane.should eq(:decoded)
      view.pane_selection?.should be_false # an anchor cannot follow the caret into another buffer

      view.request_read_move(-1, 0)
      view.req_pane.should eq(:envelope)
    end
  end

  # Mouse gestures in the split column, which used to return early on `@decode_kind`: a drag
  # selected nothing and a double-click took no word, in either sub-pane. They go through the
  # same `request_hit` / `request_sub_rect` / `place_request_caret` seam as plain HTTP and WS.
  describe "mouse drag + double-click in the split sub-panes" do
    gql_body = %({"query":"query FindUser { name }"})
    gql_head = "POST /graphql HTTP/1.1\r\nHost: api.test\r\nContent-Type: application/json\r\nContent-Length: #{gql_body.bytesize}\r\n\r\n"

    # The DECODED card's content rect, re-derived as `render` does (target band → left half →
    # `decode_split` with the ACTIVE pane enlarged → the card's 1-cell inset).
    decoded_rect = ->(view : RepeaterView, rect : Rect) {
      target_h = {rect.h, 3}.min
      content = Rect.new(rect.x, rect.y + target_h, rect.w, {rect.h - target_h, 0}.max)
      half = {(content.w - 1) // 2, 1}.max
      col = Rect.new(content.x, content.y, half, content.h)
      inactive = {col.h // 3, 1}.max
      env_h = view.req_pane == :envelope ? {col.h - inactive, 1}.max : inactive
      Rect.new(col.x, col.y + env_h, col.w, {col.h - env_h, 0}.max).inset(1, 1)
    }

    rendered = -> {
      detail = detail_of("/graphql", gql_head, gql_body)
      op = Gori::Graphql.from_flow("/graphql", gql_head.to_slice, gql_body.to_slice).not_nil!
      view = RepeaterView.new
      view.load_graphql(detail, op)
      rect = Rect.new(0, 0, 100, 24)
      b = MemoryBackend.new(100, 24)
      view.render(Screen.new(b), rect) # geometry: @last_cw / last_rows are set here
      {view, b, rect}
    }

    it "adopts the DECODED sub-pane a press landed in and places its caret" do
      view, b, rect = rendered.call
      view.req_pane.should eq(:envelope)
      dec = decoded_rect.call(view, rect)
      x = b.row(dec.y).index("query").not_nil!

      view.request_click_to_cursor(rect, x, dec.y)
      view.req_pane.should eq(:decoded)
      view.pane_copy_text.should contain("FindUser") # the caret line is the GraphQL query
    end

    # ^T into DECODED first, so the card is already at its active (enlarged) size and one
    # render describes the layout both the press and the drag are inverted against.
    it "extends a READ-mode selection inside the DECODED sub-pane" do
      view, _, rect = rendered.call
      view.toggle_req_pane
      view.req_pane.should eq(:decoded)
      b = MemoryBackend.new(100, 24)
      view.render(Screen.new(b), rect)

      dec = decoded_rect.call(view, rect)
      x = b.row(dec.y).index("query").not_nil!
      view.request_click_to_cursor(rect, x, dec.y)
      view.request_drag_to_cursor(rect, x + 5, dec.y)

      view.pane_selection?.should be_true
      view.pane_copy_text.should eq("query")
    end

    it "takes the word under a double-click in the DECODED sub-pane" do
      view, _, rect = rendered.call
      view.toggle_req_pane
      b = MemoryBackend.new(100, 24)
      view.render(Screen.new(b), rect)

      dec = decoded_rect.call(view, rect)
      x = b.row(dec.y).index("FindUser").not_nil! + 2
      view.request_click_to_cursor(rect, x, dec.y)
      view.request_select_word.should be_true
      view.pane_copy_text.should eq("FindUser")
    end
  end
end
