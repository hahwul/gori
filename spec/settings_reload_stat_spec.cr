require "./spec_helper"

# `Settings.reload_section` stats the file before it reads it: a section whose file has not
# moved since it was last settled costs a `File.info`, not a `File.read` — the TUI asks for
# three sections on every data_version poll. The cache must still see a real write.
private def with_settings_file(&)
  dir = File.tempname("gori-reload-stat")
  Dir.mkdir_p(dir)
  path = File.join(dir, "settings.json")
  prev = Gori::Settings.path_override
  begin
    Gori::Settings.path_override = path
    Gori::Settings.forget_reloaded_sections
    yield path
  ensure
    Gori::Settings.path_override = prev
    Gori::Settings.forget_reloaded_sections
    FileUtils.rm_rf(dir)
  end
end

describe "Settings.reload_section stat gate" do
  it "folds a section once, skips it while the file is unchanged, and folds again after a write" do
    with_settings_file do |path|
      File.write(path, {"saved_views" => {"views" => [{"name" => "one", "query" => "status:200"}]}}.to_json)
      Gori::Settings.reload_saved_views_from_disk
      Gori::Settings.saved_views.map(&.name).should eq(["one"])

      # Changed behind the cache with a NEWER mtime: seen.
      sleep 20.milliseconds
      File.write(path, {"saved_views" => {"views" => [{"name" => "one", "query" => "status:200"}, {"name" => "two", "query" => "status:404"}]}}.to_json)
      Gori::Settings.reload_saved_views_from_disk
      Gori::Settings.saved_views.map(&.name).should eq(["one", "two"])

      # `forget_reloaded_sections` drops the stat too, so a spec that mutates the globals
      # behind the file gets a fresh fold.
      Gori::Settings.forget_reloaded_sections
      Gori::Settings.reload_saved_views_from_disk
      Gori::Settings.saved_views.map(&.name).should eq(["one", "two"])
    end
  end
end
