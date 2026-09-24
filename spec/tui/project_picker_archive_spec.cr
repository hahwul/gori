require "../spec_helper"

# The picker owns a live Termisu, so archive-mode coverage follows the source-reading
# convention used by the adjacent project-picker specs.

private def picker_archive_code(*parts : String) : String
  File.read(File.join(__DIR__, "..", "..", "src", "gori", *parts))
    .lines.reject(&.lstrip.starts_with?('#')).join('\n')
end

private def picker_archive_method(source : String, name : String) : String
  source[/(private )?def #{Regex.escape(name)}\b.*?\n    end/m].not_nil!
end

describe "project archive modes in ProjectPicker" do
  it "routes key, preedit, click, wheel, rendering and shutdown through their own overlays" do
    source = picker_archive_code("tui", "project_picker.cr")
    run = picker_archive_method(source, "run")
    run.should contain("when :archive_export_path then handle_archive_export_path(ev)")
    run.should contain("when :archive_import_path then handle_archive_import_path(ev)")
    run.should contain("when :archive_import_name then handle_archive_import_name(ev)")
    run.should contain("@archive_export_overlay.try(&.set_preedit(ev.text))")
    run.should contain("@archive_import_overlay.try(&.set_preedit(ev.text))")
    run.should contain("@archive_name_overlay.try(&.set_preedit(ev.text))")
    run.should contain("@prepared_export.try(&.close)")
    run.should contain("@prepared_import.try(&.close)")

    picker_archive_method(source, "handle_picker_mouse").should contain(
      "when :archive_import_path then handle_archive_import_click(")
    name_click = picker_archive_method(source, "handle_archive_name_click")
    name_click.should contain("if outcome == :cancel")
    name_click.should contain("close_archive_import")
    name_click.should contain("@mode = :list")
    wheel = picker_archive_method(source, "picker_wheel")
    wheel.should match(/when :archive_export_path\s+then @archive_export_overlay\.try\(&\.move\(delta\)\)/)
    wheel.should match(/when :archive_import_path\s+then @archive_import_overlay\.try\(&\.move\(delta\)\)/)
    render = picker_archive_method(source, "render")
    render.should contain("render_archive_overlay(screen, w, h)")
    archive_render = picker_archive_method(source, "render_archive_overlay")
    archive_render.should contain("@archive_export_overlay.try(&.render(")
    archive_render.should contain("@archive_import_overlay.try(&.render(")
    archive_render.should contain("@archive_name_overlay.try(&.render(")
  end

  it "requires review before writing or importing and releases staged state on cancel" do
    source = picker_archive_code("tui", "project_picker.cr")
    prepare_export = picker_archive_method(source, "prepare_archive_export")
    prepare_export.should contain("ProjectArchive.disclosure(prepared.inventory)")
    prepare_export.should contain("@confirm_kind = :archive_export")
    prepare_export.should contain("dialog.message_fits?")
    prepare_export.should match(/prepared\.close\n\s+close_archive_export\n\s+@mode = :list\n\s+set_flash\("window too small to review a project export/)
    prepare_export.should match(/prepared = ProjectArchive\.prepare_export\(project\)\n\s+@prepared_export = prepared\n\s+destination_note =/)
    prepare_import = picker_archive_method(source, "prepare_archive_import")
    prepare_import.should contain("ProjectArchive.disclosure(prepared.inventory)")
    prepare_import.should contain("@confirm_kind = :archive_import_review")
    prepare_import.should contain("dialog.message_fits?")
    prepare_import.should match(/prepared\.close\n\s+close_archive_import\n\s+@mode = :list\n\s+set_flash\("window too small to review a project archive/)
    prepare_import.should match(/prepared = ProjectArchive\.prepare_import\(.*\)\n\s+@prepared_import = prepared\n\s+dialog = ConfirmDialog\.new/)

    cancel = picker_archive_method(source, "cancel_confirm")
    cancel.should contain("close_archive_export if @confirm_kind == :archive_export")
    cancel.should contain("close_archive_import if @confirm_kind == :archive_import_review")
    picker_archive_method(source, "close_archive_import").should contain("@prepared_import.try(&.close)")
  end

  it "exposes import from the empty Search row and export/import from project actions" do
    source = picker_archive_code("tui", "project_picker.cr")
    source.should contain("@selected >= 3 || (@selected == 2 && @query.empty?)")
    picker_archive_method(source, "open_space_menu").should contain("@selected == 2 && @query.empty?")
    choose = picker_archive_method(source, "activate_space_entry")
    choose.should contain("when :archive_import")
    choose.should contain("when :archive_export")
    picker_archive_method(source, "handle_list").should contain("if space_opens_menu?")
    picker_archive_method(source, "commit_archive_import").should contain("@query = \"\"")
  end
end
