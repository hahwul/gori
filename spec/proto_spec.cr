require "./spec_helper"

describe Gori::Proto do
  describe ".classify" do
    it "classifies a 101 upgrade as WebSocket (status wins over any type)" do
      Gori::Proto.classify(101, nil).should eq(Gori::Proto::Kind::Ws)
      Gori::Proto.classify(101, "application/grpc").should eq(Gori::Proto::Kind::Ws)
    end

    it "classifies gRPC by Content-Type, including +proto and grpc-web variants" do
      Gori::Proto.classify(200, "application/grpc").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto.classify(200, "application/grpc+proto").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto.classify(200, "application/grpc-web+proto").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto.classify(200, "APPLICATION/GRPC").should eq(Gori::Proto::Kind::Grpc)
    end

    it "classifies SSE by Content-Type, tolerating charset params" do
      Gori::Proto.classify(200, "text/event-stream").should eq(Gori::Proto::Kind::Sse)
      Gori::Proto.classify(200, "text/event-stream; charset=utf-8").should eq(Gori::Proto::Kind::Sse)
    end

    it "treats everything else — including a pending/typeless flow — as HTTP" do
      Gori::Proto.classify(200, "text/html").should eq(Gori::Proto::Kind::Http)
      Gori::Proto.classify(nil, nil).should eq(Gori::Proto::Kind::Http)
      Gori::Proto.classify(200, nil).should eq(Gori::Proto::Kind::Http)
    end
  end

  describe Gori::Proto::Kind do
    it "labels WS/GRPC/SSE for the PROTO column" do
      Gori::Proto::Kind::Ws.label.should eq("WS")
      Gori::Proto::Kind::Grpc.label.should eq("GRPC")
      Gori::Proto::Kind::Sse.label.should eq("SSE")
    end

    it "parses QL proto: values (websocket is an alias for ws) and rejects unknowns" do
      Gori::Proto::Kind.parse?("ws").should eq(Gori::Proto::Kind::Ws)
      Gori::Proto::Kind.parse?("websocket").should eq(Gori::Proto::Kind::Ws)
      Gori::Proto::Kind.parse?("GRPC").should eq(Gori::Proto::Kind::Grpc)
      Gori::Proto::Kind.parse?("http").should eq(Gori::Proto::Kind::Http)
      Gori::Proto::Kind.parse?("nope").should be_nil
    end
  end
end
