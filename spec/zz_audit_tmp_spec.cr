require "./spec_helper"

include Gori::Tui

describe "AUDIT: TextArea find&replace over a buffer holding raw captured bytes" do
  it "raises ArgumentError on match_count / replace_matches when the buffer is not valid UTF-8" do
    # exactly what InterceptView#toggle_edit does: String.new(it.raw), unscrubbed
    raw = "POST /upload HTTP/1.1\r\nHost: acme.test\r\nContent-Type: image/jpeg\r\n\r\n".to_slice +
          Bytes[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]
    buf = String.new(raw)
    buf.valid_encoding?.should be_false

    ta = TextArea.new(buf)
    ta.text.valid_encoding?.should be_false

    # search_lines (the incremental ^F highlight) is fine — it is a downcase+includes? scan
    ta.search_lines("host").should_not be_empty

    # match_count is what Runner#request_replace_confirm calls on ↵ in replace mode
    expect_raises(ArgumentError, /UTF-8/) { ta.match_count("Host") }
    expect_raises(ArgumentError, /UTF-8/) { ta.replace_matches("Host", "X-Host") }
  end

  it "a scrubbed buffer is fine — so the defect is the missing scrub at load, not the search" do
    raw = "POST /u HTTP/1.1\r\nHost: acme.test\r\n\r\n".to_slice + Bytes[0xFF, 0xD8]
    ta = TextArea.new(String.new(raw).scrub)
    ta.match_count("Host").should eq(1)
    ta.replace_matches("Host", "X-Host").should eq(1)
  end
end
