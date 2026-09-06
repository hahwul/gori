require "../spec_helper"

# src/gori/import/wsdl.cr — WSDL 1.1 (SOAP 1.1 + 1.2) → response-less SOAP request templates.
# Inline temp files rather than fixtures, matching spec/import/postman_spec.cr.

private def with_wsdl(xml : String, &)
  path = File.tempname("gori", ".wsdl")
  File.write(path, xml)
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

private def parse(xml : String) : Gori::Import::ParseResult
  with_wsdl(xml) { |path| Gori::Import::Wsdl.parse_file(path) }
end

private def body_of(result : Gori::Import::ParseResult, i = 0) : String
  String.new(result.flows[i].request.body.not_nil!)
end

private def head_of(result : Gori::Import::ParseResult, i = 0) : String
  String.new(result.flows[i].request.head)
end

# A document/literal WSDL with every section replaceable, so an example shows only the part
# it is about — a full WSDL runs ~50 lines and repeating it a dozen times buries the
# assertion under boilerplate.
private def wsdl(types = %(<s:element name="Add"><s:complexType><s:sequence>) +
                   %(<s:element name="a" type="s:int"/></s:sequence></s:complexType></s:element>),
                 messages = %(<wsdl:message name="AddIn"><wsdl:part name="parameters" element="tns:Add"/></wsdl:message>),
                 port_type = %(<wsdl:portType name="PT"><wsdl:operation name="Add">) +
                   %(<wsdl:input message="tns:AddIn"/></wsdl:operation></wsdl:portType>),
                 bindings = %(<wsdl:binding name="B" type="tns:PT"><soap:binding style="document") +
                   %( transport="http://schemas.xmlsoap.org/soap/http"/><wsdl:operation name="Add">) +
                   %(<soap:operation soapAction="urn:Add"/><wsdl:input><soap:body use="literal"/>) +
                   %(</wsdl:input></wsdl:operation></wsdl:binding>),
                 ports = %(<wsdl:port name="P" binding="tns:B">) +
                   %(<soap:address location="https://svc.test/endpoint"/></wsdl:port>),
                 schema_attrs = %(elementFormDefault="qualified" targetNamespace="urn:t")) : String
  <<-XML
    <?xml version="1.0" encoding="utf-8"?>
    <wsdl:definitions xmlns:wsdl="http://schemas.xmlsoap.org/wsdl/"
                      xmlns:soap="http://schemas.xmlsoap.org/wsdl/soap/"
                      xmlns:soap12="http://schemas.xmlsoap.org/wsdl/soap12/"
                      xmlns:http="http://schemas.xmlsoap.org/wsdl/http/"
                      xmlns:s="http://www.w3.org/2001/XMLSchema"
                      xmlns:tns="urn:t" targetNamespace="urn:t">
      <wsdl:types><s:schema #{schema_attrs}>#{types}</s:schema></wsdl:types>
      #{messages}
      #{port_type}
      #{bindings}
      <wsdl:service name="Svc">#{ports}</wsdl:service>
    </wsdl:definitions>
    XML
end

describe Gori::Import::Wsdl do
  it "builds one request template per operation of a document/literal service" do
    result = parse(wsdl(
      types: %(<s:element name="Add"><s:complexType><s:sequence><s:element name="a" type="s:int"/>) +
             %(</s:sequence></s:complexType></s:element>) +
             %(<s:element name="Sub"><s:complexType><s:sequence><s:element name="b" type="s:string"/>) +
             %(</s:sequence></s:complexType></s:element>),
      messages: %(<wsdl:message name="AddIn"><wsdl:part name="p" element="tns:Add"/></wsdl:message>) +
                %(<wsdl:message name="SubIn"><wsdl:part name="p" element="tns:Sub"/></wsdl:message>),
      port_type: %(<wsdl:portType name="PT">) +
                 %(<wsdl:operation name="Add"><wsdl:input message="tns:AddIn"/></wsdl:operation>) +
                 %(<wsdl:operation name="Sub"><wsdl:input message="tns:SubIn"/></wsdl:operation></wsdl:portType>),
      bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                %(<soap:binding style="document" transport="http://schemas.xmlsoap.org/soap/http"/>) +
                %(<wsdl:operation name="Add"><soap:operation soapAction="urn:Add"/>) +
                %(<wsdl:input><soap:body use="literal"/></wsdl:input></wsdl:operation>) +
                %(<wsdl:operation name="Sub"><soap:operation soapAction="urn:Sub"/>) +
                %(<wsdl:input><soap:body use="literal"/></wsdl:input></wsdl:operation></wsdl:binding>)))

    result.flows.size.should eq(2)
    result.skipped.should eq(0)
    req = result.flows[0].request
    req.method.should eq("POST")
    req.host.should eq("svc.test")
    req.target.should eq("/endpoint")
    result.flows[0].response.should be_nil # a template, never a fabricated response

    head = head_of(result)
    head.should contain("Content-Type: text/xml; charset=utf-8")
    # ALWAYS quoted: a bare `SOAPAction: urn:Add` violates SOAP 1.1 §6.1.1 and stacks route
    # on this header, so the quotes decide dispatch.
    head.should contain(%(SOAPAction: "urn:Add"))

    body = body_of(result)
    body.should contain(%(<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"))
    body.should contain("<soapenv:Body>")
    body.should contain(":Add>")
    body.should contain(">1</") # xsd:int placeholder
    head_of(result, 1).should contain(%(SOAPAction: "urn:Sub"))
  end

  it "writes an empty soapAction as the empty QUOTED string, not as an absent header" do
    # SOAP 1.1 defines `SOAPAction: ""` as "no intent stated". Omitting the line entirely is
    # a DIFFERENT statement, and .NET/Axis answer that with a 500.
    result = parse(wsdl(bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                                  %(<soap:binding transport="http://schemas.xmlsoap.org/soap/http"/>) +
                                  %(<wsdl:operation name="Add"><soap:operation soapAction=""/>) +
                                  %(<wsdl:input><soap:body use="literal"/></wsdl:input>) +
                                  %(</wsdl:operation></wsdl:binding>)))
    head_of(result).should contain(%(SOAPAction: ""))
  end

  it "escapes a quote in soapAction rather than closing the quoted-string early" do
    # `&quot;` in the WSDL decodes to a real quote, which would otherwise end the SOAPAction
    # value (and, on SOAP 1.2, the `action=` media-type parameter) where the endpoint parses it.
    result = parse(wsdl(bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                                  %(<soap:binding transport="http://schemas.xmlsoap.org/soap/http"/>) +
                                  %(<wsdl:operation name="Add"><soap:operation soapAction="a&quot;b"/>) +
                                  %(<wsdl:input><soap:body use="literal"/></wsdl:input>) +
                                  %(</wsdl:operation></wsdl:binding>)))
    head_of(result).should contain(%(SOAPAction: "a\\"b"))
  end

  it "builds an rpc/literal body from the message parts, in declaration order" do
    # The one structural difference from document/literal, and where a doc-only reader emits
    # a silently wrong envelope: ONE wrapper named by the OPERATION, whose children are one
    # accessor per part — always UNQUALIFIED, whatever elementFormDefault says.
    result = parse(wsdl(
      types: "",
      messages: %(<wsdl:message name="AddIn"><wsdl:part name="alpha" type="s:int"/>) +
                %(<wsdl:part name="beta" type="s:string"/></wsdl:message>),
      bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                %(<soap:binding style="rpc" transport="http://schemas.xmlsoap.org/soap/http"/>) +
                %(<wsdl:operation name="Add"><soap:operation soapAction="urn:Add"/>) +
                %(<wsdl:input><soap:body use="literal" namespace="urn:svc"/></wsdl:input>) +
                %(</wsdl:operation></wsdl:binding>)))
    body = body_of(result)
    body.should contain(%(xmlns:ns1="urn:svc"))
    body.should contain("<ns1:Add>")
    body.should contain("<alpha>1</alpha>")
    body.should contain("<beta>string</beta>")
    body.index("<alpha>").not_nil!.should be < body.index("<beta>").not_nil!
  end

  it "adds encodingStyle and xsi:type for an rpc/encoded operation instead of skipping it" do
    # rpc/encoded is legacy .NET/Axis, i.e. exactly the target a security tool exists to
    # reach. Best-effort single-reference form, not the multi-reference href/id encoding.
    result = parse(wsdl(
      types: "",
      messages: %(<wsdl:message name="AddIn"><wsdl:part name="alpha" type="s:int"/></wsdl:message>),
      bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                %(<soap:binding style="rpc" transport="http://schemas.xmlsoap.org/soap/http"/>) +
                %(<wsdl:operation name="Add"><soap:operation soapAction="urn:Add"/>) +
                %(<wsdl:input><soap:body use="encoded" namespace="urn:svc"/></wsdl:input>) +
                %(</wsdl:operation></wsdl:binding>)))
    body = body_of(result)
    body.should contain(%(soapenv:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"))
    body.should contain(%(<alpha xsi:type="xsd:int">1</alpha>))
  end

  it "uses the SOAP 1.2 envelope and media-type action for a soap12 binding" do
    result = parse(wsdl(bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                                  %(<soap12:binding transport="http://schemas.xmlsoap.org/soap/http"/>) +
                                  %(<wsdl:operation name="Add"><soap12:operation soapAction="urn:Add"/>) +
                                  %(<wsdl:input><soap12:body use="literal"/></wsdl:input>) +
                                  %(</wsdl:operation></wsdl:binding>),
      ports: %(<wsdl:port name="P" binding="tns:B">) +
             %(<soap12:address location="https://svc.test/endpoint"/></wsdl:port>)))
    head = head_of(result)
    head.should contain(%(Content-Type: application/soap+xml; charset=utf-8; action="urn:Add"))
    # There is NO SOAPAction header in SOAP 1.2, and sending one beside the parameter is a
    # SOAP 1.1 signal some dual-stack endpoints dispatch on — which misroutes.
    head.should_not contain("SOAPAction")
    body_of(result).should contain(%(xmlns:soapenv="http://www.w3.org/2003/05/soap-envelope"))
  end

  it "omits the SOAP 1.2 action parameter entirely when no soapAction is declared" do
    # An empty parameter is a positive claim of an empty action URI, which is not what
    # "absent" means.
    result = parse(wsdl(bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                                  %(<soap12:binding transport="http://schemas.xmlsoap.org/soap/http"/>) +
                                  %(<wsdl:operation name="Add"><soap12:operation/>) +
                                  %(<wsdl:input><soap12:body use="literal"/></wsdl:input>) +
                                  %(</wsdl:operation></wsdl:binding>),
      ports: %(<wsdl:port name="P" binding="tns:B">) +
             %(<soap12:address location="https://svc.test/endpoint"/></wsdl:port>)))
    head_of(result).should contain("Content-Type: application/soap+xml; charset=utf-8\r\n")
    head_of(result).should_not contain("action=")
  end

  it "imports each SOAP port and skips a non-SOAP one without counting it as damage" do
    # The canonical .NET shape: FooSoap / FooSoap12 / FooHttpGet over ONE portType. The HTTP
    # port is out of scope, but it is not malformed, so it must not inflate `skipped`.
    result = parse(wsdl(
      bindings: %(<wsdl:binding name="B11" type="tns:PT">) +
                %(<soap:binding transport="http://schemas.xmlsoap.org/soap/http"/>) +
                %(<wsdl:operation name="Add"><soap:operation soapAction="urn:Add"/>) +
                %(<wsdl:input><soap:body use="literal"/></wsdl:input></wsdl:operation></wsdl:binding>) +
                %(<wsdl:binding name="B12" type="tns:PT">) +
                %(<soap12:binding transport="http://schemas.xmlsoap.org/soap/http"/>) +
                %(<wsdl:operation name="Add"><soap12:operation soapAction="urn:Add"/>) +
                %(<wsdl:input><soap12:body use="literal"/></wsdl:input></wsdl:operation></wsdl:binding>) +
                %(<wsdl:binding name="BGet" type="tns:PT"><http:binding verb="GET"/></wsdl:binding>),
      ports: %(<wsdl:port name="P11" binding="tns:B11">) +
             %(<soap:address location="https://svc.test/basic"/></wsdl:port>) +
             %(<wsdl:port name="P12" binding="tns:B12">) +
             %(<soap12:address location="https://svc.test/secure"/></wsdl:port>) +
             %(<wsdl:port name="PGet" binding="tns:BGet">) +
             %(<http:address location="https://svc.test/get"/></wsdl:port>)))
    result.flows.size.should eq(2)
    result.skipped.should eq(0)
    result.flows.map(&.request.target).should eq(["/basic", "/secure"])
  end

  it "skips a port bound over a non-HTTP transport" do
    parse(wsdl(bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                         %(<soap:binding transport="http://schemas.xmlsoap.org/soap/jms"/>) +
                         %(<wsdl:operation name="Add"><soap:operation soapAction="urn:Add"/>) +
                         %(<wsdl:input><soap:body use="literal"/></wsdl:input>) +
                         %(</wsdl:operation></wsdl:binding>)))
    fail "expected a clean error"
  rescue ex : Gori::Error
    ex.message.not_nil!.should contain("not HTTP")
  end

  it "collapses two ports that produce byte-identical requests, but not two SOAP versions" do
    # The dedupe key is the REQUEST. An alias port at the same address collapses; a SOAP 1.1
    # and a SOAP 1.2 port at the same address do NOT, because a dual-stack endpoint where
    # one version bypasses a filter written for the other is the finding.
    result = parse(wsdl(
      bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                %(<soap:binding transport="http://schemas.xmlsoap.org/soap/http"/>) +
                %(<wsdl:operation name="Add"><soap:operation soapAction="urn:Add"/>) +
                %(<wsdl:input><soap:body use="literal"/></wsdl:input></wsdl:operation></wsdl:binding>),
      ports: %(<wsdl:port name="P" binding="tns:B">) +
             %(<soap:address location="https://svc.test/endpoint"/></wsdl:port>) +
             %(<wsdl:port name="Alias" binding="tns:B">) +
             %(<soap:address location="https://svc.test/endpoint"/></wsdl:port>)))
    result.flows.size.should eq(1)
  end

  describe "the XSD skeleton" do
    it "builds a nested complexType into typed placeholders" do
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add"><s:complexType><s:sequence>
          <s:element name="note" type="tns:Note"/>
        </s:sequence></s:complexType></s:element>
        <s:complexType name="Note">
          <s:sequence>
            <s:element name="body" type="s:string"/>
            <s:element name="when" type="s:dateTime"/>
            <s:element name="ok" type="s:boolean"/>
          </s:sequence>
          <s:attribute name="id" type="s:int" use="required"/>
        </s:complexType>
        XSD
      body = body_of(result)
      body.should contain(%(<ns1:note id="1">))
      body.should contain("<ns1:body>string</ns1:body>")
      body.should contain("<ns1:when>2024-01-01T00:00:00Z</ns1:when>")
      body.should contain("<ns1:ok>true</ns1:ok>")
    end

    it "leaves a local name unqualified when the schema does not say elementFormDefault" do
      # Unqualified is the XSD default; .NET emits qualified and Axis often does not, so it
      # cannot be guessed. A default `xmlns=` on the wrapper would be shorter and would pull
      # every unqualified child into the wrong namespace.
      result = parse(wsdl(schema_attrs: %(targetNamespace="urn:t"),
        types: %(<s:element name="Add"><s:complexType><s:sequence>) +
               %(<s:element name="a" type="s:int"/></s:sequence></s:complexType></s:element>)))
      body = body_of(result)
      body.should contain("<ns1:Add>") # a GLOBAL element is qualified regardless
      body.should contain("<a>1</a>")  # the LOCAL one is not
      body.should_not contain(%(<soapenv:Body>\n    <ns1:Add xmlns=))
    end

    it "prefers the first enumeration value over the base type's placeholder" do
      # A value outside the enumeration is the commonest reason a schema-validating gateway
      # rejects a seed request before it reaches any business logic.
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add"><s:complexType><s:sequence>
          <s:element name="kind" type="tns:Kind"/>
        </s:sequence></s:complexType></s:element>
        <s:simpleType name="Kind"><s:restriction base="s:string">
          <s:enumeration value="memo"/><s:enumeration value="alert"/>
        </s:restriction></s:simpleType>
        XSD
      body_of(result).should contain("<ns1:kind>memo</ns1:kind>")
    end

    it "emits a repeating accessor twice, never maxOccurs times" do
      result = parse(wsdl(types: %(<s:element name="Add"><s:complexType><s:sequence>) +
                                 %(<s:element name="tag" maxOccurs="9999" type="s:string"/>) +
                                 %(</s:sequence></s:complexType></s:element>)))
      body_of(result).scan(/<ns1:tag>/).size.should eq(2)
    end

    it "emits an optional element rather than hiding it" do
      # Deleting an element you can see is trivial; inventing one the skeleton hid means
      # going back to the WSDL.
      result = parse(wsdl(types: %(<s:element name="Add"><s:complexType><s:sequence>) +
                                 %(<s:element name="maybe" minOccurs="0" type="s:string"/>) +
                                 %(</s:sequence></s:complexType></s:element>)))
      body_of(result).should contain("<ns1:maybe>string</ns1:maybe>")
    end

    it "renders only the first branch of a choice" do
      result = parse(wsdl(types: %(<s:element name="Add"><s:complexType><s:choice>) +
                                 %(<s:element name="byId" type="s:int"/>) +
                                 %(<s:element name="byName" type="s:string"/>) +
                                 %(</s:choice></s:complexType></s:element>)))
      body = body_of(result)
      body.should contain("<ns1:byId>1</ns1:byId>")
      body.should_not contain("byName")
    end

    it "puts the base type's particles before the extension's" do
      # XSD extension APPENDS. A server unmarshalling by position rejects the reversed body,
      # so the order is not cosmetic.
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add" type="tns:Derived"/>
        <s:complexType name="Base"><s:sequence>
          <s:element name="first" type="s:string"/>
        </s:sequence></s:complexType>
        <s:complexType name="Derived"><s:complexContent><s:extension base="tns:Base">
          <s:sequence><s:element name="second" type="s:string"/></s:sequence>
        </s:extension></s:complexContent></s:complexType>
        XSD
      body = body_of(result)
      body.index("<ns1:first>").not_nil!.should be < body.index("<ns1:second>").not_nil!
    end

    it "turns simpleContent into text plus the extension's attributes" do
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add"><s:complexType><s:sequence>
          <s:element name="amount" type="tns:Money"/>
        </s:sequence></s:complexType></s:element>
        <s:complexType name="Money"><s:simpleContent><s:extension base="s:decimal">
          <s:attribute name="currency" type="s:string" fixed="USD"/>
        </s:extension></s:simpleContent></s:complexType>
        XSD
      body_of(result).should contain(%(<ns1:amount currency="USD">1.0</ns1:amount>))
    end

    it "stops a recursive type at the first repetition instead of recursing forever" do
      # A CYCLE, which the depth cap alone would let expand to 2^XSD_MAX_DEPTH elements
      # before stopping. The flow is still produced — the comment is inside the element, not
      # instead of it, so the generator never presents a partial body as complete.
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add" type="tns:Node"/>
        <s:complexType name="Node"><s:sequence>
          <s:element name="child" type="tns:Node"/>
        </s:sequence></s:complexType>
        XSD
      result.flows.size.should eq(1)
      result.skipped.should eq(0)
      body = body_of(result)
      body.scan(/<ns1:child>/).size.should eq(1)
      body.should contain("recursive type {urn:t}Node")
    end

    it "stops an element `ref` cycle instead of recursing until the process dies" do
      # A SECOND way to recurse forever, which neither of the type guards saw: an element
      # carrying an INLINE anonymous complexType names no type, so nothing reached the cycle
      # trail, and the depth counter used to restart at 1 on every hop through a `ref`. The
      # result was a stack overflow — a signal, not an exception, so the per-operation rescue
      # could not turn it into a `skipped`; it took the whole CLI/TUI/MCP process down.
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add"><s:complexType><s:sequence>
          <s:element ref="tns:Add"/>
        </s:sequence></s:complexType></s:element>
        XSD
      result.flows.size.should eq(1)
      result.skipped.should eq(0)
      body_of(result).should contain("recursive element {urn:t}Add")
    end

    it "charges a repeated subtree so the node budget bounds the EMITTED body" do
      # `render` writes the subtree string `reps` times but builds it once, so a
      # charge-on-construction budget grew linearly while the emitted count grew as the
      # PRODUCT of the reps. Nested `maxOccurs="unbounded"` levels built a multi-gigabyte body
      # and still reported `skipped: 0`. Now the copies are charged, so the operation is
      # skipped and COUNTED rather than eating the machine.
      levels = 20
      types = String.build do |io|
        io << %(<s:element name="Add" type="tns:T0"/>)
        levels.times do |i|
          io << %(<s:complexType name="T#{i}"><s:sequence>)
          io << %(<s:element name="e#{i}" maxOccurs="unbounded" type="tns:T#{i + 1}"/>)
          io << %(</s:sequence></s:complexType>)
        end
        io << %(<s:complexType name="T#{levels}"><s:sequence>) +
              %(<s:element name="leaf" type="s:string"/></s:sequence></s:complexType>)
      end
      result = parse(wsdl(types: types))
      result.flows.should be_empty
      result.skipped.should eq(1)
    end

    it "replaces the base content model on a complexContent restriction, never appends to it" do
      # Extension APPENDS and restriction REPLACES; sharing one branch both duplicated the
      # particles a restriction kept and re-added the ones it removed, so a schema-validating
      # gateway rejected the body before it reached any business logic.
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add" type="tns:Derived"/>
        <s:complexType name="Base"><s:sequence>
          <s:element name="a" type="s:string"/>
          <s:element name="b" type="s:string"/>
        </s:sequence></s:complexType>
        <s:complexType name="Derived"><s:complexContent><s:restriction base="tns:Base">
          <s:sequence><s:element name="a" type="s:string"/></s:sequence>
        </s:restriction></s:complexContent></s:complexType>
        XSD
      body = body_of(result)
      body.scan(/<ns1:a>/).size.should eq(1)
      body.should_not contain("<ns1:b>")
    end

    it "keeps the base type's required attributes through a simpleContent extension" do
      result = parse(wsdl(types: <<-XSD))
        <s:element name="Add"><s:complexType><s:sequence>
          <s:element name="amount" type="tns:Money"/>
        </s:sequence></s:complexType></s:element>
        <s:complexType name="Base"><s:simpleContent><s:extension base="s:decimal">
          <s:attribute name="scale" type="s:int" use="required"/>
        </s:extension></s:simpleContent></s:complexType>
        <s:complexType name="Money"><s:simpleContent><s:extension base="tns:Base">
          <s:attribute name="currency" type="s:string" fixed="USD"/>
        </s:extension></s:simpleContent></s:complexType>
        XSD
      body_of(result).should contain(%(<ns1:amount scale="1" currency="USD">1.0</ns1:amount>))
    end

    it "comments an unresolvable type and names the schema it did not fetch" do
      result = parse(wsdl(types: <<-XSD))
        <s:import namespace="urn:other" schemaLocation="other.xsd"/>
        <s:element name="Add"><s:complexType><s:sequence>
          <s:element xmlns:o="urn:other" name="far" type="o:Thing"/>
        </s:sequence></s:complexType></s:element>
        XSD
      body = body_of(result)
      body.should contain("unresolved type {urn:other}Thing")
      body.should contain("other.xsd")
    end
  end

  describe "the skip / raise contract" do
    it "skips one malformed operation instead of discarding the service" do
      result = parse(wsdl(
        types: "",
        messages: %(<wsdl:message name="AddIn"><wsdl:part name="a" type="s:int"/></wsdl:message>) +
                  %(<wsdl:message name="BadIn"><wsdl:part name="oops"/></wsdl:message>),
        port_type: %(<wsdl:portType name="PT">) +
                   %(<wsdl:operation name="Add"><wsdl:input message="tns:AddIn"/></wsdl:operation>) +
                   %(<wsdl:operation name="Bad"><wsdl:input message="tns:BadIn"/></wsdl:operation>) +
                   %(<wsdl:operation name="Gone"><wsdl:input message="tns:Missing"/></wsdl:operation>) +
                   %(</wsdl:portType>),
        bindings: %(<wsdl:binding name="B" type="tns:PT">) +
                  %(<soap:binding style="rpc" transport="http://schemas.xmlsoap.org/soap/http"/>) +
                  %(<wsdl:operation name="Add"><soap:operation soapAction="urn:Add"/>) +
                  %(<wsdl:input><soap:body use="literal" namespace="urn:s"/></wsdl:input></wsdl:operation>) +
                  %(<wsdl:operation name="Bad"><soap:operation soapAction="urn:Bad"/>) +
                  %(<wsdl:input><soap:body use="literal" namespace="urn:s"/></wsdl:input></wsdl:operation>) +
                  %(<wsdl:operation name="Gone"><soap:operation soapAction="urn:Gone"/>) +
                  %(<wsdl:input><soap:body use="literal" namespace="urn:s"/></wsdl:input></wsdl:operation>) +
                  %(</wsdl:binding>)))
      result.flows.size.should eq(1)
      result.skipped.should eq(2)
    end

    it "raises a clean error on a relative soap:address and names the port" do
      # `Builder.endpoint` only catches the EMPTY-host case, so "./svc" would be stored with
      # host "." — a flow that can never be sent, imported as a success.
      parse(wsdl(ports: %(<wsdl:port name="Rel" binding="tns:B">) +
                        %(<soap:address location="/services/Calc"/></wsdl:port>)))
      fail "expected a clean error"
    rescue ex : Gori::Error
      msg = ex.message.not_nil!
      msg.should contain("absolute")
      msg.should contain(%("Rel")) # WHICH port, so the operator can go and look
    end

    it "raises on a port whose address is not an HTTP transport" do
      parse(wsdl(ports: %(<wsdl:port name="Q" binding="tns:B">) +
                        %(<soap:address location="jms://queue/Calc"/></wsdl:port>)))
      fail "expected a clean error"
    rescue ex : Gori::Error
      ex.message.not_nil!.should contain("not a transport gori speaks")
    end

    it "raises a clean error on a non-WSDL file, a WSDL 2.0 file, and a portless one" do
      expect_raises(Gori::Error, /not a WSDL 1.1 document/) do
        parse(%(<html><body>not a service description</body></html>))
      end
      expect_raises(Gori::Error, /WSDL 2.0/) do
        parse(%(<description xmlns="http://www.w3.org/ns/wsdl"/>))
      end
      expect_raises(Gori::Error, /no <wsdl:service> port/) do
        parse(wsdl(ports: ""))
      end
    end
  end

  describe "security" do
    it "refuses a DOCTYPE without reading the entity it names" do
      # `Import::Burp`'s fixtures deliberately CARRY a benign DOCTYPE, because Burp writes
      # one and those bytes are the operator's evidence. A WSDL is a document DESCRIBING
      # requests, not the operator's wire bytes, so it gets the stricter rule — see the
      # DOCTYPE note in xml_mini.cr.
      err = expect_raises(Gori::Error, /DOCTYPE/) do
        parse(%(<!DOCTYPE d [ <!ENTITY e SYSTEM "file:///etc/passwd"> ]>) + wsdl)
      end
      err.message.not_nil!.should_not contain("root:")

      expect_raises(Gori::Error, /DOCTYPE/) do
        parse(%(<!DOCTYPE d [ <!ENTITY a "aa"> <!ENTITY b "&a;&a;&a;&a;"> ]>) + wsdl)
      end
    end

    it "does not read an imported schema off the filesystem" do
      # The same stance `Import::Postman` takes on a `file`-mode body: an importer reads the
      # file it was handed and nothing else.
      result = parse(wsdl(types: %(<s:import namespace="urn:secret" schemaLocation="file:///etc/passwd"/>) +
                                 %(<s:element name="Add"><s:complexType><s:sequence>) +
                                 %(<s:element name="a" type="s:int"/></s:sequence></s:complexType></s:element>)))
      body_of(result).should_not contain("root:")
      body_of(result).should contain("<ns1:a>1</ns1:a>")
    end
  end

  it "imports end to end through Import.import_file" do
    with_wsdl(wsdl) do |path|
      with_store do |store|
        result = Gori::Import.import_file(store, :wsdl, path)
        result.count.should eq(1)
        row = store.search(Gori::QL::EMPTY, 10).first
        row.host.should eq("svc.test")
        row.method.should eq("POST")
        row.target.should eq("/endpoint")
        row.status.should be_nil # a template, never a fabricated response
        body = String.new(store.get_flow(row.id).not_nil!.request_body.not_nil!)
        body.should contain(":Add>")
      end
    end
  end
end
