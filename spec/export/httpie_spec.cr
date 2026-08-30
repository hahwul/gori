require "../spec_helper"

# `Gori::Export::Httpie` — the request→`httpie` command serializer behind the TUI's
# "Copy as → httpie" row and `gori run show <id> --format httpie`. A shell command, so it shares
# `Export::Curl`'s single-quoting and NUL discipline.

private def httpie(wire : String, target : String) : String
  Gori::Export::Httpie.text(wire, target).not_nil!
end

describe Gori::Export::Httpie do
  it "emits method, URL, header items and a --raw body" do
    cmd = httpie("POST /api HTTP/1.1\r\nHost: h.test\r\nContent-Type: application/json\r\n\r\n{\"a\":1}", "https://h.test")
    cmd.should contain("http 'POST' 'https://h.test/api'")
    cmd.should contain("'Content-Type:application/json'")
    cmd.should contain(%(--raw '{"a":1}'))
  end

  it "single-quotes a header value so a shell metacharacter cannot end the command" do
    cmd = httpie("GET / HTTP/1.1\r\nHost: h.test\r\nX-Evil: ;id\r\n\r\n", "https://h.test")
    cmd.should contain("'X-Evil:;id'")
    cmd.lines.each { |l| l.should_not end_with(";id") }
  end

  # httpie's `Name:` is the syntax for UNSETTING a header; `Name;` is the one that sends it with
  # an empty value. Measured against a raw listener on httpie 3.2.4: `'X-Empty:'` put no such
  # field on the wire, `'X-Empty;'` sent `X-Empty:`.
  it "sends an empty-valued header with httpie's `Name;` form instead of unsetting it" do
    cmd = httpie("GET /x HTTP/1.1\r\nHost: h.test\r\nX-Empty:\r\nX-Full: v\r\n\r\n", "https://h.test")
    cmd.should contain("'X-Empty;'")
    cmd.should_not contain("'X-Empty:'")
    cmd.should contain("'X-Full:v'")
  end

  # httpie picks an item's separator by scanning for the first of `;`/`=`/`:`/`@`, so one of them
  # in the NAME — or a `=`/`@` opening the VALUE — changes what the item IS. Measured on httpie
  # 3.2.4: `'X=A:v1'` made the bodyless GET go out as `Content-Type: application/json` with a body
  # of `{"X": "A:v1"}`, and `'X-At:@boom'` made httpie read the local file `boom`.
  it "escapes an item separator in a header name so it cannot become a data field" do
    cmd = httpie("GET /x HTTP/1.1\r\nHost: h.test\r\nX=A: v1\r\nX;B: v2\r\nX@C: v3\r\n\r\n", "https://h.test")
    cmd.should contain(%('X\\=A:v1'))
    cmd.should contain(%('X\\;B:v2'))
    cmd.should contain(%('X\\@C:v3'))
  end

  it "escapes a `=`/`@` opening a header value, and leaves one deeper in alone" do
    cmd = httpie("GET /x HTTP/1.1\r\nHost: h.test\r\nX-At: @boom\r\nX-Eq: =1\r\nX-Ok: k=v@h\r\n\r\n", "https://h.test")
    cmd.should contain(%('X-At:\\@boom'))
    cmd.should contain(%('X-Eq:\\=1'))
    cmd.should contain("'X-Ok:k=v@h'")
  end

  it "drops a header whose backslash httpie's own escape cannot survive, and names it" do
    cmd = httpie("GET /x HTTP/1.1\r\nHost: h.test\r\nX-Back: a\\=b\r\nX-Ok: v\r\n\r\n", "https://h.test")
    cmd.should contain("# header 'X-Back' omitted")
    cmd.should_not contain("X-Back:")
    cmd.should contain("'X-Ok:v'")
    cmd.lines.last.lstrip.should start_with("#")
  end

  it "refuses the whole command when the URL holds a NUL (a shell would fetch a different resource)" do
    io = IO::Memory.new
    io << "GET /pa"
    io.write_byte(0_u8)
    io << "th HTTP/1.1\r\nHost: h.test\r\n\r\n"
    cmd = httpie(String.new(io.to_slice), "https://h.test")
    cmd.should start_with("# no command")
    cmd.should_not contain("http '")
  end

  it "omits the method (httpie infers it) when the captured method holds a NUL" do
    io = IO::Memory.new
    io << "GE"
    io.write_byte(0_u8)
    io << "T /x HTTP/1.1\r\nHost: h.test\r\n\r\nbody"
    cmd = httpie(String.new(io.to_slice), "https://h.test")
    cmd.lines.first.should eq("http 'https://h.test/x' \\")
    cmd.should contain("# method omitted")
    cmd.should contain("infer POST")
  end

  it "refuses a body holding a NUL with a note instead of a truncated argument" do
    io = IO::Memory.new
    io << "POST /u HTTP/1.1\r\nHost: h.test\r\n\r\n"
    io.write(Bytes[0x61_u8, 0x00_u8, 0x62_u8])
    cmd = httpie(String.new(io.to_slice), "https://h.test")
    # No --raw ARGUMENT (the note may mention --raw in prose); what must be absent is a line
    # whose own first token is --raw.
    cmd.lines.any? { |l| l.lstrip.starts_with?("--raw ") }.should be_false
    cmd.should contain("# body omitted")
    # LAST line: the note is a comment, so it swallows the ` \` that would continue the command.
    cmd.lines.last.lstrip.should start_with("#")
  end
end
