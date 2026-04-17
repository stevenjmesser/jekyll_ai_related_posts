# frozen_string_literal: true

require "faraday"

module JekyllAiRelatedPosts
  class LmStudioEmbeddings
    DIMENSIONS = 1536
    DEFAULT_BASE_URL = "http://127.0.0.1:1234"

    class ServerUnavailableError < JekyllAiRelatedPosts::Error; end

    def initialize(model, base_url: DEFAULT_BASE_URL, connection: nil)
      @model = model
      @connection = if connection.nil?
                      Faraday.new(url: base_url) do |builder|
                        builder.request :json
                        builder.response :json
                        builder.response :raise_error
                      end
      else
                      connection
      end
    end

    def embedding_for(text)
      res = @connection.post("/v1/embeddings") do |req|
        req.body = {
          input: text,
          model: @model
        }
      end

      res.body["data"].first["embedding"]
    rescue Faraday::ConnectionFailed => e
      Jekyll.logger.warn "AI Related Posts:", "LM Studio server unavailable. Is LM Studio running?"
      Jekyll.logger.warn "AI Related Posts:", e.inspect

      raise ServerUnavailableError, "LM Studio server unavailable"
    rescue Faraday::Error => e
      Jekyll.logger.error "AI Related Posts:", "Error response from LM Studio API!"
      Jekyll.logger.error "AI Related Posts:", e.inspect

      raise
    end
  end
end
