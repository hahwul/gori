require "../spec_helper"

# The `String` scan `Store.head_markers` was, frozen as the oracle for its byte-scan fast path
# (and still the path a head with any byte >= 0x80 takes). The FTS indexer decides from this
# pair whether a body is indexed at all, so the fast path must answer EXACTLY this — the
# chomp, the blank-line stop, the first colon, `strip`'s whitespace set and last-one-wins.
private def legacy_markers(head : Bytes) : {String?, String?}
  ct = nil.as(String?)
  ce = nil.as(String?)
  String.new(head).each_line do |raw|
    line = raw.chomp
    break if line.empty?
    idx = line.index(':')
    next unless idx
    case line[0...idx].strip.downcase
    when "content-type"     then ct = line[(idx + 1)..].strip
    when "content-encoding" then ce = line[(idx + 1)..].strip
    end
  end
  {ct, ce}
end

private HEADS = [
  "",
  "\r\n",
  "\r\r\n",
  "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Encoding: gzip\r\n\r\n",
  "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\nContent-Encoding: identity\r\n\r\n",
  "HTTP/1.1 200 OK\r\nContent-Type: first\r\nContent-Type: last\r\n\r\n",
  "HTTP/1.1 200 OK\r\ncontent-encoding:br\r\nCONTENT-TYPE:  IMAGE/PNG \r\n\r\n",
  "HTTP/1.1 200 OK\r\n\tContent-Encoding\v:\fgzip\t\r\n\r\n",
  "HTTP/1.1 200 OK\r\n\x1cContent-Encoding: not-strip-ws\r\n\r\n",
  "HTTP/1.1 200 OK\r\nContent-Encoding:\r\nContent-Type:   \r\n\r\n",
  "HTTP/1.1 200 OK\r\nContent-Encoding\r\nContent-Type\r\n\r\n",
  "HTTP/1.1 200 OK\r\nContent-Encoding: a:b\r\n\r\n",
  "HTTP/1.1 200 OK\r\nContent-Encodin: short\r\nContent-Encodings: long\r\n\r\n",
  "HTTP/1.1 200 OK\r\nX: y\r\n gzip-folded\r\n Content-Encoding: indented\r\n\r\n",
  "HTTP/1.1 200 OK\r\nX: y\rContent-Encoding: after-bare-cr\r\n\r\n",
  "HTTP/1.1 200 OK\r\nContent-Encoding: nul\0in\r\n\r\n",
  "HTTP/1.1 200 OK\r\n\r\nContent-Encoding: after-blank\r\n",
  "HTTP/1.1 200 OK\r\n\r\r\nContent-Encoding: after-cr-blank\r\n",
  "HTTP/1.1 200 OK\r\n\r\r\r\nContent-Encoding: not-blank-3cr\r\n",
  "HTTP/1.1 200 OK\r\nContent-Encoding: no-blank-line",
  "HTTP/1.1 200 OK\r\nContent-Encoding: no-blank-line\r",
  "Content-Type: status-line-slot\n\n",
  "\nContent-Encoding: after-leading-lf\n",
]

describe "Gori::Store.head_markers against the String scan it replaced (differential)" do
  it "answers what the String scan answers on every hostile ASCII head, form and prefix" do
    HEADS.each do |s|
      [s, s.gsub("\r\n", "\n"), s.gsub("\r\n", "\r\r\n")].uniq!.each do |form|
        b = form.to_slice
        (0..b.size).each do |n|
          h = b[0, n]
          Gori::Store.head_markers(h).should eq(legacy_markers(h)), "diverged on #{String.new(h).inspect}"
        end
      end
    end
  end

  it "answers what the String scan answers on random heads over the scan's own alphabet" do
    alphabet = ["\r", "\n", "\r\n", ":", " ", "\t", "\v", "\0", "a", "Z", "e",
                "Content-Type", "CONTENT-type", "Content-Encoding", "content-ENCODING", "Content-"]
    rng = Random.new(1983)
    5000.times do
      s = String.build { |io| rng.rand(1..24).times { io << alphabet.sample(rng) } }
      h = s.to_slice
      Gori::Store.head_markers(h).should eq(legacy_markers(h)), "diverged on #{s.inspect}"
    end
  end

  it "takes the String scan for a head with any byte >= 0x80, and still agrees" do
    [
      "HTTP/1.1 200 OK\r\nX: d\u00e4rk\r\nContent-Encoding: gzip\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-Encoding:\u00a0gzip\u00a0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nContent-\u212Aype: kelvin\r\n\r\n",
    ].each do |s|
      h = s.to_slice
      Gori::Store.head_markers(h).should eq(legacy_markers(h))
    end
    invalid = Bytes[0x58, 0xff, 0x0d, 0x0a] + "Content-Encoding: br\r\n\r\n".to_slice
    Gori::Store.head_markers(invalid).should eq(legacy_markers(invalid))
    Gori::Store.head_markers(invalid).should eq({nil, "br"})
  end
end
