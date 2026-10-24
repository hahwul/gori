require "./spec_helper"

# "Where does a message head end" has ONE answer: `Env.head_body_separator` (and
# `head_body_boundary` / `split_head_body` over it), which accepts `\r\n\r\n`, `\n\n` and the
# mixed `\n\r\n`, earliest first, in bytes. A private copy of that scan is the shape a
# request-path audit found again and again (#1762, #1763, #1764): a slot overlay that wrote
# its header into a multipart body, an h2 send that put a body into header fields, a Miner
# injection after the body, a curl export that swallowed body bytes into the head — each one a
# copy that knew two of the three spellings, or took the CRLF one wherever it appeared.
#
# So a new scan for a blank line is a failure here unless it is listed below with the reason it
# is not a message-head split, or is one on bytes that cannot hold the other spellings. An
# entry that stops matching fails too, so a fix deletes its own line. Keyed by the stripped
# source line, not a line number, so ordinary edits around it do not churn the list.
private BOUNDARY_SCAN = %r{(?:\.index|\.byte_index|\.split|\.includes\?|\.partition)\(\s*(?:"\\r\\n\\r\\n"|"\\n\\n")|AsciiBytes\.index\([^)]*(?:"\\r\\n\\r\\n"|"\\n\\n")}

private EDITOR = "TUI editor text: the LF projection of the buffer, where a blank line is exactly `\\n\\n`"

private BOUNDARY_ALLOWED = {
  {"src/gori/graphql.cr", %(sep = part.index("\\r\\n\\r\\n") || part.index("\\n\\n") || next)}                         => {1, "a multipart PART's headers inside a captured body, read to find `operations`; not a message head"},
  {"src/gori/export/csrf_poc.cr", %(sep = seg.index("\\r\\n\\r\\n") || seg.index("\\n\\n"))}                           => {1, "a multipart PART's headers inside the body being exported; not a message head"},
  {"src/gori/export/curl.cr", %(elsif AsciiBytes.index(rest, "\\r\\n\\r\\n".to_slice))}                                => {1, "the blank line that ends a chunked body's trailers, after the 0-chunk; not a message head"},
  {"src/gori/repeater/flow_request.cr", %(sep = text.index("\\r\\n\\r\\n"))}                                           => {2, "CRLF-only on purpose: auto Content-Length rewrites or adds only in a head it can parse line by line (see `resync_content_length`)"},
  {"src/gori/probe/active/request_smuggling.cr", %(i = s.index("\\r\\n\\r\\n"))}                                       => {1, "a request the probe itself wrote, always CRLF-framed"},
  {"src/gori/tui/intercept_view.cr", %(synced_head = String.new(synced).split("\\r\\n\\r\\n", limit: 2).first)}        => {1, "reads the Content-Length line back out of `sync_edit` output over CRLF-normalized wire bytes"},
  {"src/gori/tui/repeater_view/reflect.cr", %(synced_head = String.new(synced).split("\\r\\n\\r\\n", limit: 2).first)} => {1, "reads the Content-Length line back out of the synced, CRLF-normalized wire form"},
  {"src/gori/tui/repeater_view/reflect.cr", %(env_sep = @editor.text.index("\\n\\n"))}                                 => {1, EDITOR},
  {"src/gori/tui/repeater_view/send.cr", %(sep = text.index("\\n\\n") || return "no request body")}                    => {1, EDITOR},
  {"src/gori/tui/repeater_view/send.cr", %(sep = env.index("\\n\\n"))}                                                 => {1, EDITOR},
  {"src/gori/tui/repeater_view/decode.cr", %(sep = env.index("\\n\\n"))}                                               => {1, EDITOR},
  {"src/gori/tui/repeater_view/decode.cr", %(sep = env.index("\\n\\n") || return env)}                                 => {3, EDITOR},
  {"src/gori/repeater/minimize.cr", %(if sep = text.index("\\n\\n"))}                                                  => {1, "Minimize works on the LF editor form (`split_text`); `resolve` frames the wire"},
}

describe "the head/body boundary" do
  it "is found by Env.head_body_separator, not by a private scan" do
    root = File.expand_path(File.join(__DIR__, ".."))
    hits = Hash({String, String}, Int32).new(0)
    glob_files(root, "src", "gori", "**", "*.cr").each do |path|
      rel = Path.new(path).relative_to(root).to_posix.to_s
      File.each_line(path) do |line|
        code = line.strip
        next if code.starts_with?('#')
        hits[{rel, code}] += 1 if BOUNDARY_SCAN.matches?(code)
      end
    end
    unexpected = hits.reject { |k, n| BOUNDARY_ALLOWED[k]?.try(&.[0]) == n }
    stale = BOUNDARY_ALLOWED.reject { |k, (n, _)| hits[k]? == n }
    unexpected.keys.map { |(f, c)| "#{f}: #{c}" }.should eq([] of String)
    stale.keys.map { |(f, c)| "#{f}: #{c}" }.should eq([] of String)
  end
end
