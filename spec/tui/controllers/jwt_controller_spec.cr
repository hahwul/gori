require "../../spec_helper"
require "../../support/memory_backend"
require "../../support/fake_host"
require "file_utils"

include Gori::Tui

module Gori::Tui
  class JwtController
    def cur_for_alg_spec : JwtSession
      cur
    end
  end
end

private JWT_CTL_CA = File.tempname("gori-jwt-ctl-ca")
Spec.after_suite { FileUtils.rm_rf(JWT_CTL_CA) }

private def with_jwt_controller(&)
  root = File.tempname("gori-jwt-ctl")
  Dir.mkdir_p(root)
  project = Gori::ProjectRegistry.new(root).temp("jwtctl")
  session = Gori::Session.open(Gori::Config.new(listen: "127.0.0.1", port: 0),
    Gori::Proxy::Tls::CertAuthority.load_or_create(JWT_CTL_CA), Gori::Verbs.registry, project)
  begin
    host = FakeHost.new(session)
    yield JwtController.new(host), host
  ensure
    session.close
    FileUtils.rm_rf(root) if Dir.exists?(root)
  end
end

# The ENCODE lens with the demo HS256 token's claims loaded, HEADER focused.
private def loaded_encode(c : JwtController) : JwtSession
  s = c.cur_for_alg_spec
  s.input.set_text(Gori::Jwt.encode(%({"typ":"JWT"}), %({"sub":"u1"}), "HS256", "k"))
  c.load_decoded
  s.pane.should eq(:header)
  s
end

# Rewrite HEADER's alg, then land the edit through the bulk-paste path a real edit takes (a
# leading space keeps the JSON valid wherever `set_text` left the caret).
private def type_header_alg(c : JwtController, s : JwtSession, from : String, to : String) : Nil
  s.header.set_text(s.header.text.sub(from, to))
  c.paste_text(" ").should be_true
end

private def output_alg(s : JwtSession) : String?
  Gori::Jwt.token_alg(s.output)
end

# `Jwt.encode` forces the badge alg into the header (the engine's documented contract). The
# TUI showed a HEADER the OUTPUT did not carry: `"alg": "none"` typed there went out HS256.
describe "JWT tab: HEADER's alg and the ^A badge" do
  it "moves the badge when HEADER is edited to an alg gori signs" do
    with_jwt_controller do |c, host|
      s = loaded_encode(c)
      type_header_alg(c, s, %("HS256"), %("none"))
      s.alg.should eq("none")
      output_alg(s).should eq("none")
      s.output.ends_with?('.').should be_true # unsigned, as HEADER says
      s.alg_note.should be_nil
      host.statuses.last.should contain("from HEADER")

      type_header_alg(c, s, %("none"), %("HS384"))
      s.alg.should eq("HS384")
      output_alg(s).should eq("HS384")
    end
  end

  it "says so on OUTPUT, instead of replacing an alg it cannot sign in silence" do
    with_jwt_controller do |c, _|
      s = loaded_encode(c)
      type_header_alg(c, s, %("HS256"), %("nOnE"))
      s.alg.should eq("HS256")         # not a badge gori has: it stays
      output_alg(s).should eq("HS256") # the engine contract is unchanged
      note = s.alg_note.should_not be_nil
      note.should contain(%("nOnE"))
      note.should contain("signed as HS256")
    end
  end

  it "keeps a ^A choice across later HEADER edits, and says the two differ" do
    with_jwt_controller do |c, _|
      s = loaded_encode(c)
      c.cycle_alg # HS256 -> HS384, HEADER still says HS256
      s.alg.should eq("HS384")
      s.alg_note.should_not be_nil
      # An edit that leaves HEADER's alg alone must not snap the badge back.
      type_header_alg(c, s, %("JWT"), %("jwt"))
      s.alg.should eq("HS384")
      output_alg(s).should eq("HS384")
      s.alg_note.not_nil!.should contain(%(alg "HS256"))
    end
  end

  it "names a HEADER with no alg rather than adding one silently" do
    with_jwt_controller do |c, _|
      s = c.cur_for_alg_spec
      s.header.set_text(%({"typ":"JWT"}))
      s.payload.set_text("{}")
      s.mode = :encode
      s.pane = :header
      c.paste_text(" ")
      s.alg_note.not_nil!.should contain("no alg")
    end
  end

  it "draws the note under the token on OUTPUT" do
    b = MemoryBackend.new(100, 34)
    JwtView.new.render_encode(Screen.new(b), Rect.new(0, 0, 100, 34),
      header: TextArea.new(%({"alg":"nOnE"})), payload: TextArea.new("{}"),
      secret: "", secret_cx: 0, secret_pre: "", alg: "HS256",
      output: "eyJ.eyJ.sig", output_ok: true, pane: :header, focused: true,
      alg_note: %(// WARNING: HEADER has alg "nOnE", signed as HS256 (^A alg)))
    b.contains?("eyJ.eyJ.sig").should be_true
    b.contains?("signed as HS256").should be_true
  end
end

# Nearly every typed HEADER edit passes through invalid JSON. Recording that as "no alg" made the
# return to valid JSON read as an alg change, so a ^A'd badge snapped back to HEADER's alg (and a
# PEM path in SECRET was cleared on the way).
describe "JWT tab: a HEADER edit that passes through invalid JSON" do
  it "keeps a ^A'd asymmetric badge and its key" do
    with_jwt_controller do |c, _|
      s = loaded_encode(c)
      3.times { c.cycle_alg } # HS256 -> HS384 -> HS512 -> RS256
      s.alg.should eq("RS256")
      s.secret = "./priv.pem"
      good = s.header.text
      s.header.set_text(good.rstrip.chomp("}") + %(, "k)) # the first keystroke of `"kid": "a"`
      c.paste_text(" ")
      s.header.set_text(good.rstrip.chomp("}") + %(, "kid": "a"}))
      c.paste_text(" ")
      s.alg.should eq("RS256")
      s.secret.should eq("./priv.pem") # (no such PEM here, so OUTPUT is the key error)
    end
  end

  it "keeps a ^A'd none, and its warning" do
    with_jwt_controller do |c, _|
      s = loaded_encode(c)
      Gori::Jwt::ALGS.size.times { c.cycle_alg unless s.alg == "none" }
      good = s.header.text
      s.header.set_text(good + "x")
      c.paste_text(" ")
      s.header.set_text(good)
      c.paste_text(" ")
      s.alg.should eq("none")
      output_alg(s).should eq("none")
      s.alg_note.should_not be_nil
    end
  end
end

# A HEADER edit never clears SECRET: an alg across the HMAC/asymmetric boundary is a warning, not
# a badge move. Only ^A (or loading a token) makes that crossing.
describe "JWT tab: a HEADER alg across the key boundary" do
  it "leaves the badge and the key, and says so on OUTPUT" do
    with_jwt_controller do |c, _|
      s = loaded_encode(c)
      s.secret = "hunter2"
      type_header_alg(c, s, %("HS256"), %("RS256"))
      s.alg.should eq("HS256")
      s.secret.should eq("hunter2")
      output_alg(s).should eq("HS256")
      s.alg_note.not_nil!.should contain(%(alg "RS256"))
    end
  end
end
