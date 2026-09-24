require "../spec_helper"
require "file_utils"

# Map-local path confinement (#1237). The request target is the client's bytes, and here they
# name a LOCAL FILE — so every refusal case below is a way a crafted path could otherwise read
# something outside the directory the operator mapped.

private alias ML = Gori::RuleStub::MapLocal

private def with_mapped_dir(&)
  base = File.realpath(Dir.tempdir)
  root = File.join(base, "gori-maplocal-#{Random.new.hex(6)}")
  outside = File.join(base, "gori-maplocal-out-#{Random.new.hex(6)}")
  Dir.mkdir_p(File.join(root, "js"))
  Dir.mkdir_p(File.join(root, "docs"))
  Dir.mkdir_p(outside)
  File.write(File.join(root, "js", "app.js"), "console.log(1)")
  File.write(File.join(root, "index.html"), "<h1>root</h1>")
  File.write(File.join(root, "docs", "index.html"), "<h1>docs</h1>")
  File.write(File.join(root, "a+b.txt"), "plus")
  File.write(File.join(root, "%2e"), "literal percent name")
  File.write(File.join(root, ".env"), "SECRET=1")
  File.write(File.join(outside, "secret.txt"), "outside")
  begin
    yield root, outside
  ensure
    FileUtils.rm_rf(root)
    FileUtils.rm_rf(outside)
  end
end

private def resolve(root, target, prefix = "")
  ML.resolve(root, prefix, target)
end

describe Gori::RuleStub::MapLocal do
  it "serves a file under the root, the query and fragment dropped" do
    with_mapped_dir do |root, _|
      res = resolve(root, "/static/js/app.js?v=3#x", "/static/")
      res.outcome.should eq(ML::Outcome::Hit)
      res.path.should eq(File.join(root, "js", "app.js"))
      res.rel.should eq("js/app.js")
    end
  end

  it "serves index.html for a path ending in /, and never lists a directory" do
    with_mapped_dir do |root, _|
      resolve(root, "/").path.should eq(File.join(root, "index.html"))
      resolve(root, "/static/", "/static/").path.should eq(File.join(root, "index.html"))
      resolve(root, "/docs/").path.should eq(File.join(root, "docs", "index.html"))
      # A directory named WITHOUT the slash is not a file: missing, not a listing.
      resolve(root, "/docs").outcome.should eq(ML::Outcome::Missing)
    end
  end

  it "does not claim a path outside strip_prefix, nor a target that is not origin-form" do
    with_mapped_dir do |root, _|
      resolve(root, "/other/app.js", "/static/").outcome.should eq(ML::Outcome::NotClaimed)
      resolve(root, "/static-admin/x", "/static/").outcome.should eq(ML::Outcome::NotClaimed)
      resolve(root, "*").outcome.should eq(ML::Outcome::NotClaimed)
      resolve(root, "http://evil.test/js/app.js").outcome.should eq(ML::Outcome::NotClaimed)
    end
  end

  it "reports an absent file as missing, which the rule's fallthrough decides" do
    with_mapped_dir do |root, _|
      resolve(root, "/js/nope.js").outcome.should eq(ML::Outcome::Missing)
    end
  end

  it "refuses every spelling of a dot segment, a backslash and a NUL" do
    with_mapped_dir do |root, _|
      {
        "/../../etc/passwd",
        "/js/../../etc/passwd",
        "/%2e%2e/%2e%2e/etc/passwd",
        "/%2E%2E%2Fetc%2Fpasswd",
        "/..%2f..%2fetc/passwd",
        "/js/..\\..\\etc",
        "/js/%5c..%5cetc",
        "/js/app.js%00.png",
        "/./index.html",
        "/.env",
        "/js/%2eenv",
      }.each do |target|
        res = resolve(root, target)
        res.outcome.should eq(ML::Outcome::Refused)
      end
    end
  end

  it "refuses malformed percent-encoding instead of passing it through as text" do
    with_mapped_dir do |root, _|
      resolve(root, "/js/app%zz.js").outcome.should eq(ML::Outcome::Refused)
      resolve(root, "/js/app.js%2").outcome.should eq(ML::Outcome::Refused)
      resolve(root, "/js/%ff").outcome.should eq(ML::Outcome::Refused) # not UTF-8
    end
  end

  it "decodes exactly once, and not as a form" do
    with_mapped_dir do |root, _|
      # `%252e` is the literal name `%2e`, not a second-round `.`.
      resolve(root, "/%252e").path.should eq(File.join(root, "%2e"))
      # `+` is a plus sign in a path, not a space.
      resolve(root, "/a+b.txt").path.should eq(File.join(root, "a+b.txt"))
      resolve(root, "/a%2Bb.txt").path.should eq(File.join(root, "a+b.txt"))
    end
  end

  it "refuses a symlink that leads out of the root, and serves one that stays inside" do
    with_mapped_dir do |root, outside|
      File.symlink("/", File.join(root, "escape"))
      File.symlink(File.join(outside, "secret.txt"), File.join(root, "leak.txt"))
      File.symlink(File.join(root, "js", "app.js"), File.join(root, "alias.js"))
      resolve(root, "/escape/etc/hosts").outcome.should eq(ML::Outcome::Refused)
      resolve(root, "/leak.txt").outcome.should eq(ML::Outcome::Refused)
      resolve(root, "/alias.js").path.should eq(File.join(root, "js", "app.js"))
    end
  end

  it "serves under a root of / without refusing everything" do
    with_mapped_dir do |root, _|
      rel = File.join(root, "js", "app.js").lchop('/')
      res = resolve("/", "/#{rel}")
      res.outcome.should eq(ML::Outcome::Hit)
    end
  end

  it "calls a root that is gone or is not a directory broken, never missing" do
    with_mapped_dir do |root, _|
      resolve(File.join(root, "js", "app.js"), "/x.js").outcome.should eq(ML::Outcome::Broken)
      resolve(File.join(root, "gone"), "/x.js").outcome.should eq(ML::Outcome::Broken)
    end
  end

  it "looks a Content-Type up by extension, and guesses nothing else" do
    ML.content_type("/a/app.js").should eq("text/javascript; charset=utf-8")
    ML.content_type("/a/LOGO.PNG").should eq("image/png")
    ML.content_type("/a/data.bin").should be_nil
    ML.content_type("/a/Makefile").should be_nil
  end

  it "neutralises and clips a served path before a flow shows it" do
    ML.display("js/\e[31mred.js").should eq("js/·[31mred.js")
    ML.display("a" * 100).size.should eq(ML::REF_PATH_MAX)
  end
end
