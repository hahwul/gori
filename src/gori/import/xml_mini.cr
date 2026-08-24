require "./xml_text"

module Gori
  module Import
    # A small, namespace-aware XML tree reader — enough of XML 1.0 + XML Names to read a
    # WSDL and the XML Schema inside it, and deliberately no more.
    #
    # WHY NOT `require "xml"`. libxml2 is not linked into gori, and linking it would mean
    # adding `libxml2-dev` + `libxml2-static` (and its transitive static deps) to every
    # packaging path that builds `--static` — docker/Dockerfile, the release workflow,
    # flake.nix, Homebrew, AUR, snap. `import/burp.cr` states the same reasoning for its
    # flat scanner; this is that decision applied to a document that actually needs a tree.
    #
    # WHY NOT `Import::Burp`'s scanner. That one matches `<name` by string index over a
    # machine-generated, flat, prefix-free export. A WSDL breaks all three assumptions: the
    # same element arrives as `<wsdl:portType>`, `<portType>` or `<w:portType>` depending on
    # the generator; every cross-reference is a QName carried in an ATTRIBUTE VALUE
    # (`type="tns:Foo"`) resolved against prefixes bound arbitrarily far up the tree; and
    # `<xsd:sequence>` nests recursively. Prefix-blind matching silently mis-resolves.
    #
    # WHAT IT IS NOT. No DTD, no external entities, no XInclude, no namespace fixup, no
    # schema validation, no round-trip serialization. It reads a document into nodes.
    module XmlMini
      # {namespace uri, local name}. `Import::Wsdl` reuses this alias for its own tables.
      alias QName = {String, String}

      # prefix ("" = the default namespace) => namespace URI.
      alias NsMap = Hash(String, String)

      # `xml:` is bound implicitly and may not be rebound (XML Names §3). Every other
      # prefix, `xmlns:` included, has to be declared before it can be used.
      ROOT_NS = {"xml" => "http://www.w3.org/XML/1998/namespace"} of String => String

      # A resolved attribute. `uri` is "" for the ordinary unprefixed case — see `Node#attr?`
      # for why that is the RULE and not a fallback.
      record Attr, uri : String, local : String, value : String

      # A parsed element.
      #
      # A class rather than a record: children are appended during the parse and the same
      # node is referenced from several of `Import::Wsdl`'s index tables, so a struct would
      # copy on every assignment. There is deliberately no `parent` link — every walk in
      # this importer runs downward, and a back-reference buys nothing but a cycle.
      class Node
        getter uri : String
        getter local : String
        # Kept for ERROR MESSAGES only ("expected </soap:address>"), so a message names the
        # element the way the file spells it. Never match on this: the prefix is arbitrary
        # and `uri` is the identity.
        getter prefix : String
        getter attrs : Array(Attr)
        getter children : Array(Node)
        # The prefixes in scope AT THIS ELEMENT. Carried per node so `qname` resolves an
        # attribute VALUE in O(1) with no parent walk — see `Parser#child_ns` for why this
        # is one shared Hash for almost every node rather than one per node.
        getter ns : NsMap

        def initialize(@uri : String, @local : String, @prefix : String,
                       @attrs : Array(Attr), @ns : NsMap)
          @children = [] of Node
          @runs = nil.as(Array(String)?)
          @text = nil.as(String?)
        end

        # Character data directly inside this element. Whitespace-only runs BETWEEN tags are
        # dropped (a WSDL is mostly those, and no caller wants them); CDATA is always kept
        # verbatim, whitespace included.
        #
        # Joined ON READ and memoized. The runs were concatenated on ARRIVAL (`@text = t + s`),
        # which copies everything already there once per run: anything that splits character
        # data — a comment, a CDATA section, an entity — makes another run, so `x<!---->`
        # repeated is one run per 8 bytes and the copying is quadratic in the file. A 2 MB
        # document took 4.5 s and the 8 MiB ceiling ~70 s, on a path that runs on the TUI's own
        # fiber with nothing to yield to (P6): one import stalled the proxy with it.
        def text : String
          runs = @runs
          return "" unless runs
          @text ||= runs.join
        end

        # :nodoc:
        def add_text(s : String) : Nil
          (@runs ||= [] of String) << s
          @text = nil
        end

        def name : QName
          {@uri, @local}
        end

        def display_name : String
          @prefix.empty? ? @local : "#{@prefix}:#{@local}"
        end

        # An unprefixed ATTRIBUTE NAME is in NO namespace (XML Names §6.2) — it does NOT
        # take the default namespace the way an element name does. That is why `uri`
        # defaults to "" here: inside `<xsd:schema xmlns="…/XMLSchema">`, the attributes
        # `targetNamespace`, `name`, `type` and `elementFormDefault` are all in no
        # namespace, and looking them up under the schema namespace finds nothing.
        def attr?(local : String, uri : String = "") : String?
          @attrs.each { |a| return a.value if a.local == local && a.uri == uri }
          nil
        end

        # Direct children with this expanded name.
        def elements(uri : String, local : String) : Array(Node)
          @children.select { |c| c.uri == uri && c.local == local }
        end

        def element?(uri : String, local : String) : Node?
          @children.find { |c| c.uri == uri && c.local == local }
        end

        def elements(name : QName) : Array(Node)
          elements(name[0], name[1])
        end

        def element?(name : QName) : Node?
          element?(name[0], name[1])
        end

        # Resolve a QName carried as an attribute VALUE (`type="tns:Foo"`, `binding="tns:B"`,
        # `base="xsd:string"`). This is the THIRD name rule and it agrees with neither of the
        # other two: an unprefixed QName VALUE *does* take the default namespace — that is
        # exactly how a chameleon schema written as
        # `<schema xmlns="http://www.w3.org/2001/XMLSchema"> … type="string"` means
        # `xsd:string`. Do not fold this together with `attr?`'s rule; the divergence is the
        # point.
        #
        # An undeclared prefix raises rather than resolving to "": binding `tns:Foo` to no
        # namespace produces a lookup miss three layers later and an unexplained empty body.
        def qname(value : String) : QName
          prefix, local = XmlMini.split_qname(value)
          if prefix.empty?
            return {@ns[""]? || "", local}
          end
          uri = @ns[prefix]? ||
                raise Gori::Error.new("undeclared XML namespace prefix #{prefix.inspect} in #{value.inspect}")
          {uri, local}
        end

        def qname_attr?(local : String, uri : String = "") : QName?
          attr?(local, uri).try { |v| qname(v) }
        end
      end

      # Structural ceilings. Each stops a DIFFERENT shape, so none of them subsumes another.
      #
      #   max_bytes — checked BEFORE parsing. Nothing downstream is size-aware, so a 200 MB
      #               "WSDL" would build 200 MB of Nodes before any other guard fired.
      #               8 MiB is well above a large enterprise WSDL with inline XSD (1–2 MB).
      #               `Saml::MAX_XML` is the same shape of ceiling for the same reason.
      #   max_depth — `<a><a><a>…` costs one frame per level in the WSDL walk and again in
      #               the body generator. 256 is ~10x the deepest real schema.
      #   max_nodes — the backstop for a file legitimately under max_bytes but pathological
      #               (millions of `<a/>`), and the ONLY guard bounding attribute count and
      #               TEXT-RUN count, since both are charged against the same budget as
      #               elements. Text runs are charged because nothing else counts them: a
      #               comment is skipped without a charge, so `x<!---->` repeated is a run
      #               every 8 bytes and a million of them fit under max_bytes.
      record Limits,
        max_bytes : Int32 = 8 * 1024 * 1024,
        max_nodes : Int32 = 200_000,
        max_depth : Int32 = 256 do
        def self.default : Limits
          new
        end
      end

      def self.parse(src : String, limits : Limits = Limits.default) : Node
        if src.bytesize > limits.max_bytes
          raise Gori::Error.new(
            "XML document is too large (#{src.bytesize} bytes; the limit is #{limits.max_bytes})")
        end
        # SCRUBBED, and this is the deliberate divergence from `Import::Burp`, which must
        # NOT scrub because its bytes ARE the wire message it stores. A WSDL is a text
        # DOCUMENT whose only output is names, URLs and placeholder text, so a byte that
        # cannot be text has no meaning in it — and scrubbing once here makes every String
        # materialized below safe to hand to `URI.parse` and to PCRE2.
        text = src.valid_encoding? ? src : src.scrub
        Parser.new(text, limits).run
      end

      # {prefix, local} for a QName. No colon means no prefix; a leading or trailing colon
      # is not a prefix either, and is left as part of the name for the caller's error
      # message rather than silently producing an empty half.
      def self.split_qname(value : String) : {String, String}
        i = value.index(':')
        # `size`, not `bytesize`: `String#index` answers in CHARS, and comparing that against a
        # byte count made the trailing-colon rule depend on how wide the name's characters are —
        # `"a:"` correctly stayed whole while `"ä:"` split into a prefix `"ä"` that then raised
        # `undeclared XML namespace prefix` instead of reaching the caller's error message.
        return {"", value} unless i && i > 0 && i < value.size - 1
        {value[0...i], value[(i + 1)..]}
      end

      private class Parser
        LT       = 0x3c_u8 # '<'
        GT       = 0x3e_u8 # '>'
        SLASH    = 0x2f_u8 # '/'
        BANG     = 0x21_u8 # '!'
        QUESTION = 0x3f_u8 # '?'
        EQ       = 0x3d_u8 # '='
        DQ       = 0x22_u8 # '"'
        SQ       = 0x27_u8 # '\''
        LF       = 0x0a_u8

        def initialize(@src : String, @limits : Limits)
          @raw = @src.to_slice
          @pos = 0
          @budget = @limits.max_nodes
          @stack = [] of Node
          @root = nil.as(Node?)
        end

        def run : Node
          skip_bom
          while @pos < @raw.size
            @raw[@pos] == LT ? dispatch : text_run
          end
          unless @stack.empty?
            raise err("unclosed element <#{@stack.last.display_name}> at end of document")
          end
          @root || raise err("XML document has no root element")
        end

        # --- dispatch ------------------------------------------------------------

        private def dispatch : Nil
          nxt = @raw[@pos + 1]? || raise err("stray `<` at end of document")
          case nxt
          when QUESTION then skip_pi
          when BANG     then bang
          when SLASH    then close_tag
          else               open_tag
          end
        end

        # A processing instruction is skipped, the `<?xml …?>` declaration included. Its
        # `encoding=` is IGNORED on purpose: gori reads every import source as UTF-8, and a
        # declaration claiming otherwise would describe bytes we have already scrubbed.
        private def skip_pi : Nil
          close = index_of("?>", @pos + 2) || raise err("unterminated processing instruction")
          @pos = close + 2
        end

        private def bang : Nil
          if starts_at?(@pos, "<!--")
            close = index_of("-->", @pos + 4) || raise err("unterminated XML comment")
            @pos = close + 3
          elsif starts_at?(@pos, "<![CDATA[")
            close = index_of("]]>", @pos + 9) || raise err("unterminated CDATA section")
            # CDATA is literal by definition — never entity-decoded, and its whitespace is
            # kept even though a whitespace-only text RUN is dropped: the author wrote the
            # section deliberately.
            node = @stack.last? || raise err("CDATA outside the root element")
            charge(1)
            node.add_text(String.new(@raw[(@pos + 9)...close]))
            @pos = close + 3
          elsif starts_at?(@pos, "<!DOCTYPE")
            refuse_doctype!
          else
            raise err("unexpected markup declaration — this reader accepts elements, comments and CDATA only")
          end
        end

        # DOCTYPE is REFUSED outright, not ignored. Refusing is the stronger rule and costs
        # nothing here: neither WSDL 1.1 nor XML Schema has any use for a DTD, so a DOCTYPE
        # in a .wsdl is a generator bug or an attack. IGNORING it would leave `&payload;` in
        # the document, which then decodes to nothing and yields a silently WRONG endpoint
        # URL — a refusal with a message is strictly better than a quietly corrupted seed
        # request.
        #
        # The two attacks this closes, at their root rather than by a counter:
        #   XXE            — no external entity can be declared, and this reader has no file
        #                    or network I/O of any kind to dereference one WITH.
        #   billion laughs — no internal general entity and no parameter entity can be
        #                    declared, so there is no expansion to bound.
        #                    `XmlText::NAMED_ENTITIES` is a fixed five-entry table and an
        #                    unknown `&foo;` stays VERBATIM rather than expanding, so entity
        #                    expansion is O(1) in the input by construction.
        #
        # This is stricter than P7 ("malformed input is the payload") on purpose, and the
        # distinction is provenance: a WSDL is a document DESCRIBING requests, not the
        # operator's own wire bytes. `Import::Raw` is the P7 path; this is not it.
        private def refuse_doctype! : NoReturn
          raise err("XML DOCTYPE declarations are refused (external-entity and " \
                    "entity-expansion risk) — a WSDL needs no DTD; remove the <!DOCTYPE …> line")
        end

        # --- tags ----------------------------------------------------------------

        private def open_tag : Nil
          @pos += 1
          name = read_name
          raise err("empty element name") if name.empty?
          raws, decls, self_closing = read_attributes(name)

          parent_ns = @stack.last?.try(&.ns) || ROOT_NS
          ns = child_ns(parent_ns, decls)

          prefix, local = XmlMini.split_qname(name)
          uri =
            if prefix.empty?
              # An unprefixed ELEMENT name DOES take the default namespace — the one place
              # the three name rules agree with intuition.
              ns[""]? || ""
            else
              ns[prefix]? || raise err("undeclared XML namespace prefix #{prefix.inspect} on <#{name}>")
            end

          attrs = raws.map do |(an, av)|
            ap, al = XmlMini.split_qname(an)
            au = ap.empty? ? "" : (ns[ap]? || raise err("undeclared XML namespace prefix #{ap.inspect} on attribute #{an.inspect}"))
            Attr.new(au, al, av)
          end

          charge(1 + attrs.size)
          node = Node.new(uri, local, prefix, attrs, ns)

          if parent = @stack.last?
            parent.children << node
          else
            raise err("XML document has more than one root element") if @root
            @root = node
          end

          return if self_closing
          # A self-closing `<x/>` is pushed and popped in one step above, so it is
          # indistinguishable downstream from `<x></x>` — which is what XML says they are.
          @stack << node
          if @stack.size > @limits.max_depth
            raise err("XML nesting is deeper than #{@limits.max_depth} levels")
          end
        end

        # `{ordinary attributes, xmlns declarations, was it self-closing}` for the start tag
        # whose name has just been read. Split out of `open_tag` because the two do different
        # jobs — this one scans, that one resolves names and builds the node.
        private def read_attributes(name : String) : {Array({String, String}), Array({String, String}), Bool}
          raws = [] of {String, String}
          decls = [] of {String, String}
          seen = Set(String).new
          loop do
            skip_ws
            b = @raw[@pos]? || raise err("unterminated start tag <#{name}>")
            if b == GT
              @pos += 1
              return {raws, decls, false}
            end
            if b == SLASH
              raise err("malformed start tag <#{name}>") unless @raw[@pos + 1]? == GT
              @pos += 2
              return {raws, decls, true}
            end

            aname = read_name
            raise err("malformed attribute in <#{name}>") if aname.empty?
            value = read_attribute_value(name, aname)
            # A duplicate attribute is not well-formed, and on `location=` silently keeping
            # one of the two is picking an endpoint at random.
            raise err("duplicate attribute #{aname.inspect} on <#{name}>") unless seen.add?(aname)

            if aname == "xmlns"
              decls << {"", value}
            elsif aname.starts_with?("xmlns:")
              prefix = aname[6..]
              raise err("empty namespace prefix in `xmlns:` on <#{name}>") if prefix.empty?
              decls << {prefix, value}
            else
              raws << {aname, value}
            end
          end
        end

        private def read_attribute_value(name : String, aname : String) : String
          skip_ws
          unless @raw[@pos]? == EQ
            raise err("attribute #{aname.inspect} in <#{name}> has no value")
          end
          @pos += 1
          skip_ws
          quote = @raw[@pos]?
          # An unquoted attribute value is REFUSED rather than read to the next space. That
          # shape is not XML, and tolerating it means guessing where the value ends — on
          # `location=` that is guessing the endpoint.
          if quote.nil? || !(quote == DQ || quote == SQ)
            raise err("unquoted attribute value for #{aname.inspect} in <#{name}>")
          end
          @pos += 1
          stop = @raw.index(quote, @pos) ||
                 raise err("unterminated attribute value for #{aname.inspect} in <#{name}>")
          value = XmlText.unescape(String.new(@raw[@pos...stop]))
          @pos = stop + 1
          value
        end

        private def close_tag : Nil
          @pos += 2
          name = read_name
          skip_ws
          raise err("malformed closing tag </#{name}>") unless @raw[@pos]? == GT
          @pos += 1

          node = @stack.pop? || raise err("unexpected closing tag </#{name}> with no open element")
          prefix, local = XmlMini.split_qname(name)
          # Matched on the RESOLVED name, not the spelling: `</x:foo>` closes `<y:foo>` when
          # both prefixes are bound to the same URI, and does not when they are not.
          uri =
            if prefix.empty?
              node.ns[""]? || ""
            else
              node.ns[prefix]? || raise err("undeclared XML namespace prefix #{prefix.inspect} on </#{name}>")
            end
          unless uri == node.uri && local == node.local
            raise err("mismatched closing tag </#{name}> (expected </#{node.display_name}>)")
          end
        end

        # --- text ----------------------------------------------------------------

        private def text_run : Nil
          start = @pos
          while @pos < @raw.size && @raw[@pos] != LT
            @pos += 1
          end
          chunk = String.new(@raw[start...@pos])
          if @stack.empty?
            # The prolog and epilog may hold whitespace and nothing else.
            raise err("text outside the root element") unless chunk.blank?
            return
          end
          # A whitespace-only run between two tags is dropped. A WSDL is mostly those, no
          # caller wants them, and keeping them would allocate a String per indent. Mixed
          # content is not a shape WSDL or XML Schema produces; CDATA (above) is kept
          # regardless, which is the escape hatch for a document that means its whitespace.
          return if chunk.blank?
          # Charged like an element: a KEPT run is a thing this document made us hold, and
          # `max_nodes` is the only ceiling that counts them. A whitespace-only run is dropped
          # above and costs nothing, which is most of a real WSDL.
          charge(1)
          @stack.last.add_text(XmlText.unescape(chunk))
        end

        # --- namespaces ----------------------------------------------------------

        # The child's in-scope prefix map.
        #
        # When an element declares no `xmlns:*` — which is essentially every element in a
        # real WSDL, since generators put every binding on `<definitions>` — the PARENT'S
        # map is shared BY REFERENCE, so a 40 000-node document allocates one Hash rather
        # than 40 000. A declaration forces a copy, and that copy is what gives the inner
        # scope its own lifetime. `ns` is never mutated after construction, which is what
        # makes the sharing sound.
        private def child_ns(parent : NsMap, decls : Array({String, String})) : NsMap
          return parent if decls.empty?
          merged = parent.dup
          decls.each do |(prefix, uri)|
            # `xmlns=""` UNDECLARES the default namespace (XML Names §6.2). It does not bind
            # the empty prefix to the empty URI — that would make every unprefixed descendant
            # resolve into a namespace literally called "". Delete the key instead.
            if prefix.empty? && uri.empty?
              merged.delete("")
            else
              merged[prefix] = uri
            end
          end
          merged
        end

        # --- scanning primitives -------------------------------------------------

        private def skip_bom : Nil
          @pos = 3 if starts_at?(0, "\u{feff}")
        end

        private def skip_ws : Nil
          while @pos < @raw.size && ws?(@raw[@pos])
            @pos += 1
          end
        end

        private def ws?(b : UInt8) : Bool
          b == 0x20_u8 || b == 0x09_u8 || b == 0x0a_u8 || b == 0x0d_u8
        end

        # A name runs to the first byte that cannot be in one. Every XML delimiter is ASCII,
        # so a byte scan reads exactly what a char scan would and needs no decoding.
        private def read_name : String
          start = @pos
          while @pos < @raw.size
            b = @raw[@pos]
            break if ws?(b) || b == GT || b == SLASH || b == EQ
            @pos += 1
          end
          String.new(@raw[start...@pos])
        end

        private def starts_at?(at : Int32, s : String) : Bool
          b = s.to_slice
          return false if at + b.size > @raw.size
          b.each_with_index { |x, k| return false if @raw[at + k] != x }
          true
        end

        # Byte-wise, NOT `String#index`: `@pos` is a byte offset and `String#index` answers
        # in CHARS, so the two disagree the moment the document holds one non-ASCII byte.
        private def index_of(needle : String, from : Int32) : Int32?
          n = needle.to_slice
          return nil if n.empty?
          i = from
          last = @raw.size - n.size
          while i <= last
            if @raw[i] == n[0]
              j = 1
              while j < n.size && @raw[i + j] == n[j]
                j += 1
              end
              return i if j == n.size
            end
            i += 1
          end
          nil
        end

        private def charge(n : Int32) : Nil
          @budget -= n
          raise err("XML document has more than #{@limits.max_nodes} nodes") if @budget < 0
        end

        # Errors name a LINE, because that is what the operator can go and look at. Counting
        # is O(n) but an error is terminal, so it happens at most once.
        private def err(message : String) : Gori::Error
          line = 1
          i = 0
          while i < @pos && i < @raw.size
            line += 1 if @raw[i] == LF
            i += 1
          end
          Gori::Error.new("#{message} (line #{line})")
        end
      end
    end
  end
end
