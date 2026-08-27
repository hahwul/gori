require "./spec_helper"
require "compress/gzip"

# User-defined History columns (#819) — the model, the store's ordered list, and the spec
# grammar `--column` / MCP `columns` share.
#
# What is pinned here is the part of the feature that has no visible symptom until the column
# has already shown the operator a value from the wrong message.

private def tmp_store(&)
  path = File.tempname("gori-dc", ".db")
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

private def detail(request_head : String, response_head : String,
                   request_body : String? = nil, response_body : String? = nil) : Gori::Store::FlowDetail
  row = Gori::Store::FlowRow.new(
    id: 1_i64, created_at: 0_i64, scheme: "https", method: "GET", host: "h.test", port: 443,
    target: "/", status: 200, size: 0_i64, state: Gori::Store::FlowState::Complete)
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", request_head.to_slice, request_body.try(&.to_slice),
    response_head.to_slice, response_body.try(&.to_slice))
end

private def column(kind : Gori::ExtractKind, selector : String = "",
                   side : Gori::MessageSide = Gori::MessageSide::Response,
                   pos_start = 0, pos_end = 0, label = "c") : Gori::Store::DisplayColumn
  Gori::Store::DisplayColumn.new(0_i64, 0, label, side, kind, selector, pos_start, pos_end, 0)
end

private def value_of(col : Gori::Store::DisplayColumn, d : Gori::Store::FlowDetail) : String
  Gori::DisplayColumns.prepare([col]).values(d).first
end

describe Gori::DisplayColumns do
  describe "extraction" do
    # The whole point of the `side` axis. Every consumer extraction had before this observed
    # RESPONSES, so "the response" was implied by the descriptor and never written down — and
    # an operator wants an `X-Request-Id` column as often for the request their client sent.
    it "reads a header off whichever half the descriptor names" do
      d = detail("GET / HTTP/1.1\r\nHost: h.test\r\nX-Request-Id: from-client\r\n\r\n",
        "HTTP/1.1 200 OK\r\nX-Request-Id: from-origin\r\n\r\n")

      value_of(column(Gori::ExtractKind::Header, "x-request-id"), d).should eq("from-origin")
      value_of(column(Gori::ExtractKind::Header, "x-request-id",
        side: Gori::MessageSide::Request), d).should eq("from-client")
    end

    # A request has no `Set-Cookie`; its jar is the `Cookie` header's `; `-separated pairs
    # (RFC 6265 §5.4). Reading a request for `Set-Cookie` would answer nothing for every flow a
    # browser has ever sent, which is a column that is silently always blank.
    it "reads a request cookie out of the Cookie header, not Set-Cookie" do
      d = detail("GET / HTTP/1.1\r\nCookie: a=1; sid=abc123; b=2\r\n\r\n",
        "HTTP/1.1 200 OK\r\nSet-Cookie: sid=zzz; Path=/\r\n\r\n")

      value_of(column(Gori::ExtractKind::Cookie, "sid",
        side: Gori::MessageSide::Request), d).should eq("abc123")
      value_of(column(Gori::ExtractKind::Cookie, "sid"), d).should eq("zzz")
    end

    it "pulls a jsonpath and a regex capture out of the body" do
      d = detail("POST /x HTTP/1.1\r\n\r\n", "HTTP/1.1 200 OK\r\n\r\n",
        response_body: %({"data":{"id":"J-9"},"token":"tok=SECRET7"}))

      value_of(column(Gori::ExtractKind::JsonPath, "data.id"), d).should eq("J-9")
      value_of(column(Gori::ExtractKind::Regex, "tok=(\\w+)"), d).should eq("SECRET7")
      value_of(column(Gori::ExtractKind::Position, pos_start: 0, pos_end: 6), d).should eq(%({"data))
    end

    # BLANK, never the selector: a cell that echoed its own descriptor would read as a value the
    # message carried.
    it "yields an empty cell — not the selector — for a descriptor that matches nothing" do
      d = detail("GET / HTTP/1.1\r\n\r\n", "HTTP/1.1 200 OK\r\n\r\n", response_body: "not json")

      value_of(column(Gori::ExtractKind::Header, "x-nope"), d).should eq("")
      value_of(column(Gori::ExtractKind::JsonPath, "data.id"), d).should eq("")
      value_of(column(Gori::ExtractKind::Regex, "tok=(\\w+)"), d).should eq("")
    end

    # A pattern that will not compile must cost its own column and nothing else — the row loop
    # runs on the render fiber, where a raise is the whole tab.
    it "survives a regex that does not compile, and keeps the other columns" do
      d = detail("GET / HTTP/1.1\r\nX-Ok: yes\r\n\r\n", "HTTP/1.1 200 OK\r\nX-Ok: yes\r\n\r\n")
      prepared = Gori::DisplayColumns.prepare([
        column(Gori::ExtractKind::Regex, "([unclosed", label: "bad"),
        column(Gori::ExtractKind::Header, "x-ok", label: "ok"),
      ])

      prepared.values(d).should eq(["", "yes"])
    end

    # A header value carries whatever the peer put on the wire. A CR reaching a terminal row
    # rewrites it; a LF splits it. The exact bytes stay one `↵` away in the detail pane.
    it "draws control characters rather than letting them reach the row" do
      Gori::DisplayColumns.display_safe("a\r\nb").should eq("a··b")
      Gori::DisplayColumns.display_safe(nil).should eq("")
      Gori::DisplayColumns.display_safe(String.new(Bytes[0x41, 0xff, 0x42])).should eq("A\u{FFFD}B")
    end

    # A cell, not a document: `position:0:500000` is a legal descriptor, and without a bound the
    # row loop would build that String per row per frame and a text listing would print it.
    it "cuts an oversized value with an ellipsis rather than silently" do
      long = "x" * (Gori::DisplayColumns::CELL_MAX + 50)
      out = Gori::DisplayColumns.display_safe(long)
      out.size.should eq(Gori::DisplayColumns::CELL_MAX + 1)
      out.should end_with("…")
      Gori::DisplayColumns.display_safe("x" * Gori::DisplayColumns::CELL_MAX)
        .should_not end_with("…")
    end

    # `body_scoped?` is what decides whether a caller pays for the BLOBs at all — and it is asked
    # PER PREFIX, because a narrow pane draws only the columns that fit and must not pay a
    # 512 KiB read plus a content-decode per row for a dropped one.
    it "reports whether a given prefix of the set needs the body" do
      Gori::DisplayColumns.prepare([column(Gori::ExtractKind::Header, "x")]).body_scoped?.should be_false
      Gori::DisplayColumns.prepare([column(Gori::ExtractKind::Cookie, "x")]).body_scoped?.should be_false
      Gori::DisplayColumns.prepare([column(Gori::ExtractKind::JsonPath, "a")]).body_scoped?.should be_true

      mixed = Gori::DisplayColumns.prepare([
        column(Gori::ExtractKind::Header, "x"),
        column(Gori::ExtractKind::JsonPath, "a"),
      ])
      mixed.body_scoped?(0).should be_false
      mixed.body_scoped?(1).should be_false # the jsonpath column is the one that gets dropped
      mixed.body_scoped?(2).should be_true
    end

    it "evaluates only the requested prefix" do
      d = detail("GET / HTTP/1.1\r\n\r\n", "HTTP/1.1 200 OK\r\nX-A: one\r\nX-B: two\r\n\r\n")
      prepared = Gori::DisplayColumns.prepare([
        column(Gori::ExtractKind::Header, "x-a"),
        column(Gori::ExtractKind::Header, "x-b"),
      ])
      prepared.values(d).should eq(["one", "two"])
      prepared.values(d, 1).should eq(["one"])
      prepared.values(d, 0).should eq([] of String)
    end

    # Capping the bytes read out of SQLite caps nothing on a COMPRESSED body: a modest gzip
    # prefix inflates to whatever the ratio gives, and `ContentDecode`'s default ceiling is the
    # 32 MiB decompression-bomb guard, not a working budget — paid once per visible row.
    it "caps the inflate, not just the stored bytes it read" do
      buf = IO::Memory.new
      Compress::Gzip::Writer.open(buf) { |w| w.print("Z" * (Gori::DisplayColumns::BODY_CAP * 4)) }
      d = detail("GET / HTTP/1.1\r\n\r\n",
        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\n",
        response_body: String.new(buf.to_slice))

      # `position` reads the decoded entity directly and clamps to its bounds, so it reports how
      # far the inflate actually got: BODY_CAP, not the 2 MiB the body expands to.
      value_of(column(Gori::ExtractKind::Position,
        pos_start: Gori::DisplayColumns::BODY_CAP - 10,
        pos_end: Gori::DisplayColumns::BODY_CAP), d).size.should eq(10)

      value_of(column(Gori::ExtractKind::Position,
        pos_start: Gori::DisplayColumns::BODY_CAP + 100,
        pos_end: Gori::DisplayColumns::BODY_CAP + 200), d).should eq("")
    end
  end

  describe "spec grammar" do
    it "parses kind:selector, defaulting the side to the response and the label to the selector" do
      sp = Gori::DisplayColumns.parse_spec("header:x-request-id").as(Gori::DisplayColumns::Spec)
      sp.kind.header?.should be_true
      sp.selector.should eq("x-request-id")
      sp.side.response?.should be_true
      sp.label.should eq("x-request-id")
    end

    it "takes a side prefix and an explicit label" do
      sp = Gori::DisplayColumns.parse_spec("RID=req:header:authorization").as(Gori::DisplayColumns::Spec)
      sp.label.should eq("RID")
      sp.side.request?.should be_true
      sp.kind.header?.should be_true
      sp.selector.should eq("authorization")
    end

    # THE separator rule. A `=` counts as the label separator only when it comes BEFORE the
    # first `:` — without that, this perfectly ordinary pattern reads as a column labelled
    # `regex:token` extracting `(\w+)` by a kind that does not exist.
    it "does not mistake a `=` inside a regex for the label separator" do
      sp = Gori::DisplayColumns.parse_spec("regex:token=(\\w+)").as(Gori::DisplayColumns::Spec)
      sp.kind.regex?.should be_true
      sp.selector.should eq("token=(\\w+)")
      sp.label.should eq("token=(\\w+)")
    end

    it "parses a position range" do
      sp = Gori::DisplayColumns.parse_spec("position:0:32").as(Gori::DisplayColumns::Spec)
      sp.kind.position?.should be_true
      sp.pos_start.should eq(0)
      sp.pos_end.should eq(32)
      sp.label.should eq("0:32")
    end

    it "refuses with a sentence rather than raising" do
      Gori::DisplayColumns.parse_spec("nosuch:x").as(String).should contain("unknown kind")
      Gori::DisplayColumns.parse_spec("header:").as(String).should contain("selector")
      Gori::DisplayColumns.parse_spec("position:5").as(String).should contain("byte range")
      Gori::DisplayColumns.parse_spec("regex:([unclosed").as(String).should contain("does not compile")
      Gori::DisplayColumns.parse_spec("=header:x").as(String).should contain("label")
    end

    it "returns the FIRST refusal from a batch" do
      out = Gori::DisplayColumns.parse_specs(["header:ok", "nosuch:x", "header:also-bad-later"])
      out.as(String).should contain("unknown kind")
    end

    # ONE ceiling, shared. The editor refused a ninth column while `--column`x200 and an MCP
    # `list_history{limit: 500, columns: [200 ...]}` compiled two hundred regexes and fanned out
    # a hundred thousand extractions — on the surface whose own schema text asks the caller to
    # request only what they will read.
    it "refuses more specs than a project may define" do
      ok = Array.new(Gori::DisplayColumns::MAX_COLUMNS) { |i| "header:x-#{i}" }
      Gori::DisplayColumns.parse_specs(ok).as(Array(Gori::DisplayColumns::Spec)).size
        .should eq(Gori::DisplayColumns::MAX_COLUMNS)
      Gori::DisplayColumns.parse_specs(ok + ["header:one-too-many"])
        .as(String).should contain("is the limit")
    end

    # A `--column` label comes off ARGV, which on Unix is bytes — and this label becomes a JSON
    # object KEY on two feeds, where raw bytes produce a document no parser accepts, poisoning
    # every row rather than its own cell.
    it "scrubs a label that is not valid UTF-8" do
      raw = String.new(Bytes[0x52, 0xff, 0x44]) # "R\xffD"
      sp = Gori::DisplayColumns.parse_spec("#{raw}=header:x").as(Gori::DisplayColumns::Spec)
      sp.label.should eq("R\u{FFFD}D")
      sp.label.valid_encoding?.should be_true
    end

    # A spec's `to_column` and a stored row have to spell the same descriptor, or what the
    # editor card shows is not what `--column` would take back. The card renders `#spec` under a
    # promise that it is typeable into the CLI, so a custom LABEL has to survive the round trip —
    # without the prefix a column the operator named `RID` came back named `x-request-id`.
    it "round-trips through the store row's own `spec` spelling, label included" do
      sp = Gori::DisplayColumns.parse_spec("req:jsonpath:data.id").as(Gori::DisplayColumns::Spec)
      sp.to_column(0).spec.should eq("request:jsonpath:data.id") # label == derived: no prefix
      Gori::DisplayColumns.parse_spec("position:2:9").as(Gori::DisplayColumns::Spec)
        .to_column(0).spec.should eq("response:position:2:9")

      named = Gori::DisplayColumns.parse_spec("RID=header:x-request-id").as(Gori::DisplayColumns::Spec)
      named.to_column(0).spec.should eq("RID=response:header:x-request-id")
      back = Gori::DisplayColumns.parse_spec(named.to_column(0).spec).as(Gori::DisplayColumns::Spec)
      back.label.should eq("RID")
      back.selector.should eq("x-request-id")
    end
  end

  describe "fold_by_label" do
    # Two columns MAY share a label — the same header off the request and off the response is a
    # comparison, not a mistake — and a plain last-wins object would drop the half the operator
    # defined first. One fold, so `CLI::Output` and `MCP::Serialize` cannot drift.
    it "keeps first-seen order and groups repeats" do
      out = Gori::DisplayColumns.fold_by_label([{"A", "1"}, {"B", "2"}, {"A", "3"}])
      out.map(&.[0]).should eq(["A", "B"])
      out.map(&.[1]).should eq([["1", "3"], ["2"]])
    end
  end

  describe "width" do
    it "clamps an explicit width and falls back to the default for 0" do
      Gori::DisplayColumns.width_of(column(Gori::ExtractKind::Header, "x"))
        .should eq(Gori::DisplayColumns::DEFAULT_WIDTH)
      wide = Gori::Store::DisplayColumn.new(0_i64, 0, "c", Gori::MessageSide::Response,
        Gori::ExtractKind::Header, "x", 0, 0, 999)
      Gori::DisplayColumns.width_of(wide).should eq(Gori::DisplayColumns::MAX_WIDTH)
    end
  end

  describe "the project's ordered list" do
    it "keeps insertion order, moves a column, and persists both" do
      tmp_store do |store|
        a = store.insert_display_column("A", Gori::ExtractKind::Header, "x-a")
        b = store.insert_display_column("B", Gori::ExtractKind::Header, "x-b")
        c = store.insert_display_column("C", Gori::ExtractKind::Header, "x-c")
        a.should_not eq(0)

        store.display_columns.map(&.label).should eq(%w[A B C])

        store.move_display_column(c, -1).should be_true
        store.display_columns.map(&.label).should eq(%w[A C B])
        # An edge is "nothing moved", not an error the caller reports as a reorder.
        store.move_display_column(a, -1).should be_false
        store.move_display_column(b, 1).should be_false
        store.move_display_column(999_i64, 1).should be_false

        store.update_display_column(a, "AA", Gori::ExtractKind::JsonPath, "data.id",
          side: Gori::MessageSide::Request, width: 20).should be_true
        first = store.display_columns.first
        first.label.should eq("AA")
        first.kind.json_path?.should be_true
        first.side.request?.should be_true
        first.width.should eq(20)

        store.delete_display_column(b).should be_true
        store.display_columns.map(&.label).should eq(%w[AA C])
      end
    end

    # Unlike `extract_rules`, two columns MAY share a label: the same header off the request and
    # off the response is a comparison, not a mistake, and nothing keys a column by name.
    it "allows two columns under one label" do
      tmp_store do |store|
        store.insert_display_column("ID", Gori::ExtractKind::Header, "x-id")
        store.insert_display_column("ID", Gori::ExtractKind::Header, "x-id",
          side: Gori::MessageSide::Request).should_not eq(0)
        store.display_columns.size.should eq(2)
      end
    end

    # A hand-edited or peer-written row must cost that column its meaning, never the History
    # render path that reads this list every frame.
    it "degrades an unreadable kind/side to a default instead of raising" do
      tmp_store do |store|
        store.insert_display_column("X", Gori::ExtractKind::Header, "x-a")
        store.flush
        store.@db.exec("UPDATE display_columns SET kind = 'nonsense', side = 'sideways'")
        col = store.display_columns.first
        col.kind.header?.should be_true
        col.side.response?.should be_true
      end
    end
  end
end
