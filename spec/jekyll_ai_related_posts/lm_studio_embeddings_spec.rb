# frozen_string_literal: true

require "json"

RSpec.describe JekyllAiRelatedPosts::LmStudioEmbeddings do
  let(:stubs) { Faraday::Adapter::Test::Stubs.new }
  let(:conn) do
    Faraday.new do |builder|
      builder.adapter :test, stubs
      builder.request :json
      builder.response :json
      builder.response :raise_error
    end
  end
  subject do
    JekyllAiRelatedPosts::LmStudioEmbeddings.new("nomic-embed-text", connection: conn)
  end

  it "makes a request to LM Studio embeddings API with configured model" do
    stubs.post("/v1/embeddings") do |env|
      body = env.body.is_a?(String) ? JSON.parse(env.body) : env.body
      expect(body["input"] || body[:input]).to eq("My test")
      expect(body["model"] || body[:model]).to eq("nomic-embed-text")
      [
        200,
        { "Content-Type" => "application/json" },
        { data: [ { embedding: [ 0.01, 0.02 ] } ] }.to_json
      ]
    end

    expect(subject.embedding_for("My test")).to eq([ 0.01, 0.02 ])
  end

  it "handles LM Studio server unavailable errors" do
    failing_conn = instance_double(Faraday::Connection)
    allow(failing_conn).to receive(:post).and_raise(Faraday::ConnectionFailed, "connection failed")
    fetcher = JekyllAiRelatedPosts::LmStudioEmbeddings.new("nomic-embed-text", connection: failing_conn)
    logger = double("logger")
    allow(Jekyll).to receive(:logger).and_return(logger)
    expect(logger).to receive(:warn).with("AI Related Posts:", "LM Studio server unavailable. Is LM Studio running?")
    expect(logger).to receive(:warn).with("AI Related Posts:", /Faraday::ConnectionFailed/)

    expect { fetcher.embedding_for("My test") }
      .to raise_error(JekyllAiRelatedPosts::LmStudioEmbeddings::ServerUnavailableError)
  end

  it "raises an error for malformed LM Studio responses" do
    stubs.post("/v1/embeddings") do |_env|
      [
        200,
        { "Content-Type" => "application/json" },
        { data: [] }.to_json
      ]
    end

    expect { subject.embedding_for("My test") }
      .to raise_error(JekyllAiRelatedPosts::Error, /Unexpected response/)
  end
end
