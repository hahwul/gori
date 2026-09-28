require "json"
require "./schema"

module Gori
  module Graphql
    # One request per root field of a schema: every query and every mutation, written the way an
    # operator would start one by hand, so each is a request that can be sent as it is.
    #
    #   query user($id: ID!, $filter: UserFilter) {
    #     user(id: $id, filter: $filter) {
    #       id
    #       name
    #     }
    #   }
    #
    # Every argument becomes a variable and is passed, so the document shows what the field
    # accepts. Only the REQUIRED ones get a value in `variables`: GraphQL treats a declared variable
    # the request does not supply as an argument that was not given, so an optional filter stays
    # off until the operator fills it in, instead of going out as an empty string that changes
    # what the field returns.
    #
    # Subscriptions are listed in the notes and not generated: they run over a WebSocket, and a
    # generated operation is sent as an HTTP request.
    module Operations
      extend self

      record Operation, kind : String, field : String, document : String, variables : String?

      record Generated, operations : Array(Operation), notes : Array(String)

      # How many object levels a selection descends below the root field. The document is
      # regenerated shallower when it comes out past `MAX_DOCUMENT`.
      MAX_DEPTH = 3

      # A document past this is written again one level shallower, down to the root field's own
      # scalars. A connection type on a large schema fans out fast, and a 200 KB request nobody
      # can read is not a starting point.
      MAX_DOCUMENT = 16 * 1024

      # Fields listed per selection set. The rest of a very wide type is left for the operator.
      MAX_FIELDS = 64

      # How deep a placeholder input object is filled in. Past it, a required nested input is `{}`.
      MAX_INPUT_DEPTH = 5

      # Placeholder values written per operation. The depth cap alone does not bound the work: a
      # schema of input types each with 50 required fields of the next is 50^5 values at depth 5,
      # and the schema is the target's text.
      MAX_PLACEHOLDERS = 1024

      # A countdown shared by one document's (or one `variables` object's) recursive writers, so
      # the work is bounded by what is written rather than by how far the schema fans out.
      private class Budget
        def initialize(@left : Int32)
        end

        def spend(n : Int32) : Nil
          @left -= n
        end

        def spent? : Bool
          @left < 0
        end
      end

      def generate(schema : Schema) : Generated
        ops = [] of Operation
        notes = [] of String
        {"query" => schema.query_type, "mutation" => schema.mutation_type}.each do |kind, root|
          next unless root
          unless type = schema.types[root]?
            notes << "the schema names #{root} as its #{kind} type but does not describe it"
            next
          end
          type.fields.each do |field|
            next if field.name.starts_with?("__")
            ops << operation(schema, kind, field)
          end
        end
        if (sub = schema.subscription_type) && (t = schema.types[sub]?)
          n = t.fields.count { |f| !f.name.starts_with?("__") }
          if n > 0
            notes << "#{n} subscription field#{n == 1 ? "" : "s"} not generated — subscriptions run over a WebSocket"
          end
        end
        Generated.new(ops, notes)
      end

      private def operation(schema : Schema, kind : String, field : Schema::Field) : Operation
        doc = ""
        MAX_DEPTH.downto(0) do |depth|
          # The budget stops a level that blows past the size cap while it is being written, not
          # after a multi-MB document has been built only to be thrown away.
          budget = Budget.new(MAX_DOCUMENT)
          doc = document(schema, kind, field, depth, budget)
          break unless budget.spent? || doc.bytesize > MAX_DOCUMENT
        end
        Operation.new(kind, field.name, doc, variables(schema, field))
      end

      private def document(schema : Schema, kind : String, field : Schema::Field, depth : Int32, budget : Budget) : String
        String.build do |io|
          io << kind << ' ' << field.name
          unless field.args.empty?
            io << '('
            field.args.each_with_index do |arg, i|
              io << ", " if i > 0
              io << '$' << arg.name << ": " << variable_type(arg)
            end
            io << ')'
          end
          io << " {\n  " << field.name
          unless field.args.empty?
            io << '('
            field.args.each_with_index do |arg, i|
              io << ", " if i > 0
              io << arg.name << ": $" << arg.name
            end
            io << ')'
          end
          if (named = field.type.named) && (sel = selection(schema, named, 1, depth, "    ", budget))
            io << " {\n" << sel << "\n  }"
          end
          io << "\n}"
        end
      end

      # The type a variable is declared with. A defaulted non-null argument is declared NULLABLE:
      # it is left out of `variables`, and GraphQL lets a nullable variable reach a non-null
      # argument only because the argument has a default to fall back to. Declared `Int!`, the
      # omitted variable is an error and the request cannot be sent as generated.
      private def variable_type(arg : Schema::InputValue) : String
        type = arg.type
        inner = type.of_type
        type.non_null? && arg.default_value && inner ? inner.to_s : type.to_s
      end

      # The selection set for a value of type `name`, or nil for a leaf (a scalar or an enum is
      # selected by naming it, with no braces). An object with nothing selectable at this depth
      # still gets `__typename`, because an empty selection set is a syntax error.
      private def selection(schema : Schema, name : String, depth : Int32, max : Int32, pad : String, budget : Budget) : String?
        type = schema.types[name]? || return nil
        case type.kind
        when .object?, .interface? then field_selection(schema, type, depth, max, pad, budget)
        when .union?               then union_selection(schema, type, depth, max, pad, budget)
        end
      end

      # An object or interface: its own fields, descending into object-typed ones while `depth`
      # is under `max`.
      private def field_selection(schema : Schema, type : Schema::Type, depth : Int32, max : Int32, pad : String, budget : Budget) : String
        lines = [] of String
        type.fields.each do |f|
          break if lines.size >= MAX_FIELDS || budget.spent?
          next if f.name.starts_with?("__")
          # A field with a required argument cannot be selected without a value for it.
          next if f.args.any?(&.required?)
          inner = f.type.named || next
          inner_type = schema.types[inner]? || next
          if inner_type.kind.leaf?
            lines << "#{pad}#{f.name}"
            budget.spend(pad.bytesize + f.name.bytesize + 1)
          elsif depth < max && (sub = selection(schema, inner, depth + 1, max, pad + "  ", budget))
            lines << "#{pad}#{f.name} {\n#{sub}\n#{pad}}"
            budget.spend(2 * pad.bytesize + f.name.bytesize + 4) # the braces; `sub` spent its own
          end
        end
        lines.empty? ? "#{pad}__typename" : lines.join('\n')
      end

      # A union has no fields of its own: `__typename`, then an inline fragment per member.
      private def union_selection(schema : Schema, type : Schema::Type, depth : Int32, max : Int32, pad : String, budget : Budget) : String
        lines = ["#{pad}__typename"]
        if depth < max
          type.possible_types.each do |member|
            break if lines.size >= MAX_FIELDS || budget.spent?
            if sub = selection(schema, member, depth + 1, max, pad + "  ", budget)
              lines << "#{pad}... on #{member} {\n#{sub}\n#{pad}}"
              budget.spend(2 * pad.bytesize + member.bytesize + 12)
            end
          end
        end
        lines.join('\n')
      end

      # `{"id": ""}` for the required arguments, or nil when there are none.
      private def variables(schema : Schema, field : Schema::Field) : String?
        required = field.args.select(&.required?)
        return nil if required.empty?
        budget = Budget.new(MAX_PLACEHOLDERS)
        JSON.build do |j|
          j.object do
            required.each do |arg|
              j.field arg.name do
                placeholder(schema, arg.type, 0, j, budget)
              end
            end
          end
        end
      end

      # A value of the right shape for `ref`: `0`, `0.0`, `false`, `""`, an enum's first value, a
      # one-element list, or an input object with its own required fields filled in.
      private def placeholder(schema : Schema, ref : Schema::TypeRef, depth : Int32, j : JSON::Builder, budget : Budget) : Nil
        budget.spend(1)
        case ref.kind
        when .non_null?
          if inner = ref.of_type
            placeholder(schema, inner, depth, j, budget)
          else
            j.null
          end
        when .list?
          j.array do
            ref.of_type.try { |inner| placeholder(schema, inner, depth, j, budget) }
          end
        else
          name = ref.name || return j.null
          case name
          when "Int"     then j.number(0)
          when "Float"   then j.number(0.0)
          when "Boolean" then j.bool(false)
          when "String", "ID"
            j.string("")
          else
            named_placeholder(schema, schema.types[name]?, depth, j, budget)
          end
        end
      end

      private def named_placeholder(schema : Schema, type : Schema::Type?, depth : Int32, j : JSON::Builder, budget : Budget) : Nil
        unless type
          j.string("")
          return
        end
        case type.kind
        when .enum?
          if first = type.enum_values.first?
            j.string(first)
          else
            j.null
          end
        when .input_object?
          j.object do
            if depth < MAX_INPUT_DEPTH
              type.input_fields.each do |f|
                break if budget.spent? # past it, the rest of a huge input is the operator's to fill
                next unless f.required?
                j.field f.name do
                  placeholder(schema, f.type, depth + 1, j, budget)
                end
              end
            end
          end
        else
          # A custom scalar (`DateTime`, `JSON`, `Upload`): its format is the server's, and a
          # string is the likeliest to parse and the easiest to replace.
          j.string("")
        end
      end
    end
  end
end
