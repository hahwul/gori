require "../spec_helper"
require "../../src/gori/replay/subtab_filter"

include Gori

private def subj(name : String?, summary : String, target : String, method : String, tags : Array(String)) : Replay::SubtabFilter::Subject
  Replay::SubtabFilter::Subject.new(name, summary, target, method, tags)
end

private def filtered(query : String, list : Array(Replay::SubtabFilter::Subject)) : Array(Replay::SubtabFilter::Subject)
  Replay::SubtabFilter.parse(query).apply(list)
end

describe Gori::Replay::Tags do
  it "splits on whitespace and commas, strips a leading #, dedupes case-insensitively" do
    Replay::Tags.parse("idor  #auth, IDOR").should eq(["idor", "auth"])
    Replay::Tags.parse(nil).should eq([] of String)
    Replay::Tags.parse("   ").should eq([] of String)
  end

  it "serializes to a space-joined string (nil when empty)" do
    Replay::Tags.serialize(["idor", "auth"]).should eq("idor auth")
    Replay::Tags.serialize([] of String).should be_nil
  end

  it "round-trips parse ∘ serialize" do
    Replay::Tags.parse(Replay::Tags.serialize(["a", "b-c"])).should eq(["a", "b-c"])
  end
end

describe Gori::Replay::SubtabFilter do
  list = [
    subj("orders probe", "GET /orders", "https://app.example.com/orders", "GET", ["idor", "auth"]),
    subj(nil, "POST /login", "https://api.example.com/login", "POST", ["auth"]),
    subj("done", "DELETE /cart", "https://app.example.com/cart", "DELETE", ["done"]),
  ]

  it "passes everything for an empty query" do
    filtered("", list).size.should eq(3)
    Replay::SubtabFilter.parse("").empty?.should be_true
  end

  it "filters by tag (case-insensitive substring over any tag)" do
    filtered("tag:idor", list).map(&.summary).should eq(["GET /orders"])
    filtered("tag:auth", list).size.should eq(2)
    filtered("tag:AUTH", list).size.should eq(2)
  end

  it "filters by name, host/target and method" do
    filtered("name:orders", list).map(&.summary).should eq(["GET /orders"])
    filtered("host:api", list).map(&.summary).should eq(["POST /login"])
    filtered("target:app.example", list).size.should eq(2)
    filtered("method:post", list).map(&.summary).should eq(["POST /login"])
  end

  it "negates a field term with a leading -" do
    filtered("-tag:done", list).map(&.summary).should eq(["GET /orders", "POST /login"])
    filtered("tag:auth -host:api", list).map(&.summary).should eq(["GET /orders"])
  end

  it "treats an empty value as match-all (mid-type), and its negation as match-none" do
    filtered("tag:", list).size.should eq(3)
    filtered("-tag:", list).size.should eq(0)
  end

  it "matches bare words as free text over name/summary/target/tags" do
    filtered("login", list).map(&.summary).should eq(["POST /login"]) # summary
    filtered("idor", list).map(&.summary).should eq(["GET /orders"])  # tag
    filtered("orders", list).size.should eq(1)                        # name + summary + target
  end

  it "AND-joins multiple terms" do
    filtered("tag:auth method:get", list).map(&.summary).should eq(["GET /orders"])
    filtered("tag:auth method:patch", list).should be_empty
  end

  describe ".suggestions" do
    it "completes field names from a partial token" do
      Replay::SubtabFilter.suggestions("ta", 2, list).should eq(["tag:", "target:"])
      Replay::SubtabFilter.suggestions("me", 2, list).should eq(["method:"])
    end

    it "suggests tag/name/host values from open sessions" do
      Replay::SubtabFilter.suggestions("tag:", 4, list).should eq(["tag:idor", "tag:auth", "tag:done"])
      Replay::SubtabFilter.suggestions("tag:i", 5, list).should eq(["tag:idor"])
      Replay::SubtabFilter.suggestions("name:", 5, list).should contain("name:orders probe")
      Replay::SubtabFilter.suggestions("host:api", 8, list).should eq(["host:api.example.com"])
    end

    it "suggests methods from sessions plus the static set" do
      m = Replay::SubtabFilter.suggestions("method:", 7, list)
      m.should contain("method:GET")
      m.should contain("method:POST")
      m.should contain("method:DELETE")
      m.should contain("method:PUT") # static gap-fill
    end

    it "honours a leading - on field and value suggestions" do
      Replay::SubtabFilter.suggestions("-ta", 3, list).should eq(["-tag:", "-target:"])
      Replay::SubtabFilter.suggestions("-tag:a", 6, list).should eq(["-tag:auth"])
    end

    it "returns nothing for an empty token (caret on whitespace)" do
      Replay::SubtabFilter.suggestions("tag:idor ", 9, list).should be_empty
      Replay::SubtabFilter.suggestions("", 0, list).should be_empty
    end
  end

  describe ".host_of" do
    it "extracts the host from a URL" do
      Replay::SubtabFilter.host_of("https://app.example.com/orders").should eq("app.example.com")
      Replay::SubtabFilter.host_of("http://localhost:8080/").should eq("localhost")
    end
  end
end
