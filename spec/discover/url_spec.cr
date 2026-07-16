require "../spec_helper"

private alias U = Gori::Discover::Url

describe Gori::Discover::Url do
  it "folds numeric/uuid/hex/date path segments in the template key" do
    p1 = U.parse("http://h/user/1/edit").not_nil!
    p2 = U.parse("http://h/user/2/edit").not_nil!
    U.template_key(p1).should eq(U.template_key(p2))
    U.template_key(p1).should contain("{n}")

    u1 = U.parse("http://h/o/550e8400-e29b-41d4-a716-446655440000").not_nil!
    U.template_key(u1).should contain("{uuid}")
  end

  it "keeps query values in the visit key but drops them in the template key" do
    a = U.parse("http://h/s?page=1").not_nil!
    b = U.parse("http://h/s?page=2").not_nil!
    U.visit_key(a).should_not eq(U.visit_key(b))
    U.template_key(a).should eq(U.template_key(b))
  end

  it "normalizes host case and default port in the visit key" do
    U.visit_key(U.parse("http://H:80/x").not_nil!).should eq(U.visit_key(U.parse("http://h/x").not_nil!))
  end

  it "resolves relative, absolute-path, scheme-relative, absolute, and dot-segment links" do
    base = U.parse("http://h/a/b/page").not_nil!
    U.resolve(base, "c").should eq("http://h/a/b/c")
    U.resolve(base, "../x").should eq("http://h/a/x")
    U.resolve(base, "/root").should eq("http://h/root")
    U.resolve(base, "//other/z").should eq("http://other/z")
    U.resolve(base, "https://ext/y").should eq("https://ext/y")
    U.resolve(base, "mailto:a@b").should be_nil
    U.resolve(base, "javascript:void(0)").should be_nil
    U.resolve(base, "#frag").should be_nil
  end

  it "derives the directory of a url" do
    U.dir_of(U.parse("http://h/a/b/c").not_nil!).should eq("http://h/a/b/")
    U.dir_of(U.parse("http://h/").not_nil!).should eq("http://h/")
  end
end
