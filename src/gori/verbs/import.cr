require "../verb"

module Gori
  module Verbs
    def self.register_import(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "import.har", "Import: HAR", "Import HTTP flows from a HAR file into History",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_har; nil }
      r.register Verb::Definition.new(
        "import.urls", "Import: URLs", "Import URLs from a text file into History (one URL per line)",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_urls; nil }
      r.register Verb::Definition.new(
        "import.oas", "Import: OpenAPI", "Import request templates from an OpenAPI spec into History",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_oas; nil }
      r.register Verb::Definition.new(
        "import.postman", "Import: Postman", "Import request templates from a Postman Collection v2 export",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_postman; nil }
      r.register Verb::Definition.new(
        "import.insomnia", "Import: Insomnia", "Import request templates from an Insomnia v4 JSON export",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_insomnia; nil }
      r.register Verb::Definition.new(
        "import.burp", "Import: Burp", "Import saved Burp items (request + response) into History",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_burp; nil }
      r.register Verb::Definition.new(
        "import.wsdl", "Import: WSDL", "Import SOAP request templates from a WSDL 1.1 service description",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_wsdl; nil }
      # Listed only while an import runs (`available:`), which is also the only time it means
      # anything. Stops after the chunk being written; what is committed stays.
      r.register Verb::Definition.new(
        "import.cancel", "Import: cancel", "Stop the running import after its current chunk (the flows already written stay)",
        Verb::Scope::Global, available: ->(ctx : Verb::ExecContext) { ctx.import_running? },
        category: Verb::Category::Action) { |ctx| ctx.import_cancel; nil }
    end
  end
end
