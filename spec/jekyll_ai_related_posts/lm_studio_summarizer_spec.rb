# frozen_string_literal: true

require "json"

RSpec.describe JekyllAiRelatedPosts::LmStudioSummarizer do
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
    JekyllAiRelatedPosts::LmStudioSummarizer.new(
      "qwen2.5",
      prompt: "Summarize",
      max_chars: 12,
      connection: conn
    )
  end

  it "parses chat completion response content and normalizes whitespace" do
    stubs.post("/v1/chat/completions") do |env|
      body = env.body.is_a?(String) ? JSON.parse(env.body) : env.body
      expect(body["model"] || body[:model]).to eq("qwen2.5")
      user_message = (body["messages"] || body[:messages]).last
      expect(user_message["content"] || user_message[:content]).to eq("A long post ")

      [
        200,
        { "Content-Type" => "application/json" },
        {
          choices: [
            {
              message: {
                content: "Topics:\n- Networking\n\n- Homelab\n\nAbstract:\n  Two sentence summary. "
              }
            }
          ]
        }.to_json
      ]
    end

    expect(subject.summarize("A long post content that should be truncated")).to eq(
      "Topics:\n- Networking\n- Homelab\nAbstract:\nTwo sentence summary."
    )
  end
end
