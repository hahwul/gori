require "../spec_helper"

# src/gori/import/xml_mini.cr — the namespace-aware XML reader `Import::Wsdl` is built on.
# Its own spec rather than riding on wsdl_spec.cr: the three NAME RESOLUTION rules below
# disagree with each other by design, and the DOCTYPE refusal is a security boundary that
# must stay pinned at this seam even if wsdl.cr is rewritten around it.

private alias XmlMini = Gori::Import::XmlMini

private def parse(xml : String) : XmlMini::Node
  XmlMini.parse(xml)
end

describe Gori::Import::XmlMini do
  describe "namespaces" do
    it "inherits the default namespace from an ancestor element" do
      root = parse(%(<definitions xmlns="http://schemas.xmlsoap.org/wsdl/"><service/></definitions>))
      root.uri.should eq("http://schemas.xmlsoap.org/wsdl/")
      root.local.should eq("definitions")
      root.children[0].uri.should eq("http://schemas.xmlsoap.org/wsdl/")
    end

    it "undeclares the default namespace on xmlns=\"\" instead of binding it to an empty URI" do
      # XML Names §6.2. Binding "" => "" would put every unprefixed descendant into a
      # namespace literally called "", which compares equal to nothing real.
      root = parse(%(<a xmlns="urn:x"><b xmlns=""><c/></b></a>))
      root.uri.should eq("urn:x")
      root.children[0].uri.should eq("")
      root.children[0].children[0].uri.should eq("")
    end

    it "rebinds a prefix on an inner element without leaking back out" do
      # The bug this catches: a WSDL carrying two <xsd:schema> sections that bind `tns`
      # differently, where the second subtree's binding leaks onto the first's siblings and
      # every type resolves against the wrong namespace.
      root = parse(<<-XML)
        <root xmlns:s="urn:A">
          <inner xmlns:s="urn:B"><x/></inner>
          <after/>
        </root>
        XML
      root.ns["s"].should eq("urn:A")
      root.element?("", "inner").not_nil!.ns["s"].should eq("urn:B")
      root.element?("", "after").not_nil!.ns["s"].should eq("urn:A")
    end

    it "binds the xml: prefix implicitly" do
      root = parse(%(<a xml:lang="en"/>))
      root.attr?("lang", "http://www.w3.org/XML/1998/namespace").should eq("en")
    end

    it "refuses an undeclared prefix rather than resolving it to no namespace" do
      expect_raises(Gori::Error, /undeclared XML namespace prefix "nope"/) do
        parse(%(<nope:a/>))
      end
    end
  end

  describe "the three name rules" do
    it "puts an unprefixed attribute NAME in no namespace, unlike an element name" do
      # XML Names §6.2, and the rule that decides whether `targetNamespace` is findable
      # inside a schema that declares a default namespace.
      root = parse(%(<schema xmlns="http://www.w3.org/2001/XMLSchema" targetNamespace="urn:t"/>))
      root.uri.should eq("http://www.w3.org/2001/XMLSchema") # element name DID take it
      root.attr?("targetNamespace").should eq("urn:t")       # attribute name did NOT
      root.attr?("targetNamespace", "http://www.w3.org/2001/XMLSchema").should be_nil
    end

    it "resolves a QName in an attribute VALUE, not just in element names" do
      # WSDL's entire cross-reference graph lives in attribute values. A reader that
      # namespaces only elements silently matches `tns:Foo` against `other:Foo`.
      root = parse(%(<a xmlns:tns="urn:t" type="tns:Foo"/>))
      root.qname_attr?("type").should eq({"urn:t", "Foo"})
    end

    it "resolves an unprefixed QName VALUE against the default namespace" do
      # The asymmetry with the attribute-NAME rule above, and how a chameleon schema's
      # `type="string"` means xsd:string.
      root = parse(%(<a xmlns="http://www.w3.org/2001/XMLSchema" type="string"/>))
      root.qname_attr?("type").should eq({"http://www.w3.org/2001/XMLSchema", "string"})
    end

    it "measures the trailing-colon rule in characters, not bytes" do
      # `String#index` answers in CHARS; comparing it against `bytesize` made the rule depend
      # on how wide the name's characters are, so `"a:"` stayed whole while `"ä:"` split into a
      # prefix and raised instead of reaching the caller's error message.
      XmlMini.split_qname("a:").should eq({"", "a:"})
      XmlMini.split_qname("\u{e4}:").should eq({"", "\u{e4}:"})
      XmlMini.split_qname("\u{e4}:x").should eq({"\u{e4}", "x"})
    end

    it "raises on a QName value whose prefix was never declared" do
      root = parse(%(<a type="ghost:Foo"/>))
      expect_raises(Gori::Error, /undeclared XML namespace prefix "ghost"/) { root.qname("ghost:Foo") }
    end
  end

  describe "syntax" do
    it "treats a self-closing element as an empty one" do
      parse(%(<a><x/></a>)).children[0].children.should be_empty
      parse(%(<a><x></x></a>)).children[0].children.should be_empty
      parse(%(<a><soap:address xmlns:soap="urn:s" location="https://h/svc"/></a>))
        .children[0].attr?("location").should eq("https://h/svc")
    end

    it "keeps CDATA content verbatim, markup and all" do
      parse(%(<a><![CDATA[<b>&amp;</b>]]></a>)).text.should eq("<b>&amp;</b>")
    end

    it "decodes the five predefined entities and numeric character references" do
      parse(%(<a>&lt;&gt;&amp;&quot;&apos;</a>)).text.should eq(%(<>&"'))
      parse(%(<a>&#65;&#x41;</a>)).text.should eq("AA")
      parse(%(<a v="&lt;&#65;"/>)).attr?("v").should eq("<A")
    end

    it "leaves an unknown entity verbatim rather than dropping or expanding it" do
      # Pinned because it IS the entity-expansion story: gori resolves five entities and
      # nothing else, so there is no expansion to bound.
      parse(%(<a>&foo;</a>)).text.should eq("&foo;")
    end

    it "drops whitespace-only runs between tags but keeps real text" do
      parse("<a>\n  <b/>\n</a>").text.should eq("")
      parse("<a>  hi  </a>").text.should eq("  hi  ")
    end

    it "skips the XML declaration, comments and a BOM" do
      root = parse(%(\u{feff}<?xml version="1.0" encoding="UTF-8"?><!-- note --><a><!--x--><b/></a>))
      root.local.should eq("a")
      root.children.size.should eq(1)
    end

    it "accepts single-quoted attribute values and refuses unquoted ones" do
      parse(%(<a v='x'/>)).attr?("v").should eq("x")
      expect_raises(Gori::Error, /unquoted attribute value/) { parse(%(<a v=x/>)) }
    end

    it "refuses a duplicate attribute rather than picking one" do
      expect_raises(Gori::Error, /duplicate attribute "location"/) do
        parse(%(<a location="https://one" location="https://two"/>))
      end
    end

    it "refuses an unclosed or mismatched tag rather than guessing" do
      expect_raises(Gori::Error, /mismatched closing tag/) { parse(%(<a><b></a></b>)) }
      expect_raises(Gori::Error, /unclosed element <a>/) { parse(%(<a>)) }
      expect_raises(Gori::Error, /unexpected closing tag/) { parse(%(<a/></b>)) }
    end

    it "refuses a document with no root, two roots, or text outside the root" do
      expect_raises(Gori::Error, /no root element/) { parse(%(<!-- only a comment -->)) }
      expect_raises(Gori::Error, /more than one root element/) { parse(%(<a/><b/>)) }
      expect_raises(Gori::Error, /text outside the root element/) { parse(%(<a/>trailing)) }
    end

    it "matches a closing tag on the resolved name, not the spelling" do
      parse(%(<x:a xmlns:x="urn:t" xmlns:y="urn:t"></y:a>)).uri.should eq("urn:t")
    end

    it "names the line an error is on" do
      expect_raises(Gori::Error, /line 3/) { parse("<a>\n  <b>\n  </c>\n</a>") }
    end
  end

  describe "limits" do
    it "refuses a document larger than the byte cap" do
      small = XmlMini::Limits.new(max_bytes: 32)
      expect_raises(Gori::Error, /too large/) { XmlMini.parse("<a>#{"x" * 100}</a>", small) }
    end

    it "refuses nesting deeper than the depth cap" do
      shallow = XmlMini::Limits.new(max_depth: 4)
      deep = "<a>" * 10 + "</a>" * 10
      expect_raises(Gori::Error, /deeper than 4 levels/) { XmlMini.parse(deep, shallow) }
    end

    it "charges attributes against the node budget, not just elements" do
      tight = XmlMini::Limits.new(max_nodes: 3)
      expect_raises(Gori::Error, /more than 3 nodes/) do
        XmlMini.parse(%(<a p="1" q="2" r="3"/>), tight)
      end
    end
  end

  describe "security" do
    it "refuses a DOCTYPE declaration, internal subset or not" do
      expect_raises(Gori::Error, /DOCTYPE/) { parse(%(<!DOCTYPE a><a/>)) }
      expect_raises(Gori::Error, /DOCTYPE/) do
        parse(%(<!DOCTYPE a [ <!ENTITY x "y"> ]><a>&x;</a>))
      end
    end

    it "refuses an external-entity declaration without reading the file it names" do
      # The refusal happens at the `<!DOCTYPE` token, before any entity is even parsed —
      # so there is no code path that could open the URL.
      err = expect_raises(Gori::Error, /DOCTYPE/) do
        parse(%(<!DOCTYPE r [ <!ENTITY e SYSTEM "file:///etc/passwd"> ]><r>&e;</r>))
      end
      err.message.not_nil!.should_not contain("root:")
    end

    it "cannot expand a billion-laughs payload because no entity can be declared" do
      expect_raises(Gori::Error, /DOCTYPE/) do
        parse(<<-XML)
          <!DOCTYPE lolz [
            <!ENTITY lol "lol">
            <!ENTITY lol2 "&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;">
          ]>
          <lolz>&lol2;</lolz>
          XML
      end
    end

    it "refuses any other markup declaration" do
      expect_raises(Gori::Error, /markup declaration/) { parse(%(<a><!ENTITY x "y"></a>)) }
    end
  end
end
