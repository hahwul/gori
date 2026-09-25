require "../../spec_helper"

private def project_archive_cli_source : String
  File.read(File.join(__DIR__, "..", "..", "..", "src", "gori", "cli", "run", "project.cr"))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def project_archive_cli_method(source : String, name : String) : String
  source[/(private )?def self\.#{Regex.escape(name)}\b.*?\n      end/m].not_nil!
end

describe "gori run project archive commands" do
  it "routes both verbs and lists them in project help" do
    source = project_archive_cli_source
    dispatch = project_archive_cli_method(source, "cmd_project")
    dispatch.should contain("when \"export\", \"import\"")
    dispatch.should contain("cmd_project_archive(args)")
    archive_dispatch = project_archive_cli_method(source, "cmd_project_archive")
    archive_dispatch.should contain("when \"export\" then cmd_project_export(args[1..])")
    archive_dispatch.should contain("when \"import\" then cmd_project_import(args[1..])")
    source.should contain("export <name>")
    source.should contain("import <archive>")
  end

  it "shows the export inventory before atomically writing a confirmed destination" do
    source = project_archive_cli_source
    export = project_archive_cli_method(source, "cmd_project_export")
    export.should contain("p.on(\"-o PATH\", \"--output=PATH\"")
    export.should contain("p.on(\"--force\"")
    export.should contain("ProjectArchive.disclosure(prepared.inventory)")
    export.index!("STDERR.puts").should be < export.index!("prepared.write(")
    export.should contain("overwrite: force")
    # The engine's refusal names no flag; the CLI adds its own.
    export.should contain("rescue ex : ProjectArchive::DestinationExists")
    export.should contain("(use --force to replace it)")
  end

  it "validates and discloses an archive before registering its new project" do
    source = project_archive_cli_source
    import = project_archive_cli_method(source, "cmd_project_import")
    import.should contain("p.on(\"--name=NAME\"")
    import.should contain("ProjectArchive.prepare_import(positional.first)")
    import.should contain("ProjectArchive.disclosure(prepared.inventory)")
    import.index!("STDERR.puts").should be < import.index!("prepared.import_into(")
    import.should contain("ProjectRegistry.new(Paths.projects_dir)")
  end
end
