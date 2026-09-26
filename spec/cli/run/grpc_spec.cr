require "../../spec_helper"

describe "gori run grpc reflect --timeout" do
  it "accepts a positive fractional timeout" do
    Gori::CLI::Run.grpc_timeout("1.5").not_nil!.total_seconds.should eq(1.5)
  end

  it "refuses non-finite, overflowing, and sub-resolution values without raising" do
    %w[NaN Infinity -Infinity 1e300 1e-320].each do |value|
      Gori::CLI::Run.grpc_timeout(value).should be_nil
    end
  end

  it "refuses zero and negative values" do
    Gori::CLI::Run.grpc_timeout("0").should be_nil
    Gori::CLI::Run.grpc_timeout("-1").should be_nil
  end
end

describe "gori run grpc schema / forget reflections source parity" do
  it "reads reflections from Gori::Protobuf::Schemas.reflections(store) rather than store.grpc_reflections" do
    src = File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "grpc.cr"))
    schema_body = src[/def self\.cmd_grpc_schema\(.*?\n      end/m].not_nil!
    schema_body.should contain("reflections = Gori::Protobuf::Schemas.reflections(store)")
    schema_body.should_not contain("reflections = store.grpc_reflections")

    forget_body = src[/def self\.cmd_grpc_forget\(.*?\n      end/m].not_nil!
    forget_body.should contain("known = Gori::Protobuf::Schemas.reflections(store).map(&.target)")
    forget_body.should_not contain("known = store.grpc_reflections.map(&.target)")
  end
end
