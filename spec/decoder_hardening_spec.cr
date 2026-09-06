require "./spec_helper"
require "file_utils"

# Defects a review of the Decoder engine, its codecs and the chain library found. Each
# example here failed against the code it was written for.

private REG = Gori::Decoder.default_registry

private def run(input : Bytes | String, chain : String, reg = REG) : Gori::Decoder::ChainResult
  Gori::Decoder.run(reg, input.is_a?(String) ? input.to_slice : input, chain)
end

private def text_out(input : String, chain : String) : String
  String.new(run(input, chain).output.not_nil!)
end

# Load `doc` as the settings file of a throwaway GORI_HOME, restoring the process-wide
# Settings afterwards (the same shape spec/settings_spec.cr's fixtures take).
private def with_settings_file(doc : String, &)
  dir = File.tempname("gori-decoder-settings")
  Dir.mkdir_p(dir)
  prev_home = ENV["GORI_HOME"]?
  prev_chains = Gori::Settings.decoder_chains
  prev_theme = Gori::Settings.theme
  begin
    ENV["GORI_HOME"] = dir
    Gori::Settings.warning_io = nil
    Gori::Settings.reset_load_warning_guard
    File.write(Gori::Settings.path, doc)
    Gori::Settings.load
    yield
  ensure
    File.write(Gori::Settings.path, %({"theme":"goridark"}))
    Gori::Settings.load
    Gori::Settings.decoder_chains = prev_chains
    prev_home ? (ENV["GORI_HOME"] = prev_home) : ENV.delete("GORI_HOME")
    FileUtils.rm_rf(dir)
    Gori::Settings.theme = prev_theme
    Gori::Settings.bind_port = 8070
  end
end

# The degraded-settings fixture spec/settings_spec.cr uses: valid JSON that is not an
# object latches the partial-read flag, so every later `Settings.save` refuses.
private def with_refused_save(&)
  with_settings_file(%([{"theme":"dracula"}])) do
    Gori::Settings.save.should be_false
    yield
  end
end

describe "Decoder engine hardening" do
  describe "a non-UTF-8 spec" do
    # PCRE2 refuses an invalid-UTF-8 subject with a raw ArgumentError, and both the token
    # split and the key fold were regexes over the raw string — so `Decoder.run` raised out
    # of a "never raises" contract, and `Library.register_all` raised inside `Settings.load`,
    # whose blanket rescue factory-reset every section after `decoder` over one bad chain.
    it "runs to an unknown converter instead of raising" do
      res = run("x", "\xff > upper")
      res.ok?.should be_false
      res.steps.first.state.unknown?.should be_true
      Gori::Decoder.parse_spec("\xff|upper").size.should eq 2
    end

    it "resolves nothing through the registry rather than raising" do
      REG["\xff"]?.should be_nil
      Gori::Decoder::Registry.normalize("\xff").should_not be_empty
      Gori::Decoder.chain_runs_commands?(REG, "\xff > exec:x").should be_true
    end

    it "is tolerated by the chain library without raising" do
      r = Gori::Decoder.build_registry([{"bad", "\xff > upper"}, {"\xff", "upper"}, {"good", "upper"}])
      String.new(run("a", "good", r).output.not_nil!).should eq "A"
    end
  end

  describe "Library.name_error" do
    it "names the three shapes no chain token could ever spell" do
      Gori::Decoder::Library.name_error("  ").not_nil!.should contain("required")
      Gori::Decoder::Library.name_error("a>b").not_nil!.should contain("can't contain")
      Gori::Decoder::Library.name_error("exec:mytool").not_nil!.should contain("exec:")
      Gori::Decoder::Library.name_error("Exec: tool").not_nil!.should contain("exec:") # the marker is case-insensitive
      Gori::Decoder::Library.name_error("peel").should be_nil
    end

    # `Decoder.run` tests the exec marker BEFORE the registry, so a chain saved under
    # `exec:mytool` was never reached — the token spawned argv `mytool` instead.
    it "keeps an exec:-named entry out of the registry" do
      r = Gori::Decoder.build_registry([{"exec:mytool", "upper"}, {"a>b", "upper"}, {"ok", "upper"}])
      r["exec:mytool"]?.should be_nil
      r["a>b"]?.should be_nil
      r.names.should contain("ok")
    end

    # The settings parse KEEPS such an entry (dropping it would erase it from disk at the next
    # save); it is the registrar that refuses to make it a step.
    it "leaves an imported name the tab refuses in the library but out of the registry" do
      with_settings_file(%({"decoder":{"chains":[
          {"name":"a>b","spec":"upper"},{"name":"exec:x","spec":"upper"},{"name":"fine","spec":"upper"}]}})) do
        Gori::Settings.decoder_chains.map(&.[0]).should eq ["a>b", "exec:x", "fine"]
        Gori::Decoder.shared_registry["fine"]?.should_not be_nil
        Gori::Decoder.shared_registry["exec:x"]?.should be_nil
        Gori::Decoder.shared_registry["a>b"]?.should be_nil
      end
    end
  end

  describe "the library follows the disk" do
    # `delete_decoder_chain` republished the engine's library before `save`, so a refused
    # write left the picker without the row and the name unresolvable — until the next start
    # brought the entry back.
    it "puts a deleted chain back when the write is refused" do
      with_refused_save do
        Gori::Settings.decoder_chains = [{"keep", "upper"}]
        Gori::Settings.delete_decoder_chain("keep").should be_false
        Gori::Settings.decoder_chains.map(&.[0]).should eq ["keep"]
        String.new(run("a", "keep", Gori::Decoder.shared_registry).output.not_nil!).should eq "A"
      end
    end
  end

  describe "codecs" do
    it "powershell-escape doubles the Unicode single quotes PowerShell also treats as delimiters" do
      text_out("a’b‘c‚d‛e'f", "powershell-escape").should eq "'a’’b‘‘c‚‚d‛‛e''f'"
    end

    it "base36-decode folds only ASCII case, so a Kelvin sign is not a digit" do
      res = run("Kİ", "base36-decode")
      res.ok?.should be_false
      res.steps.first.error.not_nil!.should contain("invalid base36 char")
      text_out("AB", "base36-decode").should eq text_out("ab", "base36-decode")
    end

    it "xml-unescape leaves a numeric reference with a sign or a space literal" do
      text_out("&#x+41;&# 65;&#65 ;&#+65;&#x;", "xml-unescape").should eq "&#x+41;&# 65;&#65 ;&#+65;&#x;"
      text_out("&#65;&#x41;&#X41;", "xml-unescape").should eq "AAA"
    end

    it "refuses an empty gzip stream like its zlib and raw siblings" do
      %w[gunzip inflate raw-inflate].each do |conv|
        res = run("", conv)
        res.ok?.should be_false
        res.steps.first.error.not_nil!.should contain("empty input")
      end
    end

    # The cut-stream tolerance kept whatever a reader produced before it raised — a CRC-32
    # mismatch included, so a damaged body read as a clean decode.
    it "fails a gzip / zlib stream whose checksum does not match, rather than calling it Ok" do
      body = (1..600).map(&.to_s).join(" ").to_slice # compressible, but not to nothing
      gz = Gori::Decoder::Codecs.gzip_compress(body).dup
      gz[gz.size - 5] ^= 0xff # inside the CRC-32 trailer
      res = run(gz, "gunzip")
      res.ok?.should be_false
      res.steps.first.error.not_nil!.should contain("corrupt")

      z = Gori::Decoder::Codecs.zlib_compress(body).dup
      z[z.size - 1] ^= 0xff # the Adler-32 trailer
      run(z, "inflate").ok?.should be_false

      isize = Gori::Decoder::Codecs.gzip_compress(body).dup
      isize[isize.size - 1] ^= 0xff # the ISIZE field, checked after the CRC passes
      run(isize, "gunzip").ok?.should be_false

      # A stream merely CUT short still keeps its readable head.
      whole = Gori::Decoder::Codecs.gzip_compress(body)
      run(whole[0, whole.size // 2], "gunzip").ok?.should be_true
    end
  end
end
