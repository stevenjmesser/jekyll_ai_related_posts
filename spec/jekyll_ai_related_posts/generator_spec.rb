# frozen_string_literal: true

require "debug"
require "ostruct"

RSpec.describe JekyllAiRelatedPosts::Generator do
  let(:config_overrides) do
    {
      "ai_related_posts" => {
        "openai_api_key" => "my_key",
        "embeddings_source" => "mock"
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
          "fetch_enabled" => false
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
            "embedding_model" => "nomic-embed-text"
          }
        }
      )
      generator.instance_variable_set(:@site, site)

      fetcher = generator.send(:new_fetcher)

      expect(fetcher).to be_a(JekyllAiRelatedPosts::LmStudioEmbeddings)
      expect(fetcher.instance_variable_get(:@model)).to eq("nomic-embed-text")
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
            "embedding_model" => "nomic-embed-text"
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
end
