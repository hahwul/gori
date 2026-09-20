require "../../spec_helper"
require "../../support/probe_harness"

describe Gori::Probe::Passive::ApiDocsExposed do
  it "flags a Swagger UI / ReDoc HTML page" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store,
        %(<div id="swagger-ui"></div><script src="swagger-ui-bundle.js"></script>)))
        .should contain("api_docs_exposed")
      probe_codes_of(probe_analyze_html(store,
        %(<redoc spec-url="/openapi.json"></redoc>))).should contain("api_docs_exposed")
    end
  end

  it "flags an interactive GraphQL IDE" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, %(<title>GraphiQL</title><script src="graphiql.min.js">)))
        .should contain("api_docs_exposed")
      probe_codes_of(probe_analyze_html(store, %(window.GraphQLPlayground = {}; // GraphQL Playground)))
        .should contain("api_docs_exposed")
    end
  end

  it "flags an OpenAPI/Swagger spec served as JSON" do
    with_store do |store|
      json = %({"openapi":"3.0.3","info":{"title":"x"},"paths":{"/u":{}}})
      probe_codes_of(probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: json)).should contain("api_docs_exposed")
      swagger2 = %({"swagger":"2.0","paths":{"/u":{}}})
      probe_codes_of(probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: swagger2)).should contain("api_docs_exposed")
    end
  end

  it "does not flag ordinary pages or JSON that merely names the format" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store, "<h1>Welcome</h1><p>Our API is documented elsewhere.</p>"))
        .should_not contain("api_docs_exposed")
      # A version key with no top-level "paths" object is not a spec (prose about OpenAPI).
      probe_codes_of(probe_analyze(store,
        resp_head: "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n",
        content_type: "application/json", body: %({"note":"we use openapi: 3 internally"})))
        .should_not contain("api_docs_exposed")
    end
  end
end
