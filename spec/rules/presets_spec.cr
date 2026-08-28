require "../spec_helper"

private def with_rules(&)
  path = File.tempname("gori-presets", ".db")
  store = Gori::Store.open(path)
  begin
    yield Gori::Rules.load(store)
  ensure
    store.close
    File.delete?(path)
    File.delete?("#{path}-wal")
    File.delete?("#{path}-shm")
  end
end

private def preset(key : String) : Gori::RulePresets::Preset
  Gori::RulePresets.find(key).not_nil!
end

# Apply a preset to a captured response and return the transformed message. `transform_message`
# is the exact path the proxy takes (head + body), so this exercises the real rewrite, not a
# hand-rolled gsub.
private def apply_preset(key : String, message : String) : String
  with_rules do |rules|
    rules.add_preset(preset(key))
    rules.transform_message(message, Gori::Store::RuleTarget::Response, "acme.test")
  end
end

describe Gori::RulePresets do
  describe "the catalog" do
    it "has unique, non-empty keys" do
      keys = Gori::RulePresets.all.map(&.key)
      keys.each { |k| k.should_not be_empty }
      keys.uniq.size.should eq(keys.size)
    end

    it "installs only Replace and RemoveHeader rules — never a Pipe (would run a command #818)" do
      Gori::RulePresets.all.each do |ps|
        ps.rules.each do |spec|
          spec.op.executes?.should be_false # not a pipe
          {Gori::Store::RuleOp::Replace, Gori::Store::RuleOp::RemoveHeader}.should contain(spec.op)
        end
      end
    end

    it "carries only shapes normalize_shape accepts unchanged" do
      # A spec whose {target, part} differs from what normalize_shape would coerce it to is a
      # rule the proxy would silently reshape — header ops must already be head, body rules body.
      Gori::RulePresets.all.each do |ps|
        ps.rules.each do |spec|
          got = Gori::Rules.normalize_shape(spec.op, spec.target, spec.part)
          got.should eq({spec.target, spec.part})
        end
      end
    end

    it "gives every installed rule a non-empty name so it is findable and deletable" do
      Gori::RulePresets.all.each do |ps|
        ps.rules.each { |spec| spec.name.should_not be_empty }
      end
    end

    it "compiles every regex pattern through SafeRegexp" do
      Gori::RulePresets.all.each do |ps|
        ps.rules.each do |spec|
          next unless spec.match_kind.regex?
          Gori::SafeRegexp.compile(spec.pattern) # raises on a bad pattern
        end
      end
    end
  end

  describe ".find" do
    it "is case-insensitive on the key" do
      Gori::RulePresets.find("REMOVE-CSP").should eq(Gori::RulePresets.find("remove-csp"))
    end

    it "returns nil for an unknown key" do
      Gori::RulePresets.find("nope").should be_nil
    end
  end

  describe "Rules#add_preset" do
    it "installs a preset's rules as ordinary, named, enabled rules" do
      with_rules do |rules|
        n = rules.add_preset(preset("remove-security-headers"))
        n.should eq(3)
        installed = rules.rules
        installed.size.should eq(3)
        installed.all?(&.enabled?).should be_true
        installed.map(&.name).should contain("Remove X-Frame-Options")
      end
    end

    it "can install disabled for review before touching traffic" do
      with_rules do |rules|
        rules.add_preset(preset("remove-csp"), enabled: false)
        rules.rules.none?(&.enabled?).should be_true
        rules.active?.should be_false
      end
    end

    it "duplicates VISIBLY on a second install rather than silently no-op'ing" do
      with_rules do |rules|
        rules.add_preset(preset("disable-sri"))
        rules.add_preset(preset("disable-sri"))
        rules.rules.size.should eq(2) # two rows, both deletable
      end
    end
  end

  describe "live rewrites through the proxy path" do
    it "unhide-hidden-fields makes a hidden input visible" do
      body = %(<form><input type="hidden" name="csrf" value="abc"></form>)
      out = apply_preset("unhide-hidden-fields", "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n#{body}")
      out.should contain(%(type="text"))
      out.should_not contain(%(type="hidden"))
    end

    it "unhide handles single quotes, unquoted and mixed case; leaves lookalikes alone" do
      out = apply_preset("unhide-hidden-fields",
        "HTTP/1.1 200 OK\r\n\r\n<INPUT TYPE=hidden><input type='hidden'><input data-type=\"hidden\" name=\"q\">")
      out.scan(/type\s*=\s*["']?text/i).size.should eq(2) # both real hidden inputs unhidden
      out.should contain(%(data-type="hidden"))           # not a real type attribute — untouched
    end

    it "enable-disabled-fields strips disabled and readonly" do
      out = apply_preset("enable-disabled-fields",
        %(HTTP/1.1 200 OK\r\n\r\n<input disabled><select readonly="readonly"><input data-disabled="1">))
      out.should_not match(/\sdisabled(\b|=)/)
      out.should_not match(/\sreadonly/)
      out.should contain(%(data-disabled="1")) # a different attribute — untouched
    end

    it "remove-length-limits strips maxlength" do
      out = apply_preset("remove-length-limits", %(HTTP/1.1 200 OK\r\n\r\n<input maxlength="4" name=x>))
      out.should_not contain("maxlength")
      out.should contain("name=x")
    end

    it "strip-validation removes required, pattern= and on* handlers" do
      out = apply_preset("strip-validation",
        %(HTTP/1.1 200 OK\r\n\r\n<form onsubmit="return v()"><input required pattern="[0-9]+" oninput='c()'></form>))
      out.should_not contain("required")
      out.should_not contain("pattern=")
      out.should_not contain("onsubmit")
      out.should_not contain("oninput")
    end

    it "disable-sri strips integrity from script/link" do
      out = apply_preset("disable-sri",
        %(HTTP/1.1 200 OK\r\n\r\n<script src="a.js" integrity="sha384-x" crossorigin></script>))
      out.should_not contain("integrity")
      out.should contain("crossorigin")
    end

    it "remove-csp drops BOTH Content-Security-Policy and the -Report-Only variant" do
      msg = "HTTP/1.1 200 OK\r\n" \
            "Content-Security-Policy: default-src 'self'\r\n" \
            "Content-Security-Policy-Report-Only: default-src 'self'\r\n" \
            "Content-Type: text/html\r\n\r\n<html></html>"
      out = apply_preset("remove-csp", msg)
      out.should_not contain("Content-Security-Policy")
      out.should contain("Content-Type: text/html") # other headers survive
    end

    it "remove-security-headers drops the three hardening headers" do
      msg = "HTTP/1.1 200 OK\r\n" \
            "X-Frame-Options: DENY\r\n" \
            "X-Content-Type-Options: nosniff\r\n" \
            "Strict-Transport-Security: max-age=31536000\r\n" \
            "X-Powered-By: gori\r\n\r\nbody"
      out = apply_preset("remove-security-headers", msg)
      out.should_not contain("X-Frame-Options")
      out.should_not contain("X-Content-Type-Options")
      out.should_not contain("Strict-Transport-Security")
      out.should contain("X-Powered-By: gori") # an unrelated header is kept
    end
  end
end
