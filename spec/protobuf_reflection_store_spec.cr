require "./spec_helper"
require "./support/demo_descriptor"
require "base64"

private alias Schemas = Gori::Protobuf::Schemas
private alias Reflection = Gori::Protobuf::Reflection

private def demo_file_descriptor : Bytes
  set = Gori::Protobuf.decode(Base64.decode(DEMO_DESC_B64))
  set.fields.find { |f| f.number == 1 }.not_nil!.bytes.not_nil!
end

private def with_store(&)
  path = File.tempname("gori-reflect-store", ".db")
  store = Gori::Store.open(path)
  begin
    yield store
  ensure
    Schemas.clear
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

# A descriptor set that redefines `demo.User` with ONE field, so a merge conflict is
# observable rather than assumed.
private def rival_set : Bytes
  fd = IO::Memory.new
  fd.write(Gori::Protobuf::Encoder.length_delimited(1_u32, "rival.proto".to_slice))
  fd.write(Gori::Protobuf::Encoder.length_delimited(2_u32, "demo".to_slice))
  field = IO::Memory.new
  field.write(Gori::Protobuf::Encoder.length_delimited(1_u32, "only".to_slice))
  field.write(Bytes[0x18, 0x01]) # number = 1
  field.write(Bytes[0x20, 0x01]) # label = optional
  field.write(Bytes[0x28, 0x09]) # type = string
  msg = IO::Memory.new
  msg.write(Gori::Protobuf::Encoder.length_delimited(1_u32, "User".to_slice))
  msg.write(Gori::Protobuf::Encoder.length_delimited(2_u32, field.to_slice))
  fd.write(Gori::Protobuf::Encoder.length_delimited(4_u32, msg.to_slice))
  Reflection.descriptor_set([fd.to_slice])
end

describe "gRPC reflection cache" do
  describe Gori::Store do
    it "round-trips a descriptor set byte-exactly" do
      with_store do |store|
        set = Reflection.descriptor_set([demo_file_descriptor])
        store.put_grpc_reflection("https://api.test:443", Reflection::SERVICE_V1, 1, 1, set).should be_true
        rows = store.grpc_reflections
        rows.size.should eq(1)
        rows[0].target.should eq("https://api.test:443")
        rows[0].service.should eq(Reflection::SERVICE_V1)
        rows[0].files.should eq(1)
        rows[0].descriptor.should eq(set)
      end
    end

    it "REPLACES a target rather than accumulating rows" do
      with_store do |store|
        set = Reflection.descriptor_set([demo_file_descriptor])
        store.put_grpc_reflection("https://api.test:443", Reflection::SERVICE_V1, 1, 1, set)
        store.put_grpc_reflection("https://api.test:443", Reflection::SERVICE_V1ALPHA, 2, 2, rival_set)
        rows = store.grpc_reflections
        rows.size.should eq(1)
        rows[0].service.should eq(Reflection::SERVICE_V1ALPHA)
        rows[0].descriptor.should eq(rival_set)
      end
    end

    it "deletes one target and clears them all" do
      with_store do |store|
        set = Reflection.descriptor_set([demo_file_descriptor])
        store.put_grpc_reflection("https://a.test:443", "s", 1, 1, set)
        store.put_grpc_reflection("https://b.test:443", "s", 1, 1, set)
        store.delete_grpc_reflection("https://a.test:443")
        store.grpc_reflections.map(&.target).should eq(["https://b.test:443"])
        store.clear_grpc_reflections
        store.grpc_reflections.should be_empty
      end
    end
  end

  describe Gori::Protobuf::Schemas do
    it "adopts a fetch, resolves through it, and survives a reload" do
      with_store do |store|
        Schemas.load_project(store)
        Schemas.resolve("/demo.Users/GetUser", request: true).should be_nil

        set = Reflection.descriptor_set([demo_file_descriptor])
        Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, set).should be_true

        binding = Schemas.resolve("/demo.Users/GetUser", request: true).not_nil!
        binding.type.full_name.should eq("demo.GetUserRequest")

        # …and the same answer a FILE-loaded set gives, which is the whole acceptance
        # criterion: one parser, one binding, one set of renderers.
        binding.type.fields.should eq(demo_schema.message?("demo.GetUserRequest").not_nil!.fields)

        # A fresh project open (a restart) replays the cache without touching the network.
        Schemas.clear
        Schemas.resolve("/demo.Users/GetUser", request: true).should be_nil
        Schemas.load_project(store)
        Schemas.resolve("/demo.Users/GetUser", request: true).should_not be_nil
      end
    end

    it "names the reflected target in the settings row's status" do
      with_store do |store|
        set = Reflection.descriptor_set([demo_file_descriptor])
        Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, set)
        Schemas.status.should start_with("reflection https://api.test:443 · ")
        # A project that only ever reflected has no file count to print — "0 files" beside a
        # loaded reflection reads as a partial failure.
        Schemas.status.should_not contain("0 files")
        Schemas.sources.map(&.origin).should eq([Schemas::Origin::Reflection])
        Schemas.sources[0].label.should eq("https://api.test:443")
      end
    end

    it "names both halves when a file and a reflection are loaded together" do
      dir = File.tempname("gori-protos")
      Dir.mkdir_p(dir)
      begin
        File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
        with_store do |store|
          Schemas.apply(dir)
          Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, rival_set)
          Schemas.status.should start_with("1 file · reflection https://api.test:443 · ")
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "counts several reflected targets rather than listing them on one row" do
      with_store do |store|
        set = Reflection.descriptor_set([demo_file_descriptor])
        Schemas.adopt(store, "https://a.test:443", Reflection::SERVICE_V1, 1, 1, set)
        Schemas.adopt(store, "https://b.test:443", Reflection::SERVICE_V1, 1, 1, set)
        Schemas.status.should contain("reflection ×2")
      end
    end

    it "forgets a target and stops resolving through it" do
      with_store do |store|
        set = Reflection.descriptor_set([demo_file_descriptor])
        Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, set)
        Schemas.resolve("/demo.Users/GetUser", request: true).should_not be_nil
        Schemas.forget(store, "https://api.test:443").should be_true
        Schemas.resolve("/demo.Users/GetUser", request: true).should be_nil
        Schemas.status.should eq("no descriptor set loaded")
      end
    end

    it "keeps the reflected sources when the descriptor PATH is edited" do
      with_store do |store|
        set = Reflection.descriptor_set([demo_file_descriptor])
        Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, set)
        rev = Schemas.revision
        Schemas.apply("") # the Project settings row cleared, which is not a withdrawal
        Schemas.revision.should be > rev
        Schemas.resolve("/demo.Users/GetUser", request: true).should_not be_nil
      end
    end

    it "counts a reflected redefinition of a file-loaded message rather than hiding it" do
      dir = File.tempname("gori-protos")
      Dir.mkdir_p(dir)
      begin
        File.write(File.join(dir, "demo.desc"), Base64.decode(DEMO_DESC_B64))
        with_store do |store|
          Schemas.apply(dir)
          Schemas.schema.not_nil!.message?("demo.User").not_nil!.fields.size.should be > 1
          # Reflection loads LAST, so the server's word supersedes — and the disagreement is
          # counted, never silent.
          Schemas.adopt(store, "https://api.test:443", Reflection::SERVICE_V1, 1, 1, rival_set)
          Schemas.schema.not_nil!.message?("demo.User").not_nil!.fields.size.should eq(1)
          Schemas.schema.not_nil!.conflicts.should be > 0
          Schemas.status.should contain("redefined")
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "reports a cached blob that will not parse instead of dropping the row" do
      with_store do |store|
        store.put_grpc_reflection("https://api.test:443", "s", 1, 1, "not a descriptor set".to_slice)
        Schemas.load_project(store)
        Schemas.errors?.should be_true
        Schemas.sources[0].origin.reflection?.should be_true
        Schemas.sources[0].error.should_not be_nil
        Schemas.status.should contain("https://api.test:443")
      end
    end
  end
end
