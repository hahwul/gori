require "../spec_helper"

private alias F = Gori::Fuzz
private alias M = Gori::Miner

private class HookMetadataBackend < F::Backend
  def origin : F::Origin
    F::Origin.new("http", "example.test", 80)
  end

  def http2? : Bool
    true
  end

  def ws_notes : Int64
    3_i64
  end

  def ws_note_reason : String?
    "x"
  end

  def send(bytes : Bytes) : Gori::Repeater::Result
    raise "unexpected send"
  end
end

describe M::HookBackend do
  it "forwards transport and WebSocket notes from its inner backend" do
    backend = M::HookBackend.new(HookMetadataBackend.new, ["unused"], 1.second)

    backend.http2?.should be_true
    backend.ws_notes.should eq(3_i64)
    backend.ws_note_reason.should eq("x")
  end
end
