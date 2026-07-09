require "../spec_helper"
require "../../src/gori/tui/comparer_view"

include Gori::Tui

private def flow(method, target, host = "h.test")
  row = Gori::Store::FlowRow.new(
    1_i64, 1_i64, "https", method, host, 443, target,
    200, 100_i64, Gori::Store::FlowState::Complete, 50_i64, 1_i64, "text/plain")
  head = "#{method} #{target} HTTP/1.1\r\nHost: #{host}\r\n\r\n".to_slice
  resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nbody".to_slice
  Gori::Store::FlowDetail.new(row, "HTTP/1.1", head, nil, resp, "body".to_slice)
end

describe ComparerView do
  it "builds auto labels from slots and prefers a custom name" do
    v = ComparerView.new
    v.label.should eq("empty")
    v.add_flow(flow("GET", "/a"))
    v.label.should contain("GET")
    v.add_flow(flow("POST", "/b"))
    v.label.should contain("⇄")
    v.name = "login vs register"
    v.label.should eq("login vs register")
  end

  it "duplicates slots and appends copy to a custom name" do
    v = ComparerView.new
    v.name = "pair"
    a = flow("GET", "/a")
    b = flow("POST", "/b")
    v.set_slot(:a, a)
    v.set_slot(:b, b)
    v.toggle_pane # request mode
    d = v.duplicate
    d.name.should eq("pair copy")
    d.both_set?.should be_true
    d.pane.should eq(:request)
    d.same?(v).should be_false
  end

  it "reset! clears slots and name" do
    v = ComparerView.new
    v.name = "x"
    v.add_flow(flow("GET", "/z"))
    v.reset!
    v.name.should be_nil
    v.both_set?.should be_false
    v.label.should eq("empty")
  end
end
