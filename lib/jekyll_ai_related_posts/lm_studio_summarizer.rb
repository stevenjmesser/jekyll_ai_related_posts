# frozen_string_literal: true

require "faraday"

module JekyllAiRelatedPosts
  class LmStudioSummarizer
    DEFAULT_MAX_CHARS = 8000
    DEFAULT_PROMPT = <<~PROMPT.strip
      Summarize the provided blog post content for related-post embeddings.
      Format your output exactly as:
      Topics:
      - <topic 1>
      - <topic 2>
      - <topic 3>
      - <topic 4>
      - <topic 5>
      - <optional topic 6>
      - <optional topic 7>
      - <optional topic 8>
      Abstract:
      <1-2 sentence abstract>
    PROMPT

    class ServerUnavailableError < JekyllAiRelatedPosts::Error; end

    def initialize(model, base_url: LmStudioEmbeddings::DEFAULT_BASE_URL, prompt: DEFAULT_PROMPT,
                   max_chars: DEFAULT_MAX_CHARS, connection: nil)
      @model = model
      @prompt = prompt
      @max_chars = max_chars
      @connection = connection || Faraday.new(url: base_url) do |builder|
        builder.request :json
        builder.response :json
        builder.response :raise_error
      end
    end

    def summarize(text)
      res = @connection.post("/v1/chat/completions") do |req|
        req.body = {
          model: @model,
          messages: [
            { role: "system", content: @prompt },
            { role: "user", content: truncate_text(text.to_s) }
          ]
        }
      end

      content = res.body.dig("choices", 0, "message", "content")
      if content.nil? || content.to_s.strip.empty?
        raise JekyllAiRelatedPosts::Error, "Unexpected response from LM Studio chat completions API"
      end

      normalize_summary(content)
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

    private

    def truncate_text(text)
      text[0, @max_chars]
    end

    def normalize_summary(summary)
      summary.to_s
             .gsub(/\r\n?/, "\n")
             .lines
             .map(&:strip)
             .reject(&:empty?)
             .join("\n")
             .strip
    end
  end
end
