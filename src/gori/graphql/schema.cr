require "json"

module Gori
  module Graphql
    # A GraphQL schema read out of an introspection RESULT: the answer a server gives to
    # `Introspection::QUERY`, either as the response body (`{"data":{"__schema":…}}`) or saved
    # on its own (`{"__schema":…}`).
    #
    # Only what `Operations` needs to write a request is kept: the root type names, and for every
    # type its kind, fields with their arguments, input fields, enum values and union members.
    # Descriptions, deprecation and directives are dropped.
    #
    # The schema is the TARGET's text, so every name is checked against the GraphQL name grammar
    # before it can reach a generated document. A name that fails is dropped with the field or
    # type carrying it, never repaired: a schema describing `a) { evil }` as a field name is
    # hostile or broken, and either way no request can call it.
    class Schema
      enum Kind
        Scalar
        Object
        Interface
        Union
        Enum
        InputObject
        List
        NonNull

        # The `__TypeKind` spelling. Not `parse?`, which every enum already has with a different
        # grammar (case-insensitive, underscores ignored) that must not be shadowed.
        def self.from_wire(s : String?) : Kind?
          case s
          when "SCALAR"       then Scalar
          when "OBJECT"       then Object
          when "INTERFACE"    then Interface
          when "UNION"        then Union
          when "ENUM"         then Enum
          when "INPUT_OBJECT" then InputObject
          when "LIST"         then List
          when "NON_NULL"     then NonNull
          end
        end

        def leaf? : Bool
          scalar? || enum?
        end
      end

      # A type reference: a named type wrapped in any number of LIST / NON_NULL.
      class TypeRef
        getter kind : Kind
        getter name : String?
        getter of_type : TypeRef?

        def initialize(@kind : Kind, @name : String?, @of_type : TypeRef?)
        end

        # The named type under the wrappers.
        def named : String?
          ref = self
          while inner = ref.of_type
            ref = inner
          end
          ref.name
        end

        def non_null? : Bool
          kind.non_null?
        end

        # The GraphQL spelling (`[ID!]!`), as a variable definition writes it.
        def to_s(io : IO) : Nil
          case kind
          when .non_null?
            of_type.try(&.to_s(io))
            io << '!'
          when .list?
            io << '['
            of_type.try(&.to_s(io))
            io << ']'
          else
            io << name
          end
        end
      end

      record InputValue, name : String, type : TypeRef, default_value : String? do
        # Whether a request must supply it: non-null and no default to fall back to.
        def required? : Bool
          type.non_null? && default_value.nil?
        end
      end

      record Field, name : String, args : Array(InputValue), type : TypeRef

      record Type, kind : Kind, name : String, fields : Array(Field),
        input_fields : Array(InputValue), enum_values : Array(String),
        possible_types : Array(String)

      # A body past this is refused before parsing. Large public schemas (GitHub's, Shopify's)
      # answer introspection with 1–3 MiB of JSON.
      MAX_BYTES = 32 * 1024 * 1024

      # The deepest wrapper chain read. The query asks for seven levels of `ofType`; a result
      # nesting deeper than it was asked to is not one to follow.
      MAX_WRAPPERS = 16

      NAME = /\A[_A-Za-z][_0-9A-Za-z]*\z/

      getter types : Hash(String, Type)
      getter query_type : String?
      getter mutation_type : String?
      getter subscription_type : String?

      def initialize(@types : Hash(String, Type), @query_type : String?,
                     @mutation_type : String?, @subscription_type : String?)
      end

      # A GraphQL name, the only thing allowed into a generated document from the schema.
      def self.name?(s : String) : Bool
        NAME.matches?(s)
      end

      # Raises `Gori::Error` with the reason when `text` is not an introspection result.
      def self.parse(text : String) : Schema
        raise Gori::Error.new("the response is larger than #{MAX_BYTES // (1024 * 1024)} MiB") if text.bytesize > MAX_BYTES
        json = begin
          JSON.parse(text.lchop('\u{FEFF}'))
        rescue JSON::ParseException
          raise Gori::Error.new("the response is not JSON, so it is not an introspection result")
        end
        root = json.as_h? || raise Gori::Error.new("the response is not a JSON object")
        schema = root["data"]?.try(&.as_h?).try(&.["__schema"]?).try(&.as_h?) ||
                 root["__schema"]?.try(&.as_h?)
        unless schema
          if msg = first_error(root)
            raise Gori::Error.new("the server answered with an error instead of a schema: #{msg}")
          end
          raise Gori::Error.new("the response carries no __schema — send the introspection query first")
        end
        types = {} of String => Type
        each_of(schema["types"]?) do |t|
          if type = parse_type(t)
            types[type.name] = type
          end
        end
        raise Gori::Error.new("the __schema lists no types") if types.empty?
        new(types, root_name(schema, "queryType"), root_name(schema, "mutationType"),
          root_name(schema, "subscriptionType"))
      end

      private def self.first_error(root : Hash(String, JSON::Any)) : String?
        err = root["errors"]?.try(&.as_a?).try(&.first?) || return nil
        msg = err.as_h?.try(&.["message"]?).try(&.as_s?) || err.to_json
        msg.size > 200 ? "#{msg[0, 200]}…" : msg
      end

      private def self.root_name(schema : Hash(String, JSON::Any), key : String) : String?
        name = schema[key]?.try(&.as_h?).try(&.["name"]?).try(&.as_s?) || return nil
        name?(name) ? name : nil
      end

      private def self.parse_type(t : JSON::Any) : Type?
        h = t.as_h? || return nil
        kind = Kind.from_wire(h["kind"]?.try(&.as_s?)) || return nil
        # A named type is never a wrapper; a `types` entry claiming LIST or NON_NULL is not one.
        return nil if kind.list? || kind.non_null?
        name = h["name"]?.try(&.as_s?) || return nil
        return nil unless name?(name)
        fields = [] of Field
        each_of(h["fields"]?) do |f|
          if field = parse_field(f)
            fields << field
          end
        end
        Type.new(kind, name, fields, input_values(h["inputFields"]?), names(h["enumValues"]?),
          names(h["possibleTypes"]?))
      end

      private def self.parse_field(f : JSON::Any) : Field?
        h = f.as_h? || return nil
        name = h["name"]?.try(&.as_s?) || return nil
        return nil unless name?(name)
        type = type_ref(h["type"]?, 0) || return nil
        args = [] of InputValue
        each_of(h["args"]?) do |a|
          if v = input_value(a)
            args << v
          elsif a.as_h?.try(&.["type"]?).try(&.as_h?).try(&.["kind"]?).try(&.as_s?) == "NON_NULL"
            # An argument that did not parse is one the generated call cannot pass. Dropping it
            # is harmless when it is optional, but without a REQUIRED one every request the field
            # would produce is invalid, so the field goes with it.
            return nil
          end
        end
        Field.new(name, args, type)
      end

      private def self.input_values(raw : JSON::Any?) : Array(InputValue)
        acc = [] of InputValue
        each_of(raw) do |a|
          if v = input_value(a)
            acc << v
          end
        end
        acc
      end

      # The valid `name`s of a list of `{name: …}` objects (enum values, union members).
      private def self.names(raw : JSON::Any?) : Array(String)
        acc = [] of String
        each_of(raw) do |v|
          if (n = v.as_h?.try(&.["name"]?).try(&.as_s?)) && name?(n)
            acc << n
          end
        end
        acc
      end

      # Each element of `raw` when it is a JSON array; anything else (absent, null, an object)
      # yields nothing, since introspection answers `null` for the lists a kind does not have.
      private def self.each_of(raw : JSON::Any?, & : JSON::Any ->) : Nil
        if arr = raw.try(&.as_a?)
          arr.each { |e| yield e }
        end
      end

      private def self.input_value(a : JSON::Any) : InputValue?
        h = a.as_h? || return nil
        name = h["name"]?.try(&.as_s?) || return nil
        return nil unless name?(name)
        type = type_ref(h["type"]?, 0) || return nil
        InputValue.new(name, type, h["defaultValue"]?.try(&.as_s?))
      end

      private def self.type_ref(raw : JSON::Any?, depth : Int32) : TypeRef?
        return nil if depth > MAX_WRAPPERS
        h = raw.try(&.as_h?) || return nil
        kind = Kind.from_wire(h["kind"]?.try(&.as_s?)) || return nil
        if kind.list? || kind.non_null?
          inner = type_ref(h["ofType"]?, depth + 1) || return nil
          # `[T]!!` is not a type. A non-null directly wrapping a non-null cannot be written in a
          # variable definition, so the reference is refused rather than spelled wrong.
          return nil if kind.non_null? && inner.non_null?
          return TypeRef.new(kind, nil, inner)
        end
        name = h["name"]?.try(&.as_s?) || return nil
        return nil unless name?(name)
        TypeRef.new(kind, name, nil)
      end
    end
  end
end
