# frozen_string_literal: true

require "faraday"

module JekyllAiRelatedPosts
  class LmStudioEmbeddings
    DEFAULT_DIMENSIONS = 1536
    DEFAULT_BASE_URL = "http://127.0.0.1:1234"

    class ServerUnavailableError < JekyllAiRelatedPosts::Error; end

    def initialize(model, base_url: DEFAULT_BASE_URL, connection: nil)
      @model = model
      @connection = connection || Faraday.new(url: base_url) do |builder|
        builder.request :json
        builder.response :json
        builder.response :raise_error
      end
    end

    def embedding_for(text)
      res = @connection.post("/v1/embeddings") do |req|
        req.body = {
          input: text,
          model: @model
        }
      end

      data = res.body["data"]
      embedding = data&.first&.[]("embedding")
      if embedding.nil?
        raise JekyllAiRelatedPosts::Error, "Unexpected response from LM Studio embeddings API"
      end

      embedding
    rescue Faraday::ConnectionFailed => e
      Jekyll.logger.warn "AI Related Posts:", "LM Studio server unavailable. Is LM Studio running?"
      Jekyll.logger.warn "AI Related Posts:", e.inspect

      raise ServerUnavailableError, "LM Studio server unavailable"
    rescue JekyllAiRelatedPosts::Error => e
      Jekyll.logger.error "AI Related Posts:", e.message

      raise
    rescue Faraday::Error => e
      Jekyll.logger.error "AI Related Posts:", "Error response from LM Studio API!"
      Jekyll.logger.error "AI Related Posts:", e.inspect

      raise
    end
  end
end
