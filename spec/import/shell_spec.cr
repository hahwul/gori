require "../spec_helper"

private def words(text : String) : Array(String)
  cmds = Gori::Import::Shell.commands(text)
  cmds.size.should eq(1)
  cmds.first.words
end

describe Gori::Import::Shell do
  describe ".commands" do
    it "splits on unquoted whitespace and keeps quoted spans whole" do
      words(%q(curl 'a b' "c d" e\ f)).should eq(["curl", "a b", "c d", "e f"])
    end

    it "keeps a single-quoted span byte-for-byte, backslashes and $ included" do
      words(%q(x 'a\nb $HOME "q"')).should eq(["x", %q(a\nb $HOME "q")])
    end

    it "escapes only $ ` \" \\ inside double quotes (POSIX 2.2.3)" do
      words(%q(x "a\$b \"q\" \\ \n")).should eq(["x", %q(a$b "q" \ \n)])
    end

    it "joins adjacent quoted and bare parts into one word" do
      words(%q(x a'b'"c"d)).should eq(["x", "abcd"])
    end

    it "keeps an empty quoted string as an empty word" do
      words(%q(x '' "")).should eq(["x", "", ""])
    end

    it "removes a backslash-newline continuation, LF or CRLF" do
      words("curl 'u' \\\n  -H 'A: 1' \\\r\n  -d x").should eq(["curl", "u", "-H", "A: 1", "-d", "x"])
      words("x \"a\\\nb\"").should eq(["x", "ab"])
    end

    it "decodes $'…' ANSI-C quoting byte-wise, as Chrome's bash copy emits it" do
      words(%q(x $'a\tb\r\n\x41\101é\'\\')).should eq(["x", "a\tb\r\nAAé'\\"])
      words(%q(x $'\xff\xfe'))[1].to_slice.should eq(Bytes[0xff, 0xfe])
    end

    it "ends a $'…' string at a NUL, as bash does (an argument cannot carry one)" do
      words(%q(x $'ab\x00cd'e)).should eq(["x", "abe"])
    end

    it "keeps an unknown ANSI-C escape as written" do
      words(%q(x $'\q')).should eq(["x", %q(\q)])
    end

    it "leaves $VAR literal — gori's own $ENV.KEY token is spelled that way" do
      words(%q(x $ENV.TOKEN "$HOME")).should eq(["x", "$ENV.TOKEN", "$HOME"])
    end

    it "drops a comment that starts a word, but not a # inside one" do
      words("curl 'u' -d a#b # a note\n").should eq(["curl", "u", "-d", "a#b"])
    end

    it "splits commands on ; && || | & and newlines" do
      cmds = Gori::Import::Shell.commands("a 1; b 2 && c 3 || d 4 | e 5 & f\ng")
      cmds.map(&.words.first).should eq(%w[a b c d e f g])
    end

    it "drops a redirection together with its target and an io-number" do
      cmds = Gori::Import::Shell.commands("curl u > out.html 2>/dev/null -s")
      cmds.first.words.should eq(["curl", "u", "-s"])
      cmds.first.redirected.should be_true
    end

    it "refuses an unterminated quote, as Unterminated" do
      expect_raises(Gori::Import::Shell::Unterminated) { Gori::Import::Shell.commands("x 'abc") }
      expect_raises(Gori::Import::Shell::Unterminated) { Gori::Import::Shell.commands(%q(x "abc)) }
      expect_raises(Gori::Import::Shell::Unterminated) { Gori::Import::Shell.commands(%q(x $'abc)) }
    end

    # The shell would have run it and pasted its OUTPUT; keeping the text would store a
    # request the operator's shell never sent.
    it "refuses a command substitution, quoted or not" do
      expect_raises(Gori::Import::Shell::Error, /substitution/) { Gori::Import::Shell.commands("x $(cat t)") }
      expect_raises(Gori::Import::Shell::Error, /substitution/) { Gori::Import::Shell.commands(%q(x "a $(id)")) }
      expect_raises(Gori::Import::Shell::Error, /substitution/) { Gori::Import::Shell.commands("x `id`") }
      words(%q(x '$(id)')).should eq(["x", "$(id)"])
    end
  end

  describe ".incomplete?" do
    it "is true for a trailing continuation or an open quote" do
      Gori::Import::Shell.incomplete?("curl 'u' \\").should be_true
      Gori::Import::Shell.incomplete?("curl 'u").should be_true
      Gori::Import::Shell.incomplete?("curl \"u").should be_true
    end

    it "is false for a complete command, an escaped backslash, or a consumed continuation" do
      Gori::Import::Shell.incomplete?("curl 'u'").should be_false
      Gori::Import::Shell.incomplete?("curl a\\\\").should be_false
      Gori::Import::Shell.incomplete?("curl 'u' \\\n").should be_false
      Gori::Import::Shell.incomplete?("x $(id)").should be_false
    end
  end
end
