require "../spec_helper"
require "../support/memory_backend"
require "../support/demo_descriptor"
require "base64"
require "file_utils"

include Gori::Tui

private alias PB = Gori::Protobuf
private alias Schemas = Gori::Protobuf::Schemas

private def grpc_tmp_store(&)
  path = File.tempname("gori-grpcfields", ".db")
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

# `Schemas` is per-PROCESS state and every other example in the suite renders through it.
private def with_demo_schema(&)
  dir = File.tempname("gori-protos-fields")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
  Schemas.apply(dir)
  yield
ensure
  Schemas.clear
  FileUtils.rm_rf(dir) if dir
end

private def framed(payload : Bytes) : Bytes
  Gori::Proxy::H2::Grpc.frame(false, payload)
end

private def grpc_view(store : Gori::Store, payload : Bytes,
                      target = "/demo.Users/GetUser") : RepeaterView
  head = "POST #{target} HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\n\r\n"
  id = store.insert_flow(Gori::Store::CapturedRequest.new(
    created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
    method: "POST", target: target, http_version: "HTTP/2",
    head: head.to_slice, body: framed(payload), source: Gori::FlowSource::Kind::Proxy))
  view = RepeaterView.new
  view.load_grpc(store.get_flow(id).not_nil!)
  view
end

# `demo.GetUserRequest` — the input type `/demo.Users/GetUser` binds to. Field 1 is a string.
private def get_user_request(name : String) : Bytes
  io = IO::Memory.new
  io.write(Bytes[0x0A, name.bytesize.to_u8])
  io.write(name.to_slice)
  io.to_slice
end

# The payload the tab would actually put on the wire, deframed back to the message body.
private def sent_payload(view : RepeaterView) : Bytes
  bytes = view.request_bytes
  sep = "\r\n\r\n".to_slice
  idx = (0..bytes.size - sep.size).find { |i| bytes[i, sep.size] == sep }.not_nil!
  msgs, residual = Gori::Proxy::H2::Grpc.scan(bytes[idx + sep.size..])
  residual.should eq(0)
  msgs.size.should eq(1)
  msgs[0].data
end

describe "RepeaterView gRPC FIELDS editor (#828)" do
  # #823's last acceptance criterion, kept by #828: a gori with no descriptor set loaded
  # behaves in this tab exactly as it did before either issue landed.
  describe "with no descriptor set loaded" do
    it "offers no field editor and leaves the pane on the head" do
      Schemas.clear
      grpc_tmp_store do |store|
        view = grpc_view(store, get_user_request("hahwul"))
        view.grpc_fields_available?.should be_false
        view.grpc_field_binding.should be_nil
        view.toggle_grpc_fields.should be_false
        view.grpc_fields?.should be_false

        backend = MemoryBackend.new(160, 24)
        view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
        backend.contains?("FIELDS").should be_false
        backend.contains?("content-type: application/grpc").should be_true # the head editor
      end
    end

    it "sends the captured body byte for byte" do
      Schemas.clear
      grpc_tmp_store do |store|
        payload = get_user_request("hahwul")
        view = grpc_view(store, payload)
        sent_payload(view).should eq(payload)
      end
    end
  end

  describe "with a descriptor set that declares the rpc" do
    it "binds the request line to the rpc's INPUT message and lists its fields" do
      with_demo_schema do
        grpc_tmp_store do |store|
          view = grpc_view(store, get_user_request("hahwul"))
          b = view.grpc_field_binding.not_nil!
          b.type.full_name.should eq("demo.GetUserRequest")
          b.request.should be_true
          view.grpc_fields_available?.should be_true
          view.toggle_grpc_fields.should be_true

          rows = view.grpc_field_rows
          rows.size.should eq(1)
          rows[0].label.should contain("name")
          rows[0].label.should contain("string")
          rows[0].seed.should eq("hahwul")
          rows[0].editable?.should be_true
        end
      end
    end

    it "draws the named field in the request pane and a ␣E:FIELDS badge" do
      with_demo_schema do
        grpc_tmp_store do |store|
          view = grpc_view(store, get_user_request("hahwul"))
          view.toggle_grpc_fields.should be_true
          backend = MemoryBackend.new(160, 24)
          view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
          backend.contains?("FIELDS").should be_true
          backend.contains?("name").should be_true
          backend.contains?("hahwul").should be_true
        end
      end
    end

    it "edits a field and sends the re-encoded message" do
      with_demo_schema do
        grpc_tmp_store do |store|
          view = grpc_view(store, get_user_request("hahwul"))
          view.toggle_grpc_fields
          view.grpc_field_begin.should be_nil
          view.grpc_fields_editing?.should be_true
          type_into(view, "admin")
          view.grpc_field_apply.should be_nil
          view.grpc_fields_editing?.should be_false
          view.dirty?.should be_true

          sent = sent_payload(view)
          sent.should eq(get_user_request("admin"))
          # …and the frame in front of it is recomputed, so the message the origin reads is
          # well formed rather than five stale length bytes over a shorter payload.
          PB.decode(sent).fields[0].string.should eq("admin")
        end
      end
    end

    it "re-encoding with no edit is byte-identical to the capture" do
      with_demo_schema do
        grpc_tmp_store do |store|
          payload = get_user_request("hahwul")
          view = grpc_view(store, payload)
          view.toggle_grpc_fields
          view.grpc_field_begin.should be_nil # seeded with the captured value
          view.grpc_field_apply.should be_nil # applied unchanged
          sent_payload(view).should eq(payload)
        end
      end
    end

    it "refuses without touching the payload, and keeps the text to be corrected" do
      with_demo_schema do
        grpc_tmp_store do |store|
          view = grpc_view(store, get_user_request("hahwul"))
          view.toggle_grpc_fields
          view.grpc_field_begin.should be_nil
          type_into(view, "admin")
          empty_the_payload_under_the_form(view)
          # The field the value was opened against is no longer in the message. `replace`
          # bound-checks the path rather than splicing at whatever index still exists.
          view.grpc_field_apply.not_nil!.should contain("changed under the editor")
          view.grpc_fields_editing?.should be_true # the typed text is still there
          sent_payload(view).should be_empty       # …and nothing was written
        end
      end
    end

    it "shows a refusal in the pane, and drops it as soon as the value is edited" do
      with_demo_schema do
        grpc_tmp_store do |store|
          view = grpc_view(store, get_user_request("hahwul"))
          view.toggle_grpc_fields
          view.grpc_field_begin
          empty_the_payload_under_the_form(view)
          view.grpc_field_apply.should_not be_nil
          backend = MemoryBackend.new(160, 24)
          view.render(Screen.new(backend), Rect.new(0, 0, 160, 24))
          backend.contains?("changed under the editor").should be_true
          type_into(view, "x")
          backend2 = MemoryBackend.new(160, 24)
          view.render(Screen.new(backend2), Rect.new(0, 0, 160, 24))
          backend2.contains?("changed under the editor").should be_false
        end
      end
    end

    # The value is encoded and spliced against the row it was OPENED on. `grpc_field_rows`
    # rebuilds on any `Schemas.revision` tick and only CLAMPS the selection across a rebuild,
    # so re-resolving it at apply time could land the typed value on a different field.
    it "applies to the field the value was opened against, across a schema reload" do
      dir = File.tempname("gori-protos-reload")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
      Schemas.apply(dir)
      grpc_tmp_store do |store|
        view = grpc_view(store, get_user_request("hahwul"))
        view.toggle_grpc_fields
        view.grpc_field_begin.should be_nil
        type_into(view, "admin")
        Schemas.apply(dir) # a reload: same declarations, new revision, rows rebuilt
        view.grpc_field_apply.should be_nil
        sent_payload(view).should eq(get_user_request("admin"))
      end
    ensure
      Schemas.clear
      FileUtils.rm_rf(dir) if dir
    end

    it "clears the open value field when the form is toggled off under it" do
      with_demo_schema do
        grpc_tmp_store do |store|
          view = grpc_view(store, get_user_request("hahwul"))
          view.toggle_grpc_fields
          view.grpc_field_begin
          view.grpc_fields_editing?.should be_true
          view.toggle_grpc_fields.should be_false # the ␣E:FIELDS badge click
          # A live `grpc_fields_editing?` with the form gone locks the tab against a
          # cross-session reconcile forever and routes IME composition into a dead buffer.
          view.grpc_fields_editing?.should be_false
          view.pane_insert?(:request).should be_false
        end
      end
    end
  end

  describe "P7: the schema is a lens, the bytes stay the truth" do
    it "lists an undeclared field number read-only, with the reason on the row" do
      with_demo_schema do
        grpc_tmp_store do |store|
          io = IO::Memory.new
          io.write(get_user_request("hahwul"))
          io.write(Bytes[0x48, 0x07]) # field 9, varint 7 — demo.GetUserRequest declares no 9
          view = grpc_view(store, io.to_slice)
          view.toggle_grpc_fields
          rows = view.grpc_field_rows
          rows.size.should eq(2)
          rows[1].label.should contain("(undeclared)")
          rows[1].label.should contain("varint")
          rows[1].editable?.should be_false
          rows[1].note.not_nil!.should contain("does not declare field 9")
        end
      end
    end

    it "names a wire/schema disagreement and refuses to retype it" do
      with_demo_schema do
        grpc_tmp_store do |store|
          # field 1 is declared `string`; here it arrives as a varint.
          view = grpc_view(store, Bytes[0x08, 0x2A])
          view.toggle_grpc_fields
          rows = view.grpc_field_rows
          rows.size.should eq(1)
          rows[0].editable?.should be_false
          rows[0].note.not_nil!.should contain("schema declares name as string")
          rows[0].note.not_nil!.should contain("the wire carries a varint")
          rows[0].value.should eq("42") # the wire reading, drawn as the no-schema tree draws it
          view.grpc_field_begin.not_nil!.should contain("schema declares name as string")
        end
      end
    end

    it "carries an undeclared field through an edit to its neighbour, byte for byte" do
      with_demo_schema do
        grpc_tmp_store do |store|
          io = IO::Memory.new
          io.write(get_user_request("hahwul"))
          io.write(Bytes[0x48, 0x07])
          original = io.to_slice
          view = grpc_view(store, original)
          view.toggle_grpc_fields
          view.grpc_field_begin
          type_into(view, "admin")
          view.grpc_field_apply.should be_nil
          sent = sent_payload(view)
          sent[sent.size - 2, 2].should eq(Bytes[0x48, 0x07])
          sent.should eq(get_user_request("admin") + Bytes[0x48, 0x07])
        end
      end
    end

    it "offers no field editor over a COMPRESSED payload" do
      with_demo_schema do
        grpc_tmp_store do |store|
          # The frame's 0x01 flag says the payload is compressed, and compressed bytes are
          # not a protobuf message until something inflates them — which gori does not. The
          # same carve-out `ProtobufTree.decode?` makes for every other gRPC surface.
          head = "POST /demo.Users/GetUser HTTP/2\r\nHost: api.test\r\ncontent-type: application/grpc\r\ngrpc-encoding: gzip\r\n\r\n"
          id = store.insert_flow(Gori::Store::CapturedRequest.new(
            created_at: 1_i64, scheme: "https", host: "api.test", port: 443,
            method: "POST", target: "/demo.Users/GetUser", http_version: "HTTP/2",
            head: head.to_slice,
            body: Gori::Proxy::H2::Grpc.frame(true, Bytes[0x1F, 0x8B, 0x08, 0x00]),
            source: Gori::FlowSource::Kind::Proxy))
          view = RepeaterView.new
          view.load_grpc(store.get_flow(id).not_nil!)
          view.grpc_reframable?.should be_true # ^X still reaches the compressed octets
          view.grpc_field_binding.should_not be_nil
          view.grpc_fields_available?.should be_false
          view.toggle_grpc_fields.should be_false
        end
      end
    end

    it "names every row it does not draw — a cut, and a truncated parse" do
      s = demo_schema
      user = s.message?("demo.User").not_nil!
      # A clean field, then a length prefix claiming more than arrived.
      truncated = Bytes[0x08, 0x2A, 0x12, 0x40, 0x41]
      rows = RepeaterView.grpc_form_rows(truncated, s, user)
      rows.size.should eq(2)
      rows[0].seed.should eq("42")
      rows[1].label.should contain("truncated")
      rows[1].editable?.should be_false
      # …and the octets the decoder could not read survive an edit to the field above them.
      d = user.field?(1_u32).not_nil!
      encoded = Gori::Protobuf::Encoder.encode(s, d, "99", packed: false).as(Bytes)
      Gori::Protobuf::Encoder.replace(truncated, rows[0].path, encoded)
        .as(Bytes)[2..].should eq(truncated[2..])
    end

    it "leaves ^X reachable and drops the form when hex opens" do
      with_demo_schema do
        grpc_tmp_store do |store|
          view = grpc_view(store, get_user_request("hahwul"))
          view.toggle_grpc_fields.should be_true
          view.toggle_request_hex.should be_true # the controller exits the form first, but the
          view.exit_grpc_fields                  # view must survive either order
          view.request_hex?.should be_true
        end
      end
    end
  end

  # The row/path model, exercised against a message with nesting — no rpc in the demo
  # descriptor takes a `demo.User` as its INPUT, and the paths are what the encoder splices by.
  describe ".grpc_form_rows" do
    it "descends into a nested message and gives each row its own path" do
      s = demo_schema
      rows = RepeaterView.grpc_form_rows(Base64.decode(DEMO_USER_B64), s,
        s.message?("demo.User").not_nil!)
      profile = rows.index(&.label.includes?("profile")).not_nil!
      rows[profile].editable?.should be_false
      rows[profile].note.not_nil!.should contain("edit the fields under it")
      rows[profile].path.should eq([3])
      # …and the two fields inside it, indented, with a path that descends.
      rows[profile + 1].label.should contain("age")
      rows[profile + 1].path.should eq([3, 0])
      rows[profile + 1].seed.should eq("30")
      rows[profile + 2].label.should contain("tags")
      rows[profile + 2].path.should eq([3, 1])
    end

    it "seeds every scalar shape the reference message carries" do
      s = demo_schema
      rows = RepeaterView.grpc_form_rows(Base64.decode(DEMO_USER_B64), s,
        s.message?("demo.User").not_nil!)
      by_name = {} of String => RepeaterView::GrpcFieldRow
      rows.each { |r| by_name[r.label.split(/\s+/).reject(&.empty?)[1]] = r }
      by_name["id"].seed.should eq("-7")
      by_name["role"].seed.should eq("ROLE_ADMIN")   # the NAME, which `encode` takes back
      by_name["token"].seed.should eq("de ad be ef") # bytes as hex
      by_name["scores"].seed.should eq("1, 2, 300")  # a packed run
      by_name["scores"].packed.should be_true
      by_name["active"].seed.should eq("true")
      by_name["ratio"].seed.should eq("0.5")
      by_name["small"].seed.should eq("1.5")
      by_name["delta"].seed.should eq("-3")
      by_name["serial"].seed.should eq("244837814094590")
    end
  end
end

# Shrink the payload out from under an open value field, the way a `^X` hex edit does —
# the one route by which the row a value was opened on can stop existing.
private def empty_the_payload_under_the_form(view : RepeaterView) : Nil
  view.toggle_request_hex
  32.times { view.hex_delete } # forward-delete: the cursor enters at byte 0
  view.toggle_request_hex
end

# Type `text` into the open value field, replacing whatever it was seeded with.
private def type_into(view : RepeaterView, text : String) : Nil
  20.times { view.grpc_field_input_key(key_ev(Termisu::Input::Key::Backspace)) }
  text.each_char { |c| view.grpc_field_input_key(key_ev(Termisu::Input::Key::Unknown, c)) }
end

private def key_ev(key : Termisu::Input::Key, char : Char? = nil) : Termisu::Event::Key
  Termisu::Event::Key.new(key, Termisu::Input::Modifier::None, char)
end
