require "../spec_helper"
require "file_utils"

include Gori::Tui

# What the project picker says when a create or a rename does NOT happen. Both used to end
# in a bare `return`: the form stayed up with the operator's text still in it and nothing
# said, so a name gori refuses and a disk that is full both read as `↵` being a dead key.
# The picker holds a live Termisu and cannot be built here, so the sentence lives in a class
# method — the same shape `meta_segments` and `ProjectMarks` use.

private def with_project_root(&)
  root = File.tempname("gori-projroot")
  begin
    yield Gori::ProjectRegistry.new(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

describe "ProjectPicker.failed_flash" do
  it "names the verb, the name typed, and the raised reason" do
    msg = ProjectPicker.failed_flash("create", "!!!",
      Gori::Error.new(Gori::ProjectRegistry::UNSLUGGABLE_NAME))
    msg.should contain(%("!!!"))
    msg.should contain("can't create")
    msg.should contain("at least one letter or digit")
  end

  it "distinguishes a refused name from a filesystem failure" do
    # The whole reason the reason is carried through rather than replaced by one generic
    # sentence: "fix the name" and "free some disk" are different next steps.
    disk = ProjectPicker.failed_flash("create", "acme", File::Error.new("no space left on device", file: "/x"))
    disk.should contain("no space left on device")
    disk.should_not contain("letter or digit")
  end

  it "still produces a sentence for an exception carrying no message" do
    # Silence is the defect being fixed, so an empty `message` must not reintroduce it.
    msg = ProjectPicker.failed_flash("rename", "acme", IO::Error.new)
    msg.should contain(%(can't rename "acme"))
    msg.should_not end_with("— ")
  end
end

describe Gori::ProjectRegistry do
  it "names the RULE a refused project name broke, not just the verdict" do
    with_project_root do |reg|
      # An ASCII-punctuation-only name has nothing to slugify (a dot-run must never become a
      # path), while any name carrying a non-ASCII character gets a hashed fallback slug —
      # so "a letter or a digit" is the whole of what is missing.
      ex = expect_raises(Gori::Error) { reg.create("...") }
      ex.message.not_nil!.should contain("at least one letter or digit")

      # A rename breaks a DIFFERENT rule (it never touches the slug), so it gets its own
      # sentence rather than one that would send the operator hunting for a missing letter
      # in a name they left blank.
      project = reg.create("acme")
      blank = expect_raises(Gori::Error) { reg.rename(project, "   ") }
      blank.message.not_nil!.should contain("cannot be blank")
    end
  end
end
