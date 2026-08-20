require "../spec_helper"

# The request pane's RECONSTRUCTION has to reproduce every pass that runs between the splice
# and the socket, or it shows bytes no socket carried.
#
# `FuzzerView#result_request` already froze the two that matter most — the Content-Length
# knobs and the query/form percent-encoding — and skipped a third: `Generator#reframe_grpc?`,
# the opt-in recompute of the gRPC 5-byte length prefix (^O config → "gRPC reframe (unary)",
# `gori run fuzz --reframe-grpc`, MCP `reframe_grpc`). With the toggle ON the wire carried a
# prefix recomputed for the substituted message while this pane showed the STALE one — which
# on a gRPC sweep is precisely the byte under test, and the tab's default retention
# (`keep_bodies: :matched`) makes every non-matching row a reconstruction.

private def with_grpc_store(&)
  path = File.tempname("gori-fuzzgrpc", ".db")
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

# A row the run's keep_bodies dropped: no head, no body, no request — the shape every
# non-matching row has under the TUI default, and the only shape that reaches the fallback.
private def dropped_row(payloads : Array(String)) : Gori::Fuzz::Result
  Gori::Fuzz::Result.new(0_i64, payloads, nil, 404, 12_i64, 2, 1, 1000_i64, nil, false, false, nil)
end

# {view, the reconstructed body of its single row} for one run of the same gRPC template.
private def reframe_body(store, reframe : Bool) : Array(UInt8)
  # 5-byte prefix (flag 0, length 3) then "abc" — `abc` is the marked position, and the seed
  # frames CLEANLY, which is what `GrpcVerdict.reframable_template?` requires.
  tmpl = "POST /svc.M/Do HTTP/1.1\r\nHost: h\r\ncontent-type: application/grpc\r\n" \
         "content-length: 8\r\n\r\n\u0000\u0000\u0000\u0000\u0003§abc§"
  view = Gori::Tui::FuzzerView.new
  view.load_request("http://127.0.0.1:1/", tmpl, false, "")
  view.apply_set(nil, Gori::Tui::SetSpec.new(:list, "abcdef"))
  view.config.reframe_grpc = reframe
  engine, err = view.build_engine(false, Gori::Scope.load(store), nil)
  err.should be_nil
  engine.should_not be_nil
  view.begin_run(1_i64)
  view.append_result(dropped_row(["abcdef"]))
  String.new(view.result_request(view.selected_result.not_nil!).bytes).split("\r\n\r\n", 2)[1].bytes
end

describe "FuzzerView#result_request — the gRPC reframe the run applied" do
  it "recomputes the length prefix when the run did" do
    with_grpc_store do |store|
      # 6 bytes of message, so the prefix says 6. Size-preserving, so the Content-Length the
      # sync pass just wrote is untouched by it.
      reframe_body(store, true).should eq([0_u8, 0_u8, 0_u8, 0_u8, 6_u8] + "abcdef".bytes)
    end
  end

  it "leaves it stale when the run did not — the control" do
    with_grpc_store do |store|
      # P7: with the toggle off gori sends the operator's bytes and only NAMES the staleness,
      # so the prefix stays at the template's 3. A pane that always reframed would be wrong in
      # the other direction, which is why this half is asserted too.
      reframe_body(store, false).should eq([0_u8, 0_u8, 0_u8, 0_u8, 3_u8] + "abcdef".bytes)
    end
  end
end
