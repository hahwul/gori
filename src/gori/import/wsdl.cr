require "uri"
require "./builder"
require "./xml_mini"
require "./wsdl_body"

module Gori
  module Import
    # WSDL 1.1 service descriptions → one SOAP request template per callable operation.
    #
    # Like `Oas`/`Postman`/`Insomnia` this describes requests rather than captured traffic,
    # so every operation lands as a response-less template via `Builder.pending_request` and
    # shows as `Pending` in History until it is sent.
    #
    # SCOPE, stated so the bounds are not mistaken for bugs:
    #   * WSDL **1.1** only. A WSDL 2.0 document is refused by name rather than misparsed.
    #   * `soap:` (SOAP 1.1) and `soap12:` (SOAP 1.2) bindings over HTTP. A `http:binding`
    #     (GET/POST) port, or one over JMS/SMTP, is SKIPPED with a note — not counted as
    #     damage, because a .NET WSDL publishing FooHttpGet beside FooSoap is not damaged.
    #   * document/literal and rpc/literal, plus a deliberately partial rpc/encoded (see
    #     `rpc_body`).
    #   * The request body is built from the XSD **inline** in `<wsdl:types>`. An external
    #     `xsd:import`/`include` is NEVER followed — an importer that fetches a
    #     schemaLocation is an importer with file and network I/O, which is precisely the
    #     surface `XmlMini` exists to not have. An unresolvable type degrades to a comment
    #     naming the file that would have defined it, never to a crash or a silent omission.
    #   * Only the INPUT message is generated. The output message describes the response,
    #     which is the origin's to send.
    module Wsdl
      alias QName = XmlMini::QName
      alias Node = XmlMini::Node

      WSDL_NS   = "http://schemas.xmlsoap.org/wsdl/"
      WSDL2_NS  = "http://www.w3.org/ns/wsdl"
      SOAP11_NS = "http://schemas.xmlsoap.org/wsdl/soap/"
      SOAP12_NS = "http://schemas.xmlsoap.org/wsdl/soap12/"
      XSD_NS    = "http://www.w3.org/2001/XMLSchema"
      XSI_NS    = "http://www.w3.org/2001/XMLSchema-instance"
      ENV11_NS  = "http://schemas.xmlsoap.org/soap/envelope/"
      ENV12_NS  = "http://www.w3.org/2003/05/soap-envelope"
      SOAP_ENC  = "http://schemas.xmlsoap.org/soap/encoding/"
      SOAP_HTTP = "http://schemas.xmlsoap.org/soap/http"

      enum Version
        V11
        V12

        def envelope_ns : String
          self == V11 ? ENV11_NS : ENV12_NS
        end

        def binding_ns : String
          self == V11 ? SOAP11_NS : SOAP12_NS
        end
      end

      # A hostile or machine-generated WSDL must not insert 200 000 rows into History. Well
      # above any real service — the largest published enterprise WSDLs run a few hundred
      # operations across a handful of ports.
      MAX_FLOWS = 2_000

      # --- the model -----------------------------------------------------------

      record Part, name : String, element : QName?, type : QName?
      record Message, name : String, parts : Array(Part)
      record Op, name : String, input_name : String?, input : QName?
      record PortType, name : String, ops : Array(Op)
      record HeaderRef, message : QName, part : String

      record BindingOp, name : String, input_name : String?, action : String,
        style : String, use : String, body_ns : String?, parts : Array(String)?,
        headers : Array(HeaderRef)

      # `ops` is an ARRAY, not a name-keyed Hash: WSDL 1.1 permits two `<operation
      # name="Foo">` in one portType distinguished by their `<input name=…>`, and both are
      # genuinely callable. A Hash would silently keep one of them.
      record Binding, name : String, version : Version, port_type : QName,
        ops : Array(BindingOp)

      record Port, service : String, name : String, binding : QName, location : String?

      class Doc
        getter target_ns : String
        getter messages : Hash(QName, Message)
        getter port_types : Hash(QName, PortType)
        # SOAP-over-HTTP bindings only. Everything else lands in `unusable_bindings` with
        # the sentence explaining why, so a port pointing at one can say so.
        getter bindings : Hash(QName, Binding)
        getter unusable_bindings : Hash(QName, String)
        getter ports : Array(Port)
        getter schemas : Schemas

        def initialize(@target_ns : String, @messages : Hash(QName, Message),
                       @port_types : Hash(QName, PortType), @bindings : Hash(QName, Binding),
                       @unusable_bindings : Hash(QName, String), @ports : Array(Port),
                       @schemas : Schemas)
        end
      end

      # --- entry point ---------------------------------------------------------

      def self.parse_file(path : String, prov : Provenance = Provenance.none) : ParseResult
        root = XmlMini.parse(File.read(path))
        check_root!(root, path)
        doc = build(root)
        if doc.ports.empty?
          raise Gori::Error.new(
            "WSDL declares no <wsdl:service> port: an interface-only WSDL publishes no " \
            "endpoint address, so there is nothing to call — #{path}")
        end

        now = Time.utc.to_unix * 1_000_000
        pairs = [] of Builder::FlowPair
        skipped = 0
        notes = [] of String
        seen = Set(String).new

        doc.ports.each do |port|
          loc = port_endpoint(doc, port) { |why| notes << why }
          next unless loc
          binding = doc.bindings[port.binding]?
          unless binding
            notes << %(port #{port.name.inspect} references an undefined binding)
            next
          end
          pt = doc.port_types[binding.port_type]?
          unless pt
            notes << %(binding #{binding.name.inspect} references an undefined portType)
            next
          end

          binding.ops.each do |bop|
            break if pairs.size >= MAX_FLOWS
            # ONE malformed operation — an unresolvable input message, a part declaring
            # neither `element=` nor `type=`, a body that blows the node budget — skips.
            # It must never take the other 39 operations of a working service with it.
            begin
              action, body = render(doc, loc, binding, pt, bop)
              next unless seen.add?(dedupe_key(loc, binding.version, action, body))
              pairs << Builder.pending_request(now, loc, "POST",
                headers_for(binding.version, action), body.to_slice,
                source_surface: prov.surface, source_ref: prov.ref)
            rescue
              skipped += 1
            end
          end
        end

        # Nothing generated: say WHY. `import_file`'s generic "no flows found in …" would
        # hide a WSDL whose only ports are `http:binding`, which is a fact the operator can
        # act on. The notes are the reason they exist.
        if pairs.empty? && skipped == 0 && (why = notes.first?)
          raise Gori::Error.new("no SOAP requests generated from #{path} — #{why}")
        end
        ParseResult.new(pairs, skipped)
      end

      private def self.check_root!(root : Node, path : String) : Nil
        return if root.uri == WSDL_NS && root.local == "definitions"
        if root.uri == WSDL2_NS
          raise Gori::Error.new(
            "#{path} is a WSDL 2.0 document — gori reads WSDL 1.1; re-export the service as WSDL 1.1")
        end
        raise Gori::Error.new(
          "not a WSDL 1.1 document — the root element is <#{root.display_name}>, " \
          "expected <wsdl:definitions>: #{path}")
      end

      # The absolute http(s) endpoint this port publishes, or nil after yielding the sentence
      # saying why it cannot become a request.
      #
      # None of these are `skipped`: an out-of-scope port is not a malformed entry, and
      # counting it would report a perfectly good .NET WSDL's FooHttpGet port as damage. The
      # location comes back rather than being re-read by the caller so there is no second,
      # unchecked read of `port.location` to get wrong.
      private def self.port_endpoint(doc : Doc, port : Port, & : String ->) : String?
        if why = doc.unusable_bindings[port.binding]?
          yield why
          return nil
        end
        loc = port.location
        if loc.nil? || loc.empty?
          yield %(port #{port.name.inspect} declares no <soap:address location="…">)
          return nil
        end
        uri = begin
          URI.parse(loc)
        rescue
          yield %(port #{port.name.inspect} has an unparseable address #{loc.inspect})
          return nil
        end
        scheme = uri.scheme
        if scheme.nil?
          # `Builder.endpoint` only catches the EMPTY-host case, so "./svc" would become
          # host "." and produce silent garbage. Refuse it here, the way `Oas.server_base`
          # refuses a relative `servers[0].url`, and say what to do about it.
          yield %(port #{port.name.inspect} has a relative <soap:address location=#{loc.inspect}> — ) +
                %(a WSDL must publish an absolute endpoint, e.g. "https://host/svc")
          return nil
        end
        unless scheme.downcase.in?("http", "https")
          # Not "missing scheme": `Builder.normalize_url` would say that, and it reads as a
          # parse failure when the real answer is that gori does not speak this transport.
          yield %(port #{port.name.inspect} publishes a #{scheme}: address, which is not a transport gori speaks)
          return nil
        end
        loc
      end

      # The key is the REQUEST, not the WSDL component that produced it. A shape-level rule
      # ("one flow per portType") would collapse a SOAP 1.1 and a SOAP 1.2 port into one and
      # throw away the version difference that is the whole reason to look at a dual-stack
      # endpoint. Two ports that genuinely produce the same bytes collapse; two that do not,
      # do not.
      private def self.dedupe_key(url : String, version : Version, action : String, body : String) : String
        "#{version} #{url} #{action} #{body}"
      end

      # SOAP 1.1 and SOAP 1.2 state the action in DIFFERENT places, and the empty case means
      # different things too.
      #
      # SOAP 1.1 — its own header, ALWAYS present, ALWAYS quoted. A bare `SOAPAction: urn:x`
      #   violates SOAP 1.1 §6.1.1, and stacks route on this header, so dropping the quotes
      #   or the line changes dispatch. An absent/empty `soapAction=` becomes the empty
      #   QUOTED string, which SOAP 1.1 defines as "no intent stated" — omitting the header
      #   entirely is a DIFFERENT statement and .NET/Axis answer it with a 500.
      #
      # SOAP 1.2 — there is NO SOAPAction header. The action is an optional PARAMETER of the
      #   application/soap+xml media type (SOAP 1.2 Part 2 §7.1.3, RFC 3902). Sending a
      #   SOAPAction line beside it is not merely redundant: it is a SOAP 1.1 signal that
      #   some dual-stack endpoints dispatch on, and that misroutes. An empty soapAction
      #   OMITS the parameter rather than writing `action=""`, because an empty parameter is
      #   a positive claim of an empty action URI, which is not what "absent" means.
      private def self.headers_for(version : Version, action : String) : Builder::Headers
        h = Builder::Headers.new
        case version
        in Version::V11
          h << {"Content-Type", "text/xml; charset=utf-8"}
          h << {"SOAPAction", quoted(action)}
        in Version::V12
          ct = "application/soap+xml; charset=utf-8"
          ct += "; action=#{quoted(action)}" unless action.empty?
          h << {"Content-Type", ct}
        end
        h
      end

      # `action` as an RFC 2045 quoted-string. A `soapAction` carrying a `"` — which is an
      # ordinary attribute value in the WSDL, and one `&quot;` decodes to — would otherwise
      # close the string early and hand the endpoint a `SOAPAction` / `Content-Type` it
      # misparses. `Builder.reject_header_injection!` catches the CR/LF/NUL that would forge a
      # message boundary; it has nothing to say about a quote that merely breaks a value.
      private def self.quoted(action : String) : String
        %("#{action.gsub('\\', "\\\\").gsub('"', "\\\"")}")
      end

      # --- the walk ------------------------------------------------------------

      private def self.build(root : Node) : Doc
        tns = root.attr?("targetNamespace") || ""
        unusable = {} of QName => String
        Doc.new(tns, messages_of(root, tns), port_types_of(root, tns),
          bindings_of(root, tns, unusable), unusable, ports_of(root), Schemas.build(root))
      end

      private def self.messages_of(root : Node, tns : String) : Hash(QName, Message)
        messages = {} of QName => Message
        root.elements(WSDL_NS, "message").each do |m|
          name = m.attr?("name")
          next unless name
          parts = m.elements(WSDL_NS, "part").compact_map do |p|
            pname = p.attr?("name")
            pname ? Part.new(pname, p.qname_attr?("element"), p.qname_attr?("type")) : nil
          end
          messages[{tns, name}] = Message.new(name, parts)
        end
        messages
      end

      private def self.port_types_of(root : Node, tns : String) : Hash(QName, PortType)
        port_types = {} of QName => PortType
        root.elements(WSDL_NS, "portType").each do |pt|
          name = pt.attr?("name")
          next unless name
          ops = pt.elements(WSDL_NS, "operation").compact_map do |o|
            oname = o.attr?("name")
            next nil unless oname
            inp = o.element?(WSDL_NS, "input")
            Op.new(oname, inp.try(&.attr?("name")), inp.try(&.qname_attr?("message")))
          end
          port_types[{tns, name}] = PortType.new(name, ops)
        end
        port_types
      end

      # SOAP-over-HTTP bindings, plus a sentence in `unusable` for every one that is not.
      private def self.bindings_of(root : Node, tns : String,
                                   unusable : Hash(QName, String)) : Hash(QName, Binding)
        bindings = {} of QName => Binding
        root.elements(WSDL_NS, "binding").each do |b|
          name = b.attr?("name")
          next unless name
          qn = {tns, name}
          pt_ref = b.qname_attr?("type")
          unless pt_ref
            unusable[qn] = %(binding #{name.inspect} names no portType)
            next
          end
          version, sb = soap_binding(b)
          unless sb
            unusable[qn] = %(binding #{name.inspect} is not a SOAP binding — ) +
                           "WSDL http: (GET/POST) bindings are out of scope"
            next
          end
          transport = sb.attr?("transport")
          # An ABSENT transport is treated as HTTP: the spec requires it, but it is omitted
          # often enough that refusing would throw away working WSDLs.
          if transport && !transport.empty? && transport != SOAP_HTTP
            unusable[qn] = %(binding #{name.inspect} uses the #{transport} transport, which is not HTTP)
            next
          end
          default_style = sb.attr?("style").presence || "document"
          bindings[qn] = Binding.new(name, version, pt_ref,
            binding_ops(b, version.binding_ns, default_style))
        end
        bindings
      end

      # A <wsdl:binding> is SOAP iff it HAS a <soap:binding>/<soap12:binding> child, and WHICH
      # of the two decides the version. The `type=` attribute names a portType and says nothing
      # about the protocol, and the .NET generator everybody's WSDL came out of emits FooSoap,
      # FooSoap12, FooHttpGet and FooHttpPost over the SAME portType — so classification is by
      # the extension element, NEVER by the binding's name. A binding called "FooSoap12"
      # carrying an http:binding exists in the wild and would be misread.
      private def self.soap_binding(b : Node) : {Version, Node?}
        if sb = b.element?(SOAP11_NS, "binding")
          return {Version::V11, sb}
        end
        {Version::V12, b.element?(SOAP12_NS, "binding")}
      end

      private def self.binding_ops(b : Node, soap_ns : String, default_style : String) : Array(BindingOp)
        b.elements(WSDL_NS, "operation").compact_map do |o|
          oname = o.attr?("name")
          next nil unless oname
          so = o.element?(soap_ns, "operation")
          inp = o.element?(WSDL_NS, "input")
          body = inp.try(&.element?(soap_ns, "body"))
          headers = [] of HeaderRef
          if inp
            inp.elements(soap_ns, "header").each do |h|
              msg = h.qname_attr?("message")
              hp = h.attr?("part")
              headers << HeaderRef.new(msg, hp) if msg && hp
            end
          end
          BindingOp.new(oname, inp.try(&.attr?("name")),
            so.try(&.attr?("soapAction")) || "",
            so.try(&.attr?("style")).presence || default_style,
            body.try(&.attr?("use")).presence || "literal",
            body.try(&.attr?("namespace")).presence,
            body.try(&.attr?("parts")).try(&.split),
            headers)
        end
      end

      private def self.ports_of(root : Node) : Array(Port)
        ports = [] of Port
        root.elements(WSDL_NS, "service").each do |svc|
          sname = svc.attr?("name") || ""
          svc.elements(WSDL_NS, "port").each do |p|
            pname = p.attr?("name")
            next unless pname
            bref = p.qname_attr?("binding")
            next unless bref
            loc = p.element?(SOAP11_NS, "address").try(&.attr?("location")) ||
                  p.element?(SOAP12_NS, "address").try(&.attr?("location"))
            ports << Port.new(sname, pname, bref, loc)
          end
        end
        ports
      end

      # --- rendering one operation --------------------------------------------

      # {soapAction, envelope}
      private def self.render(doc : Doc, loc : String, binding : Binding,
                              pt : PortType, bop : BindingOp) : {String, String}
        op = find_op(pt, bop) ||
             raise Gori::Error.new("operation #{bop.name.inspect} is not declared on portType #{pt.name.inspect}")
        msg_qn = op.input ||
                 raise Gori::Error.new("operation #{bop.name.inspect} declares no input message")
        msg = doc.messages[msg_qn]? ||
              raise Gori::Error.new("operation #{bop.name.inspect} names an undefined input message")

        w = Writer.new(doc.schemas)
        parts = select_parts(msg, bop)
        rpc = bop.style == "rpc"
        # SOAP 1.2 dropped §5 encoding, so `use="encoded"` there is a generator artefact:
        # generate the literal form and ignore it rather than emitting an impossible body.
        encoded = bop.use == "encoded" && binding.version == Version::V11

        body = rpc ? rpc_body(doc, w, bop, parts, encoded) : document_body(w, parts)
        header = header_markup(doc, w, bop)
        {bop.action, envelope(binding.version, w, header, body)}
      end

      private def self.find_op(pt : PortType, bop : BindingOp) : Op?
        cands = pt.ops.select { |o| o.name == bop.name }
        return nil if cands.empty?
        # An overloaded name is disambiguated by the binding's `<input name=…>`; when the
        # binding does not state one there is only one operation to mean.
        if iname = bop.input_name
          if match = cands.find { |o| o.input_name == iname }
            return match
          end
        end
        cands.first
      end

      # `soap:body parts="a b"` is a whitespace-separated filter; an absent attribute means
      # every part, which is the common case.
      private def self.select_parts(msg : Message, bop : BindingOp) : Array(Part)
        filter = bop.parts
        return msg.parts unless filter
        msg.parts.select { |p| filter.includes?(p.name) }
      end

      # document/literal: each body child IS the part's global element, rendered from the
      # schema. The operation name appears nowhere in the body — the "wrapped" convention
      # makes the element happen to share it, which is a convention, not a rule.
      private def self.document_body(w : Writer, parts : Array(Part)) : String
        String.build do |io|
          parts.each { |part| io << w.part_markup(part, 2, false) }
        end
      end

      # rpc: ONE wrapper element named by the OPERATION, in the namespace from
      # `<soap:body namespace=…>` (falling back to definitions/@targetNamespace), whose
      # children are one accessor per part.
      #
      # rpc/encoded is generated BEST-EFFORT: the same accessor shape plus
      # `soapenv:encodingStyle` on the wrapper and `xsi:type` on each simple-typed accessor.
      # What is NOT generated is SOAP encoding's multi-reference form (href/id) and its
      # SOAP-Array attributes — a single-reference encoded body is legal SOAP 1.1 §5 and
      # every stack accepts one, so this is a simplification, not a wrong body.
      private def self.rpc_body(doc : Doc, w : Writer, bop : BindingOp,
                                parts : Array(Part), encoded : Bool) : String
        ns = bop.body_ns || doc.target_ns
        tag = ns.empty? ? bop.name : "#{w.prefix_for(ns)}:#{bop.name}"
        inner = String.build do |io|
          parts.each { |part| io << w.part_markup(part, 3, true, encoded) }
        end
        attrs = encoded ? %( soapenv:encodingStyle="#{SOAP_ENC}") : ""
        String.build do |io|
          io << "    <" << tag << attrs << ">\n" << inner << "    </" << tag << ">\n"
        end
      end

      # soap:header parts are almost always the interesting ones — AuthHeader, LicenseHeader,
      # a session token — so they are generated, not dropped. A header naming a message that
      # does not resolve skips THAT HEADER only; the operation still imports.
      private def self.header_markup(doc : Doc, w : Writer, bop : BindingOp) : String
        String.build do |io|
          bop.headers.each do |h|
            msg = doc.messages[h.message]?
            next unless msg
            part = msg.parts.find { |p| p.name == h.part }
            next unless part
            io << w.part_markup(part, 2, false)
          end
        end
      end

      # Every prefix the body allocated is declared on the Envelope — the outermost element,
      # therefore in scope for the Header and the Body alike. Declaring each one on the
      # element that first used it would be shorter and WRONG: a URI first used deep in one
      # subtree and used again in a SIBLING subtree would be out of scope for the sibling.
      # One declaration block on the root makes the scoping unarguable, and is what every
      # SOAP tool's generated request looks like.
      private def self.envelope(version : Version, w : Writer, header : String, body : String) : String
        String.build do |io|
          io << %(<?xml version="1.0" encoding="UTF-8"?>) << '\n'
          io << %(<soapenv:Envelope xmlns:soapenv=") << version.envelope_ns << '"'
          w.declarations.each do |(prefix, uri)|
            io << " xmlns:" << prefix << %(=") << Writer.esc_attr(uri) << '"'
          end
          io << '>' << '\n'
          if header.empty?
            # Emitted even when the binding declares no header parts. It costs 22 bytes, and
            # it is the element an operator adds wsse:Security, a routing header or a
            # mustUnderstand probe to — the difference between an edit and a lookup.
            io << "  <soapenv:Header/>" << '\n'
          else
            io << "  <soapenv:Header>" << '\n' << header << "  </soapenv:Header>" << '\n'
          end
          # <Header> MUST precede <Body>. A generator that appends headers after rendering
          # the body emits an invalid envelope that most stacks still accept, so it is not
          # caught by trying it against one server.
          io << "  <soapenv:Body>" << '\n' << body << "  </soapenv:Body>" << '\n'
          io << "</soapenv:Envelope>" << '\n'
        end
      end
    end
  end
end
