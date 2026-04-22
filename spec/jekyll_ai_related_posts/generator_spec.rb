# frozen_string_literal: true

require "debug"
require "ostruct"

RSpec.describe JekyllAiRelatedPosts::Generator do
  let(:config_overrides) do
    {
      "ai_related_posts" => {
        "openai_api_key" => "my_key",
        "embeddings_source" => "mock",
        "summary_enabled" => false
      }
    }
  end
  let(:site) do
    fixture_site(config_overrides)
  end

  before(:each) do
    File.delete(site.in_source_dir(".ai_related_posts_cache.sqlite3"))
  rescue Errno::ENOENT
  end

  it "generates related posts" do
    site.process

    wifi_upgrades = File.read(dest_dir("2023", "12", "22",
                                       "home-wifi-upgrades-adding-an-access-point-with-wired-backhaul.html"))
    expect(wifi_upgrades).to include("1:::Analyzing Static Website Logs with AWStats")
    expect(wifi_upgrades).to include("2:::Catching Mew: A Playable Game Boy Quote")
  end

  it "regenerates when posts are edited" do
    # Create the cache
    site.process

    contents = File.read("spec/source/_posts/2023-12-22-home-wifi-upgrades-adding-an-access-point-with-wired-backhaul.md")
    contents.gsub!(/title:.+/, "title: How to Catch Pokemon")
    File.open("spec/source/_posts/2023-12-22-home-wifi-upgrades-adding-an-access-point-with-wired-backhaul.md",
              "w") do |file|
      file.write(contents)
    end

    expect_any_instance_of(MockEmbeddings)
      .to receive(:embedding_for)
      .with("Title: How to Catch Pokemon; Tags: Technology")
      .and_call_original
    site.process
  ensure
    contents.gsub!(/title:.+/, 'title: "Home WiFi Upgrades: Adding an Access Point with Wired Backhaul"')
    File.open("spec/source/_posts/2023-12-22-home-wifi-upgrades-adding-an-access-point-with-wired-backhaul.md",
              "w") do |file|
      file.write(contents)
    end
  end

  context "fetch disabled" do
    let(:config_overrides) do
      {
          "ai_related_posts" => {
            "openai_api_key" => "my_key",
            "embeddings_source" => "mock",
            "fetch_enabled" => false,
            "summary_enabled" => false
          }
        }
      end

    it "does not fetch embeddings from the API" do
      expect_any_instance_of(MockEmbeddings).not_to receive(:embedding_for)

      site.process
    end
  end

  describe "#new_fetcher" do
    it "uses LM Studio with embedding_model config" do
      generator = described_class.new
      site = instance_double(
        Jekyll::Site,
        config: {
          "ai_related_posts" => {
            "embedding_model" => "nomic-embed-text",
            "summary_enabled" => false
          }
        }
      )
      generator.instance_variable_set(:@site, site)

      fetcher = generator.send(:new_fetcher)

      expect(fetcher).to be_a(JekyllAiRelatedPosts::LmStudioEmbeddings)
      expect(fetcher.instance_variable_get(:@model)).to eq("nomic-embed-text")
    end

    it "raises when embedding_model is missing for LM Studio" do
      generator = described_class.new
      site = instance_double(
        Jekyll::Site,
        config: {
          "ai_related_posts" => {}
        }
      )
      generator.instance_variable_set(:@site, site)

      expect { generator.send(:new_fetcher) }
        .to raise_error(JekyllAiRelatedPosts::Error, /embedding_model/)
    end
  end

  describe "#embedding_dimensions" do
    it "defaults dimensions when not configured" do
      generator = described_class.new
      site = instance_double(
        Jekyll::Site,
        config: {
          "ai_related_posts" => {}
        }
      )
      generator.instance_variable_set(:@site, site)

      expect(generator.send(:embedding_dimensions))
        .to eq(JekyllAiRelatedPosts::LmStudioEmbeddings::DEFAULT_DIMENSIONS)
    end

    it "uses configured dimensions" do
      generator = described_class.new
      site = instance_double(
        Jekyll::Site,
        config: {
          "ai_related_posts" => {
            "embedding_dimensions" => 768
          }
        }
      )
      generator.instance_variable_set(:@site, site)

      expect(generator.send(:embedding_dimensions)).to eq(768)
    end

    it "raises for invalid configured dimensions" do
      generator = described_class.new
      site = instance_double(
        Jekyll::Site,
        config: {
          "ai_related_posts" => {
            "embedding_dimensions" => "abc"
          }
        }
      )
      generator.instance_variable_set(:@site, site)

      expect { generator.send(:embedding_dimensions) }
        .to raise_error(JekyllAiRelatedPosts::Error, /embedding_dimensions/)
    end
  end

  describe "#generate" do
    it "falls back when LM Studio server is unavailable" do
      generator = described_class.new
      posts = [
        double("post_a", relative_path: "post-a.md", data: {}),
        double("post_b", relative_path: "post-b.md", data: {})
      ]
      site = double(
        "site",
        config: {
          "ai_related_posts" => {
            "embedding_model" => "nomic-embed-text",
            "summary_enabled" => false
          }
        },
        posts: double("posts", docs: posts)
      )

      allow(generator).to receive(:setup_database)
      allow(generator).to receive(:ensure_embedding_cached)
        .and_raise(JekyllAiRelatedPosts::LmStudioEmbeddings::ServerUnavailableError, "down")
      allow(generator).to receive(:find_related)
      expect(generator).to receive(:fallback_generate_related).with(posts[0])
      expect(generator).to receive(:fallback_generate_related).with(posts[1])

      expect { generator.generate(site) }.not_to raise_error
    end
  end

  describe "#ensure_embedding_cached with summarization" do
    let(:generator) { described_class.new }
    let(:connection) { instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter) }
    let(:generator_site) do
      instance_double(
        Jekyll::Site,
        config: {
          "ai_related_posts" => {
            "embedding_model" => "nomic-embed-text",
            "summary_enabled" => true,
            "summary_model" => "qwen2.5"
          }
        }
      )
    end
    let(:post) do
      instance_double(
        Jekyll::Document,
        relative_path: "post-a.md",
        content: "Post body content",
        data: {
          "title" => "Test Title",
          "description" => "Front matter description",
          "categories" => [ "Jekyll" ],
          "tags" => [ "Ruby" ]
        }
      )
    end

    before do
      generator.instance_variable_set(:@site, generator_site)
      generator.instance_variable_set(:@stats, { cache_hits: 0, cache_misses: 0 })
      allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
      allow(ActiveRecord::Base).to receive(:sanitize_sql) { |args| args.first }
      allow(connection).to receive(:execute)
    end

    it "passes title, description, summary, categories, and tags to embeddings" do
      summarizer = instance_double(JekyllAiRelatedPosts::LmStudioSummarizer, summarize: "Topics:\n- Test\nAbstract:\nShort abstract.")
      embeddings = instance_double(JekyllAiRelatedPosts::LmStudioEmbeddings)
      generator.instance_variable_set(:@summarizer, summarizer)
      generator.instance_variable_set(:@embeddings_fetcher, embeddings)
      allow(JekyllAiRelatedPosts::Models::Post).to receive(:find_by).and_return(nil)
      allow(JekyllAiRelatedPosts::Models::Post).to receive(:create!)

      expected_input = "Title: Test Title; Description: Front matter description; Summary: Topics:\n" \
                       "- Test\n" \
                       "Abstract:\n" \
                       "Short abstract.; Categories: Jekyll; Tags: Ruby"
      expect(embeddings).to receive(:embedding_for).with(expected_input).and_return([ 0.1, 0.2 ])

      generator.send(:ensure_embedding_cached, post)
    end

    it "reuses cached summary when summary input is unchanged" do
      summary = "Topics:\n- Cached topic\nAbstract:\nCached abstract."
      summary_hash = generator.send(:summary_input_hash, post)
      cached_embedding_text = generator.send(:embedding_text, post, summary: summary)
      existing = double(
        "existing_post",
        summary: summary,
        summary_input_hash: summary_hash,
        embedding_text: cached_embedding_text
      )
      summarizer = instance_double(JekyllAiRelatedPosts::LmStudioSummarizer)
      embeddings = instance_double(JekyllAiRelatedPosts::LmStudioEmbeddings)
      generator.instance_variable_set(:@summarizer, summarizer)
      generator.instance_variable_set(:@embeddings_fetcher, embeddings)
      allow(JekyllAiRelatedPosts::Models::Post).to receive(:find_by).and_return(existing)

      expect(summarizer).not_to receive(:summarize)
      expect(embeddings).not_to receive(:embedding_for)

      generator.send(:ensure_embedding_cached, post)
    end
  end
end
