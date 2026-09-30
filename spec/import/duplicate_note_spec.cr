require "../spec_helper"
require "file_utils"

# #1395: nothing deduplicates an import, so the same HAR imported twice doubled History with
# no word. `Import.duplicate_note` warns — never refuses — from the provenance stamp each
# imported flow carries (`source_ref` = the file's basename), on every surface that imports.
# `import_text` has no file name of its own, so it neither trips nor stamps a name that would.

private def with_url_list(name : String, &)
  dir = File.tempname("gori-dup")
  Dir.mkdir(dir)
  path = File.join(dir, name)
  File.write(path, "https://shop.test/a\nhttps://shop.test/b\n")
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "Gori::Import duplicate note" do
  it "says nothing on a first import, and names the earlier one on a second" do
    with_store do |store|
      with_url_list("targets.txt") do |path|
        first = Gori::Import.import_file(store, :urls, path)
        first.count.should eq(2)
        first.notes.should be_empty

        second = Gori::Import.import_file(store, :urls, path)
        second.count.should eq(2) # a warning, not a refusal
        note = second.notes.join
        note.should contain("2 flows are already in this project")
        note.should contain(%("targets.txt"))
        store.count.should eq(4)
      end
    end
  end

  it "does not trip on a different file name, or on text imports" do
    with_store do |store|
      with_url_list("one.txt") { |p| Gori::Import.import_file(store, :urls, p) }
      with_url_list("two.txt") { |p| Gori::Import.import_file(store, :urls, p).notes.should be_empty }
      text = "https://shop.test/c\n"
      Gori::Import.import_text(store, :urls, text).notes.should be_empty
      Gori::Import.import_text(store, :urls, text).notes.should be_empty
    end
  end

  it "imports every format from text, staged privately and removed" do
    with_store do |store|
      before = Dir.children(Dir.tempdir).count(&.starts_with?("gori-import"))
      result = Gori::Import.import_text(store, :urls, "https://shop.test/x\nhttps://shop.test/y\n")
      result.count.should eq(2)
      Dir.children(Dir.tempdir).count(&.starts_with?("gori-import")).should eq(before)
      expect_raises(Gori::Error, /empty/) { Gori::Import.import_text(store, :har, "  ") }
    end
  end
end
