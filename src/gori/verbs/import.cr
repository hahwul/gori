require "../verb"

module Gori
  module Verbs
    def self.register_import(r : Verb::Registry) : Nil
      r.register Verb::Definition.new(
        "import.har", "import:har", "Import HTTP flows from a HAR file into History",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_har; nil }
      r.register Verb::Definition.new(
        "import.urls", "import:urls", "Import URLs from a text file into History (one URL per line)",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_urls; nil }
      r.register Verb::Definition.new(
        "import.oas", "import:oas", "Import request templates from an OpenAPI spec into History",
        Verb::Scope::Global, category: Verb::Category::Action) { |ctx| ctx.import_oas; nil }
    end
  end
end