require "../spec_helper"

private alias F = Gori::Fuzz
private alias M = Gori::Miner
private alias RM = Gori::RequestMacro

private class MacroMetadataBackend < F::Backend
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

private class MacroMetadataSource < RM::Source
  def run(budget : RM::Budget?, pacer : Proc(Nil)?, cancelled : Proc(Bool)? = nil) : RM::Outcome
    RM::Outcome.new(true, 0)
  end

  def labels : Array(String)
    [] of String
  end
end

describe M::MacroBackend do
  it "forwards transport and WebSocket notes through the nested hook wrapper" do
    inner = M::HookBackend.new(MacroMetadataBackend.new, ["unused"], 1.second)
    lane = RM::Lane.new(RM::Spec.new(["unused"]), MacroMetadataSource.new, "miner", "request")
    backend = M::MacroBackend.new(inner, lane)

    backend.http2?.should be_true
    backend.ws_notes.should eq(3_i64)
    backend.ws_note_reason.should eq("x")
  end
end
