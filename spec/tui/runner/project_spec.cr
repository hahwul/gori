require "../../spec_helper"
require "../../support/tui_contract"

private class ProjectTagRunner < Gori::Tui::Runner
  def prepare(@session : Gori::Session) : Nil
    @tabs = {:project => Gori::Tui::ProjectController.new(FakeHost.new(@session)).as(Gori::Tui::TabController)}
    @overlay = @palette_return = Gori::Tui::OverlayKind::None
  end

  def tag_card : Gori::Tui::TagPromptOverlay
    project_edit_tags
    @active_overlay.as(Gori::Tui::TagPromptOverlay)
  end

  getter toast
end

describe "the Project tag editor" do
  it "preserves a peer's replacement and its own draft until the editor is reopened" do
    reg = Gori::ProjectRegistry.new(Gori::Paths.projects_dir)
    project = reg.create("tag-editor-#{Random::Secure.hex(5)}", tags: ["original"])
    session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
      Gori::Proxy::Tls::CertAuthority.load_or_create(TuiContract::CA_ROOT), Gori::Verbs.registry, project)
    begin
      runner = ProjectTagRunner.allocate
      runner.prepare(session)
      card = runner.tag_card
      card.input.tags << "draft"
      Gori::ProjectRegistry.new(Gori::Paths.projects_dir).set_tags(project, ["peer"])
      card.commit.should be_false
      card.tags.should eq(["original", "draft"])
      runner.toast.not_nil!.should contain("reopen")
      reg.tags_of(project).should eq(["peer"])

      reopened = runner.tag_card
      reopened.tags.should eq(["peer"])
      reopened.input.tags << "draft"
      reopened.commit.should be_true
      reg.tags_of(project).should eq(["peer", "draft"])
    ensure
      session.close
      FileUtils.rm_rf(project.dir)
    end
  end
end
