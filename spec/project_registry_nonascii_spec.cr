require "./spec_helper"
require "file_utils"

# Fix #5 — an all-non-ASCII project name (e.g. "日本語") used to slugify to "" and be
# rejected as "invalid project name", making such projects unusable via --project.
# ProjectRegistry#slugify now derives a stable, filesystem-safe fallback slug for them
# WITHOUT changing any existing ASCII project's directory name.
private def with_nonascii_root(&)
  root = File.tempname("gori-registry-nonascii")
  begin
    yield root
  ensure
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

describe Gori::ProjectRegistry do
  it "creates a usable project for an all-non-ASCII display name (stable hashed slug)" do
    with_nonascii_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      p = reg.create("日本語")
      p.name.should eq("日本語") # verbatim display name preserved
      slug = File.basename(p.dir)
      slug.should start_with("project-") # ASCII-safe fallback slug
      slug.matches?(/\Aproject-[0-9a-f]+\z/).should be_true
      Dir.exists?(p.dir).should be_true
      # Deterministic: reopening the same name resolves to the SAME directory.
      reg.create("日本語").dir.should eq(p.dir)
      # Materialize the DB so list/find sees the project (as the sibling specs do),
      # then confirm it's addressable by its verbatim display name via #find.
      Gori::Store.open(p.db_path).close
      reg.find("日本語").try(&.dir).should eq(p.dir)
    end
  end

  it "leaves an ASCII name's slug unchanged by the non-ASCII fallback" do
    with_nonascii_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      reg.create("ACME Red Team!").db_path.should eq(File.join(root, "acme-red-team", "gori.db"))
    end
  end

  it "still rejects a blank / ASCII-punctuation-only name (no '.'/'..' traversal)" do
    with_nonascii_root do |root|
      reg = Gori::ProjectRegistry.new(root)
      expect_raises(Gori::Error, /invalid project name/) { reg.create("   ") }
      expect_raises(Gori::Error, /invalid project name/) { reg.create("..") }
      expect_raises(Gori::Error, /invalid project name/) { reg.create("---") }
    end
  end
end
