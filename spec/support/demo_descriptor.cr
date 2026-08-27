require "../../src/gori"
require "base64"

# A REAL `protoc` FileDescriptorSet, shared by every spec that needs a `.proto` lens.
#
# Hand-encoding one here would only prove the spec agrees with whatever this file's author
# believed `descriptor.proto` says — the failure mode a parser spec exists to catch — so the
# bytes come from the tool the feature is built around, checked in as base64 because the
# repo keeps no binary fixtures.
#   $ cat demo.proto
#     syntax = "proto3";
#     package demo;
#     enum Role { ROLE_UNKNOWN = 0; ROLE_USER = 1; ROLE_ADMIN = 2; }
#     message Profile { int32 age = 1; repeated string tags = 2; }
#     message Outer {
#       message Inner { string label = 1; }
#       enum Kind { KIND_A = 0; KIND_B = 1; }
#       Inner inner = 1;
#       Kind kind = 2;
#     }
#     message User {
#       int64 id = 1;  string name = 2;   Role role = 3;      Profile profile = 4;
#       bytes token = 5;  repeated int32 scores = 6;  bool active = 7;  double ratio = 8;
#       float small = 9;  sint32 delta = 10;  fixed64 serial = 11;  Outer outer = 12;
#     }
#     message GetUserRequest { string name = 1; }
#     service Users {
#       rpc GetUser(GetUserRequest) returns (User);
#       rpc Watch(stream GetUserRequest) returns (stream User);
#     }
#   $ protoc -I. --descriptor_set_out=demo.desc demo.proto
DEMO_DESC_B64 = "CuAFCgpkZW1vLnByb3RvEgRkZW1vIi8KB1Byb2ZpbGUSEAoDYWdlGAEgASgFUgNhZ2USEgoEdGFn" \
                "cxgCIAMoCVIEdGFncyKVAQoFT3V0ZXISJwoFaW5uZXIYASABKAsyES5kZW1vLk91dGVyLklubmVy" \
                "UgVpbm5lchIkCgRraW5kGAIgASgOMhAuZGVtby5PdXRlci5LaW5kUgRraW5kGh0KBUlubmVyEhQK" \
                "BWxhYmVsGAEgASgJUgVsYWJlbCIeCgRLaW5kEgoKBktJTkRfQRAAEgoKBktJTkRfQhABIrYCCgRV" \
                "c2VyEg4KAmlkGAEgASgDUgJpZBISCgRuYW1lGAIgASgJUgRuYW1lEh4KBHJvbGUYAyABKA4yCi5k" \
                "ZW1vLlJvbGVSBHJvbGUSJwoHcHJvZmlsZRgEIAEoCzINLmRlbW8uUHJvZmlsZVIHcHJvZmlsZRIU" \
                "CgV0b2tlbhgFIAEoDFIFdG9rZW4SFgoGc2NvcmVzGAYgAygFUgZzY29yZXMSFgoGYWN0aXZlGAcg" \
                "ASgIUgZhY3RpdmUSFAoFcmF0aW8YCCABKAFSBXJhdGlvEhQKBXNtYWxsGAkgASgCUgVzbWFsbBIU" \
                "CgVkZWx0YRgKIAEoEVIFZGVsdGESFgoGc2VyaWFsGAsgASgGUgZzZXJpYWwSIQoFb3V0ZXIYDCAB" \
                "KAsyCy5kZW1vLk91dGVyUgVvdXRlciIkCg5HZXRVc2VyUmVxdWVzdBISCgRuYW1lGAEgASgJUgRu" \
                "YW1lKjcKBFJvbGUSEAoMUk9MRV9VTktOT1dOEAASDQoJUk9MRV9VU0VSEAESDgoKUk9MRV9BRE1J" \
                "ThACMmMKBVVzZXJzEisKB0dldFVzZXISFC5kZW1vLkdldFVzZXJSZXF1ZXN0GgouZGVtby5Vc2Vy" \
                "Ei0KBVdhdGNoEhQuZGVtby5HZXRVc2VyUmVxdWVzdBoKLmRlbW8uVXNlcigBMAFiBnByb3RvMw=="

# A `demo.User` serialised by the reference Python protobuf runtime from that same
# descriptor set — so the expected readings below are the ENCODER's, not this spec's:
#   id=-7, name="hahwul", role=ROLE_ADMIN, profile{age:30, tags:["red","blue"]},
#   token=deadbeef, scores=[1,2,300], active=true, ratio=0.5, small=1.5, delta=-3,
#   serial=0xdeadbeefcafe, outer{inner{label:"deep"}, kind:KIND_B}
DEMO_USER_B64 = "CPn//////////wESBmhhaHd1bBgCIg0IHhIDcmVkEgRibHVlKgTerb7vMgQBAqwCOAFBAAAAAAAA" \
                "4D9NAADAP1AFWf7K776t3gAAYgoKBgoEZGVlcBAB"

def demo_schema : Gori::Protobuf::Schema
  Gori::Protobuf::Schema.parse(Base64.decode(DEMO_DESC_B64)).as(Gori::Protobuf::Schema)
end

def demo_user_message : Gori::Protobuf::Message
  Gori::Protobuf.decode(Base64.decode(DEMO_USER_B64))
end

# The reading for field `number` of the reference `demo.User` message.
def demo_reading(number : Int32) : Gori::Protobuf::Lens::Reading?
  s = demo_schema
  t = s.message?("demo.User").not_nil!
  f = demo_user_message.fields.find { |x| x.number == number }.not_nil!
  Gori::Protobuf::Lens.read(s, t, f)
end
