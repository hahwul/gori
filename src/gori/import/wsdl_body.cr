require "./xml_mini"

module Gori
  module Import
    module Wsdl
      # The XSD declared INLINE in `<wsdl:types>`, indexed by expanded name.
      #
      # Every `<xsd:schema>` under `<wsdl:types>` is MERGED into one index. WSDL 1.1 allows
      # several schemas with different targetNamespaces there, and an `<xsd:import
      # namespace="…"/>` carrying no schemaLocation is exactly how one inline schema
      # references another — so merging resolves that (very common) case with no import
      # following at all.
      class Schemas
        getter elements : Hash(QName, Node)
        # complexType AND simpleType share ONE table because they share one symbol space in
        # XSD (§3.4.1: a complexType and a simpleType cannot share a name in one target
        # namespace), so a second table would only ever add a miss to handle.
        getter types : Hash(QName, Node)
        # targetNamespaces whose schema says `elementFormDefault="qualified"`. Per-schema in
        # XSD; indexed per-namespace here, which differs only for two inline schemas sharing
        # a targetNamespace and disagreeing — a shape no generator produces.
        getter qualified : Set(String)
        # namespace => the schemaLocation gori did NOT follow. Read only to make an
        # unresolvable type's comment say which file would have defined it.
        getter unresolved : Hash(String, String)

        def initialize(@elements : Hash(QName, Node), @types : Hash(QName, Node),
                       @qualified : Set(String), @unresolved : Hash(String, String))
        end

        def self.build(root : Node) : Schemas
          elements = {} of QName => Node
          types = {} of QName => Node
          qualified = Set(String).new
          unresolved = {} of String => String
          present = Set(String).new

          schemas = [] of Node
          root.elements(WSDL_NS, "types").each do |t|
            t.elements(XSD_NS, "schema").each { |s| schemas << s }
          end

          schemas.each do |s|
            tns = s.attr?("targetNamespace") || ""
            present << tns
            qualified << tns if s.attr?("elementFormDefault") == "qualified"
            s.elements(XSD_NS, "element").each do |e|
              if name = e.attr?("name")
                elements[{tns, name}] = e
              end
            end
            {"complexType", "simpleType"}.each do |kind|
              s.elements(XSD_NS, kind).each do |t|
                if name = t.attr?("name")
                  types[{tns, name}] = t
                end
              end
            end
          end

          # External schema following is OUT OF SCOPE: an importer that fetches a
          # schemaLocation is an importer with file and network I/O, which is the XXE
          # surface `XmlMini` was written to not have — and a relative schemaLocation beside
          # the .wsdl is only sometimes on disk anyway.
          #
          # Recorded ONLY when the import carries a schemaLocation AND its namespace has no
          # inline schema: a schemaLocation-less import between two inline schemas resolves
          # normally above and must not be reported as missing.
          schemas.each do |s|
            {"import", "include"}.each do |kind|
              s.elements(XSD_NS, kind).each do |imp|
                loc = imp.attr?("schemaLocation")
                next if loc.nil? || loc.empty?
                ns = imp.attr?("namespace") || s.attr?("targetNamespace") || ""
                next if present.includes?(ns)
                unresolved[ns] = loc
              end
            end
          end

          new(elements, types, qualified, unresolved)
        end
      end

      # Turns a message part into SOAP body markup, allocating namespace prefixes as it goes.
      #
      # One Writer per generated request: the prefix table it fills is what `Wsdl.envelope`
      # declares on the Envelope element, so a Writer shared between two requests would
      # declare prefixes one of them never uses.
      class Writer
        # Two independent guards, because they stop different shapes, plus a width backstop.
        #
        #   XSD_MAX_DEPTH  bounds a deep-but-finite tree. A schema 30 wrapper types deep is
        #                  legal and useless as a seed request.
        #   the path stack bounds a CYCLE (see `content_of`). The depth cap alone would let
        #                  a self-referencing type expand to 2^12 elements before stopping.
        #   MAX_BODY_NODES bounds WIDTH — a choice of 400 branches under a sequence of 40 is
        #                  neither deep nor cyclic and would still produce an unreadable
        #                  body. Blowing it raises, so the operation is skipped and COUNTED
        #                  rather than silently truncated; 2 000 elements in one SOAP body is
        #                  already past the point of being editable in the Repeater.
        XSD_MAX_DEPTH  =    12
        MAX_BODY_NODES = 2_000

        # `maxOccurs` is honoured as "once" or "more than once", never literally: a declared
        # maxOccurs="9999" means 2 accessors, not 9999. The operator needs to SEE that the
        # accessor repeats — array handling is where the bugs are — and then set the count by
        # hand; a body that is megabytes of identical stubs cannot be read at all.
        REPEAT = 2

        PARTICLES = {"element", "sequence", "choice", "all", "any", "group"}

        # Every value is VALID for its type on purpose. A gateway that XSD-validates before
        # dispatch has to let the seed request through to the business logic, or the import
        # bought nothing — which rules out SoapUI's `?` convention, invalid for every
        # numeric, boolean and date type in the language.
        BUILTIN = {
          "string"             => "string",
          "normalizedString"   => "string",
          "token"              => "string",
          "language"           => "en",
          "Name"               => "name",
          "NCName"             => "name",
          "NMTOKEN"            => "token",
          "ID"                 => "id1",
          "IDREF"              => "id1",
          "QName"              => "string",
          "anyURI"             => "http://example.com/",
          "anyType"            => "string",
          "anySimpleType"      => "string",
          "boolean"            => "true",
          "byte"               => "1",
          "short"              => "1",
          "int"                => "1",
          "long"               => "1",
          "integer"            => "1",
          "unsignedByte"       => "1",
          "unsignedShort"      => "1",
          "unsignedInt"        => "1",
          "unsignedLong"       => "1",
          "positiveInteger"    => "1",
          "nonNegativeInteger" => "1",
          # The sign-constrained pair needs its OWN value: "1" fails validation for both,
          # which is exactly the class of failure this table exists to avoid.
          "negativeInteger"    => "-1",
          "nonPositiveInteger" => "0",
          "decimal"            => "1.0",
          "float"              => "1.0",
          "double"             => "1.0",
          "duration"           => "P1D",
          "dateTime"           => "2024-01-01T00:00:00Z",
          "date"               => "2024-01-01",
          "time"               => "00:00:00Z",
          "gYear"              => "2024",
          "gYearMonth"         => "2024-01",
          "gMonth"             => "--01",
          "gMonthDay"          => "--01-01",
          "gDay"               => "---01",
          "base64Binary"       => "Z29yaQ==",
          "hexBinary"          => "676f7269",
        }

        # An element's markup and, separately, the attributes that ride on its own tag.
        # `text` and `children` are alternatives: simple content sets the first, a particle
        # walk sets the second, and an empty element sets neither.
        record Content, text : String? = nil, children : String = "", attrs : String = ""

        getter declarations : Array({String, String})

        def initialize(@schemas : Schemas)
          @prefixes = {} of String => String
          @used = Set(String).new(["soapenv"])
          @declarations = [] of {String, String}
          @budget = MAX_BODY_NODES
        end

        def prefix_for(uri : String, hint : String? = nil) : String
          if existing = @prefixes[uri]?
            return existing
          end
          prefix = hint
          if prefix.nil? || @used.includes?(prefix)
            n = @prefixes.size + 1
            while @used.includes?("ns#{n}")
              n += 1
            end
            prefix = "ns#{n}"
          end
          @used << prefix
          @prefixes[uri] = prefix
          @declarations << {prefix, uri}
          prefix
        end

        # One message part as body markup at `depth`.
        #
        # `rpc` names the accessor after the PART and leaves it UNQUALIFIED — rpc accessors
        # are never namespace-qualified, whatever `elementFormDefault` says, and routing them
        # through the document-path qualification logic is the easiest way to get this wrong.
        # `xsi_type` is the rpc/encoded extra.
        def part_markup(part : Part, depth : Int32, rpc : Bool, xsi_type : Bool = false) : String
          el = part.element
          ty = part.type
          # WS-I BP R2204 says document/literal parts use `element=` and rpc parts use
          # `type=`, and BOTH violations ship in the wild — so neither is a skip. Declaring
          # NEITHER (or both) is genuinely malformed, and raising here is what the caller's
          # per-operation rescue turns into one `skipped`.
          if el && ty
            raise Gori::Error.new("message part #{part.name.inspect} declares both element= and type=")
          end
          if el
            decl = @schemas.elements[el]?
            unless decl
              return comment_line(depth, "unresolved element #{qn_s(el)}#{hint_for(el[0])}")
            end
            return global_element(decl, el[0], depth, [] of QName, 1)
          end
          unless ty
            raise Gori::Error.new("message part #{part.name.inspect} declares neither element= nor type=")
          end
          content = content_of(ty, lookup(ty), ty[0], depth + 1, 1, [] of QName)
          extra = ""
          if xsi_type && ty[0] == XSD_NS
            extra = %( #{prefix_for(XSI_NS, "xsi")}:type="#{prefix_for(XSD_NS, "xsd")}:#{ty[1]}")
          end
          render(part.name, content, depth, 1, extra)
        end

        # --- element declarations ------------------------------------------------

        private def global_element(decl : Node, ns : String, depth : Int32,
                                   path : Array(QName), reps : Int32) : String
          name = decl.attr?("name")
          return comment_line(depth, "global element declaration with no name") unless name
          content = decl_content(decl, ns, depth + 1, 1, path)
          # A GLOBAL element is qualified by its own schema's targetNamespace, always —
          # elementFormDefault governs LOCAL names only.
          tag = ns.empty? ? name : "#{prefix_for(ns)}:#{name}"
          render(tag, content, depth, reps)
        end

        private def element_markup(decl : Node, owner_ns : String, depth : Int32,
                                   level : Int32, path : Array(QName)) : String
          if ref = decl.qname_attr?("ref")
            target = @schemas.elements[ref]?
            unless target
              return comment_line(depth, "unresolved element reference #{qn_s(ref)}#{hint_for(ref[0])}")
            end
            # The referenced global element brings its own name, namespace and qualification;
            # only the occurrence count comes from the reference.
            return global_element(target, ref[0], depth, path, occurs(decl))
          end
          name = decl.attr?("name")
          return "" unless name
          content = decl_content(decl, owner_ns, depth + 1, level + 1, path)
          # `elementFormDefault="qualified"` (per schema, overridden by `form=` on one
          # element) decides whether LOCAL names are namespace-qualified. The default is
          # UNQUALIFIED; .NET emits qualified and Axis often does not, so it cannot be
          # guessed — and a qualified name gets an explicit prefix rather than a default
          # `xmlns=` on the wrapper, which would silently pull every unqualified CHILD into
          # the same namespace and produce a body that looks right and validates wrong.
          tag = qualified?(decl, owner_ns) && !owner_ns.empty? ? "#{prefix_for(owner_ns)}:#{name}" : name
          render(tag, content, depth, occurs(decl))
        end

        # An inline anonymous type when the declaration has one, else its named `type=`,
        # else xsd:anyType.
        private def decl_content(decl : Node, owner_ns : String, depth : Int32,
                                 level : Int32, path : Array(QName)) : Content
          inline = decl.element?(XSD_NS, "complexType") || decl.element?(XSD_NS, "simpleType")
          return content_of(nil, inline, owner_ns, depth, level, path) if inline
          ty = decl.qname_attr?("type")
          return Content.new(text: "string") unless ty
          content_of(ty, lookup(ty), ty[0], depth, level, path)
        end

        # --- types ---------------------------------------------------------------

        private def content_of(type_qn : QName?, type_node : Node?, owner_ns : String,
                               depth : Int32, level : Int32, path : Array(QName)) : Content
          if type_qn && type_qn[0] == XSD_NS
            return Content.new(text: builtin_text(type_qn[1]))
          end
          if type_qn && type_node.nil?
            # An unresolvable type renders as a COMMENT naming it and the schemaLocation
            # that would have defined it, so the operator can see WHICH file to paste in —
            # never as a silent omission, which would present an incomplete body as complete.
            return Content.new(children: comment_line(depth, "unresolved type #{qn_s(type_qn)}#{hint_for(type_qn[0])}"))
          end
          return Content.new(text: "string") unless type_node
          if type_qn
            if path.includes?(type_qn)
              return Content.new(children: comment_line(depth, "recursive type #{qn_s(type_qn)} — expand by hand"))
            end
            path = path + [type_qn]
          end
          if level > XSD_MAX_DEPTH
            return Content.new(children: comment_line(depth, "nesting past #{XSD_MAX_DEPTH} levels — expand by hand"))
          end
          case type_node.local
          when "simpleType"  then simple_content(type_node, owner_ns, depth, level, path)
          when "complexType" then complex_content(type_node, owner_ns, depth, level, path)
          else                    Content.new(text: "string")
          end
        end

        private def simple_content(node : Node, owner_ns : String, depth : Int32,
                                   level : Int32, path : Array(QName)) : Content
          if r = node.element?(XSD_NS, "restriction")
            # An enumeration wins over the base type's placeholder. A value outside the
            # enumeration is the single most common cause of a schema-validating gateway
            # rejecting a seed request before it reaches any business logic.
            if e = r.element?(XSD_NS, "enumeration")
              return Content.new(text: e.attr?("value") || "string")
            end
            if base = r.qname_attr?("base")
              return content_of(base, lookup(base), base[0], depth, level + 1, path)
            end
            if inner = r.element?(XSD_NS, "simpleType")
              return content_of(nil, inner, owner_ns, depth, level + 1, path)
            end
          end
          if l = node.element?(XSD_NS, "list")
            if item = l.qname_attr?("itemType")
              return content_of(item, lookup(item), item[0], depth, level + 1, path)
            end
          end
          if u = node.element?(XSD_NS, "union")
            if mt = u.attr?("memberTypes")
              if first = mt.split.first?
                qn = u.qname(first)
                return content_of(qn, lookup(qn), qn[0], depth, level + 1, path)
              end
            end
            if inner = u.element?(XSD_NS, "simpleType")
              return content_of(nil, inner, owner_ns, depth, level + 1, path)
            end
          end
          Content.new(text: "string")
        end

        private def complex_content(node : Node, owner_ns : String, depth : Int32,
                                    level : Int32, path : Array(QName)) : Content
          # simpleContent: the base's placeholder becomes the element's TEXT and the
          # extension's attributes ride on the same tag — `<amount currency="USD">1.0</amount>`
          # is this branch.
          if sc = node.element?(XSD_NS, "simpleContent")
            if ext = sc.element?(XSD_NS, "extension") || sc.element?(XSD_NS, "restriction")
              base = ext.qname_attr?("base")
              text = base ? (content_of(base, lookup(base), base[0], depth, level + 1, path).text || "string") : "string"
              return Content.new(text: text, attrs: attrs_of(ext))
            end
          end
          if cc = node.element?(XSD_NS, "complexContent")
            if ext = cc.element?(XSD_NS, "extension") || cc.element?(XSD_NS, "restriction")
              children = ""
              attrs = ""
              if base = ext.qname_attr?("base")
                # XSD extension APPENDS, so the BASE's particles go FIRST. Order is not
                # cosmetic: a server unmarshalling by position rejects the reversed body.
                bc = content_of(base, lookup(base), base[0], depth, level + 1, path)
                children += bc.children
                attrs += bc.attrs
              end
              children += particles_of(ext.children, owner_ns, depth, level, path)
              attrs += attrs_of(ext)
              return Content.new(children: children, attrs: attrs)
            end
          end
          Content.new(children: particles_of(node.children, owner_ns, depth, level, path),
            attrs: attrs_of(node))
        end

        private def particles_of(nodes : Array(Node), owner_ns : String, depth : Int32,
                                 level : Int32, path : Array(QName)) : String
          String.build do |io|
            nodes.each do |c|
              next unless c.uri == XSD_NS
              case c.local
              when "sequence", "all"
                io << particles_of(c.children, owner_ns, depth, level, path)
              when "choice"
                # The FIRST branch only, and with no explanatory comment: the body has to
                # stay a sendable document, and a "you could also send B" note would be
                # noise on every later send. The alternatives are one lookup away in the
                # WSDL the operator just imported.
                first = c.children.find { |g| g.uri == XSD_NS && PARTICLES.includes?(g.local) }
                if first
                  io << particles_of([first], owner_ns, depth, level, path)
                end
              when "element"
                io << element_markup(c, owner_ns, depth, level, path)
              when "any"
                io << comment_line(depth, "<xsd:any> — insert the element the service expects")
              when "group"
                io << comment_line(depth, "<xsd:group> reference — expand by hand")
              end
            end
          end
        end

        # `use="required"`, or an attribute the schema states a `fixed`/`default` for — in
        # which case the value is the schema's, not one gori invented. An OPTIONAL attribute
        # with no stated value is skipped: unlike an element it is trivially typed by hand
        # onto a tag the operator is already looking at, and SOAP bodies carry few of them.
        #
        # Always written unqualified. `attributeFormDefault` defaults to unqualified and a
        # qualified attribute in a SOAP body is vanishingly rare.
        private def attrs_of(container : Node) : String
          String.build do |io|
            container.elements(XSD_NS, "attribute").each do |a|
              name = a.attr?("name")
              next unless name
              stated = a.attr?("fixed") || a.attr?("default")
              next unless stated || a.attr?("use") == "required"
              io << ' ' << name << %(=") << Writer.esc_attr(stated || attr_placeholder(a)) << '"'
            end
          end
        end

        private def attr_placeholder(a : Node) : String
          ty = a.qname_attr?("type")
          return builtin_text(ty[1]) if ty && ty[0] == XSD_NS
          "string"
        end

        # --- emitting ------------------------------------------------------------

        private def render(tag : String, content : Content, depth : Int32,
                           reps : Int32, extra : String = "") : String
          pad = "  " * depth
          String.build do |io|
            reps.times do
              charge
              io << pad << '<' << tag << content.attrs << extra
              if t = content.text
                io << '>' << Writer.esc_text(t) << "</" << tag << '>' << '\n'
              elsif content.children.empty?
                io << "/>" << '\n'
              else
                io << '>' << '\n' << content.children << pad << "</" << tag << '>' << '\n'
              end
            end
          end
        end

        private def comment_line(depth : Int32, message : String) : String
          "#{"  " * depth}<!-- #{message.gsub("--", "- -")} -->\n"
        end

        private def charge : Nil
          @budget -= 1
          if @budget < 0
            raise Gori::Error.new(
              "the SOAP body would exceed #{MAX_BODY_NODES} elements — this schema is too " \
              "wide to seed automatically")
          end
        end

        # --- small helpers -------------------------------------------------------

        # A builtin never resolves through the type table; everything else does.
        private def lookup(qn : QName) : Node?
          return nil if qn[0] == XSD_NS
          @schemas.types[qn]?
        end

        private def builtin_text(local : String) : String
          BUILTIN[local]? || "string"
        end

        private def occurs(decl : Node) : Int32
          mo = decl.attr?("maxOccurs")
          return 1 unless mo
          return REPEAT if mo == "unbounded"
          (mo.to_i? || 1) > 1 ? REPEAT : 1
        end

        # `minOccurs="0"` still emits, deliberately: deleting an element you can see is
        # trivial, while inventing one the skeleton hid means going back to the WSDL. A seed
        # request is for maximum reachable surface, so optional means present. `nillable`
        # renders normally too — a body pre-filled with `xsi:nil` reaches no business logic
        # at all, which is the opposite of the point.
        private def qualified?(decl : Node, owner_ns : String) : Bool
          if form = decl.attr?("form")
            return form == "qualified"
          end
          @schemas.qualified.includes?(owner_ns)
        end

        private def qn_s(qn : QName) : String
          qn[0].empty? ? qn[1] : "{#{qn[0]}}#{qn[1]}"
        end

        private def hint_for(ns : String) : String
          loc = @schemas.unresolved[ns]?
          loc ? " (declared in #{loc}, which gori does not fetch)" : ""
        end

        def self.esc_text(s : String) : String
          s.gsub('&', "&amp;").gsub('<', "&lt;")
        end

        def self.esc_attr(s : String) : String
          esc_text(s).gsub('"', "&quot;")
        end
      end
    end
  end
end
