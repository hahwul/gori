require "../spec_helper"

include Gori::Tui

# `^E` hands the focused buffer to `$EDITOR` and writes the result back. Both callers used to
# hand it `TextArea#text` — the LF PROJECTION — and write back through `set_text`, so every
# CRLF in the message (head AND body) was destroyed by a single round trip. `ContentLength`
# then resynced DOWN to the shortened body, which is what hid it: nothing hung, nothing
# errored, and a CRLF-framing test (smuggling, CL/TE desync, a binary or multipart body)
# quietly stopped being that test.
#
# `ExternalEditor` itself was hardened for exactly this (byte-exact wire kinds, conditional
# trailing-newline chop); the invariant was defeated one layer up, in its two callers.
private def with_fake_editor(script : String, &)
  posix_only!("a #!/bin/sh stand-in editor")
  dir = File.tempname("gori-ed")
  Dir.mkdir_p(dir)
  path = File.join(dir, "fake-editor.sh")
  File.write(path, script)
  File.chmod(path, 0o755)
  prev = Gori::Settings.editor
  Gori::Settings.editor = path
  begin
    yield
  ensure
    Gori::Settings.editor = prev
    FileUtils.rm_rf(dir)
  end
end

private def ee_interceptor(&)
  path = File.tempname("gori-ee", ".db")
  store = Gori::Store.open(path)
  begin
    ic = Gori::Interceptor.new(Gori::Scope.load(store))
    ic.toggle # enable
    yield ic
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# The Runner's `run_external_editor` minus the terminal handoff (which owns @term and cannot
# run headless): the same `ExternalEditor.edit` call with the same Process::Status contract.
private def external_edit(text : String, kind : Symbol) : Gori::ExternalEditor::Result
  Gori::ExternalEditor.edit(text, kind) do |program, args|
    Process.run(program, args)
  end
end

describe "external editor (^E) wire-form round trip" do
  # A captured request whose BODY carries a deliberate CRLF — the smuggled-request shape the
  # hunter used. 33 body bytes; the head declares them.
  body = "0\r\n\r\nGET /smuggled HTTP/1.1\r\nX: x"
  wire = "POST /smug HTTP/1.1\r\nHost: 127.0.0.1:19501\r\n" \
         "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}"

  it "hands the Repeater's REQUEST buffer to $EDITOR in wire form and takes it back byte-exact" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1:19501", wire, false, false)
    view.focus_pane(:request)

    # What ^E would write to the temp file.
    view.edit_buffer_text.should eq(wire)

    # A real editor round trip that inserts one header line and nothing else.
    with_fake_editor(<<-SH) do
      #!/bin/sh
      python3 - "$1" <<'PY'
      import sys
      p = sys.argv[1]; d = open(p, 'rb').read(); i = d.find(b"\\n")
      open(p, 'wb').write(d[:i+1] + b"X-Ed: 1\\r\\n" + d[i+1:])
      PY
      SH
      result = external_edit(view.edit_buffer_text, :request)
      result.outcome.should eq(Gori::ExternalEditor::Outcome::Changed)
      view.replace_edit_buffer(result.text.not_nil!)
    end

    # Every original terminator survived; only the new header is new.
    view.request_text.should eq(
      "POST /smug HTTP/1.1\r\nX-Ed: 1\r\nHost: 127.0.0.1:19501\r\n" \
      "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end

  it "round-trips the Repeater buffer byte-exactly when the editor changes nothing" do
    view = RepeaterView.new
    view.restore("http://127.0.0.1:19501", wire, false, false)
    view.focus_pane(:request)
    view.replace_edit_buffer(view.edit_buffer_text)
    view.request_text.should eq(wire) # set_text is the exact inverse of wire_text
  end

  it "hands the Intercept editor its held bytes in wire form and takes them back byte-exact" do
    ee_interceptor do |ic|
      spawn do
        ic.hold_request(wire.to_slice, method: "POST", target: "/smug",
          host: "127.0.0.1", port: 19501, scheme: "http")
      end
      Fiber.yield
      view = InterceptView.new
      view.reload(ic)
      view.toggle_edit # open the editor on the held item

      view.editor_text.should eq(wire)
      view.replace_editor(view.editor_text)
      # An unchanged round trip must leave the forwarded bytes identical to the held ones —
      # the head's CRLFs AND the body's, whose bare-LF projection used to come back 4 bytes
      # shorter with Content-Length silently resynced to match.
      String.new(view.pending_edit.not_nil![1]).should eq(wire)
    end
  end
end
