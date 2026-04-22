# frozen_string_literal: true

require "active_record"
require "sqlite3"
require "sqlite_vss"
require "jekyll"
require "json"
require "digest"

module JekyllAiRelatedPosts
  class Generator < Jekyll::Generator
    def generate(site)
      Jekyll.logger.debug "AI Related Posts:", "Generating related posts..."

      @site = site
      @stats = {
        cache_hits: 0,
        cache_misses: 0
      }
      setup_database

      @indexed_posts = {}
      site.posts.docs.each do |p|
        @indexed_posts[p.relative_path] = p
      end

      if fetch_enabled?
        @embeddings_fetcher = new_fetcher
        @summarizer = new_summarizer if summary_enabled?

        begin
          @site.posts.docs.each do |p|
            ensure_embedding_cached(p)
          end

          @site.posts.docs.each do |p|
            find_related(p)
          end
          Jekyll.logger.info "AI Related Posts:", "Found #{@stats[:cache_hits]} cached embeddings; fetched #{@stats[:cache_misses]}"
        rescue LmStudioEmbeddings::ServerUnavailableError, LmStudioSummarizer::ServerUnavailableError
          Jekyll.logger.warn "AI Related Posts:", "Falling back to cached related posts data because LM Studio is unavailable."

          @site.posts.docs.each do |p|
            fallback_generate_related(p)
          end
        end
      else
        Jekyll.logger.info "AI Related Posts:", "Fetch disabled. Using cached related posts data."

        @site.posts.docs.each do |p|
          fallback_generate_related(p)
        end

        case @stats[:cache_misses]
        when 0
          Jekyll.logger.info "AI Related Posts:", "Found #{@stats[:cache_hits]} cached embeddings; all embeddings cached"
        when 1
          Jekyll.logger.info "AI Related Posts:", "Found #{@stats[:cache_hits]} cached embeddings; skipped 1 fetch"
        else
          Jekyll.logger.info "AI Related Posts:", "Found #{@stats[:cache_hits]} cached embeddings; skipped #{@stats[:cache_misses]} fetches"
        end
      end

      Jekyll.logger.debug "AI Related Posts:", "Done generating related posts"
    end

    private

    def fetch_enabled?
      enabled = true
      if @site.config["ai_related_posts"]["fetch_enabled"].is_a? String
        enabled = ENV["JEKYLL_ENV"] == @site.config["ai_related_posts"]["fetch_enabled"]
      elsif [ true, false ].include? @site.config["ai_related_posts"]["fetch_enabled"]
        enabled = @site.config["ai_related_posts"]["fetch_enabled"]
      end

      enabled
    end

    def fallback_generate_related(post)
      existing = Models::Post.find_by(relative_path: post.relative_path)
      if existing.nil?
        @stats[:cache_misses] += 1
        post.data["ai_related_posts"] = post.related_posts
      else
        if summary_stale?(post, existing)
          @stats[:cache_misses] += 1
        elsif existing.embedding_text == embedding_text(post, summary: existing.summary)
          @stats[:cache_hits] += 1
        else
          @stats[:cache_misses] += 1
        end
        find_related(post)
      end
    end

    def new_fetcher
      case @site.config["ai_related_posts"]["embeddings_source"]
      when "mock"
        MockEmbeddings.new
      else
        model = @site.config["ai_related_posts"]["embedding_model"]
        if model.nil? || model.strip.empty?
          raise JekyllAiRelatedPosts::Error, "Missing required `ai_related_posts.embedding_model` config"
        end

        LmStudioEmbeddings.new(
          model,
          base_url: @site.config["ai_related_posts"]["lm_studio_url"] || LmStudioEmbeddings::DEFAULT_BASE_URL
        )
      end
    end

    def embedding_dimensions
      configured = @site.config["ai_related_posts"]["embedding_dimensions"]
      return LmStudioEmbeddings::DEFAULT_DIMENSIONS if configured.nil?

      dimensions = Integer(configured, exception: false)
      if dimensions.nil?
        raise JekyllAiRelatedPosts::Error, "`ai_related_posts.embedding_dimensions` must be a valid integer"
      end

      if dimensions <= 0
        raise JekyllAiRelatedPosts::Error, "`ai_related_posts.embedding_dimensions` must be a positive integer"
      end

      dimensions
    end

    def summary_enabled?
      enabled = @site.config["ai_related_posts"]["summary_enabled"]
      enabled != false
    end

    def summary_model
      model = @site.config["ai_related_posts"]["summary_model"]
      if model.nil? || model.strip.empty?
        raise JekyllAiRelatedPosts::Error, "Missing required `ai_related_posts.summary_model` config"
      end

      model
    end

    def summary_max_chars
      configured = @site.config["ai_related_posts"]["summary_max_chars"]
      return LmStudioSummarizer::DEFAULT_MAX_CHARS if configured.nil?

      max_chars = Integer(configured, exception: false)
      if max_chars.nil? || max_chars <= 0
        raise JekyllAiRelatedPosts::Error, "`ai_related_posts.summary_max_chars` must be a positive integer"
      end

      max_chars
    end

    def summary_prompt
      @site.config["ai_related_posts"]["summary_prompt"] || LmStudioSummarizer::DEFAULT_PROMPT
    end

    def new_summarizer
      LmStudioSummarizer.new(
        summary_model,
        base_url: @site.config["ai_related_posts"]["lm_studio_url"] || LmStudioEmbeddings::DEFAULT_BASE_URL,
        prompt: summary_prompt,
        max_chars: summary_max_chars
      )
    end

    def summary_source_text(post)
      [
        "Title: #{post.data["title"]}",
        "Description: #{post.data["description"].to_s.strip}",
        "Categories: #{Array(post.data["categories"]).join(", ")}",
        "Tags: #{Array(post.data["tags"]).join(", ")}",
        "Content: #{post.content}",
        "Summary Model: #{summary_model}",
        "Summary Prompt: #{summary_prompt}",
        "Summary Max Chars: #{summary_max_chars}"
      ].join("\n")
    end

    def summary_input_hash(post)
      return nil unless summary_enabled?

      Digest::SHA256.hexdigest(summary_source_text(post))
    end

    def summary_stale?(post, existing)
      return false unless summary_enabled?
      return true if existing.summary.to_s.strip.empty?

      existing.summary_input_hash != summary_input_hash(post)
    end

    def summary_for(post, existing)
      return [ nil, nil ] unless summary_enabled?

      input_hash = summary_input_hash(post)
      if !existing.nil? && existing.summary_input_hash == input_hash && !existing.summary.to_s.strip.empty?
        return [ existing.summary, input_hash ]
      end

      Jekyll.logger.info "AI Related Posts:", "Fetching summary for #{post.relative_path}"
      summary = @summarizer.summarize(post.content.to_s)
      [ summary, input_hash ]
    end

    def ensure_embedding_cached(post)
      existing = Models::Post.find_by(relative_path: post.relative_path)
      summary, summary_hash = summary_for(post, existing)
      input = embedding_text(post, summary: summary)

      # Clear cache if post has been updated
      if !existing.nil? && existing.embedding_text != input
        sql = "DELETE FROM vss_posts WHERE rowid = (SELECT rowid FROM posts WHERE relative_path = :relative_path);"
        ActiveRecord::Base.connection.execute(ActiveRecord::Base.sanitize_sql([ sql,
                                                                               { relative_path: post.relative_path } ]))
        existing.destroy!
        existing = nil
      end

      if existing.nil?
        @stats[:cache_misses] += 1

        Models::Post.create!(
          relative_path: post.relative_path,
          embedding_text: input,
          embedding: embedding_for(post, input).to_json,
          summary: summary,
          summary_input_hash: summary_hash
        )

        sql = <<-SQL
            INSERT INTO vss_posts (rowid, post_embedding)
              SELECT rowid, embedding FROM posts WHERE relative_path = :relative_path;
        SQL
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql([ sql, { relative_path: post.relative_path } ])
        )
      else
        @stats[:cache_hits] += 1
      end
    end

    def find_related(post)
      sql = <<-SQL
        SELECT rowid, distance
        FROM vss_posts
        WHERE vss_search(
          post_embedding,
          (select embedding from posts where relative_path = :relative_path)
        )
        LIMIT 10000;
      SQL

      results = ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql([ sql, { relative_path: post.relative_path } ])
      )
      # The first result is the post itself, with a distance of 0.
      rowids = results.sort_by { |r| r["distance"] }.drop(1).first(10).map { |r| r["rowid"] }

      posts_by_rowid = {}
      rowids.each do |rowid|
        # This *is* an N+1 query, but:
        #  - N+1 penalty is way less with SQLite
        #  - N is relatively small (it's Jekyll post count)
        #  - This is an easy way to work around rowid not being a real column that ActiveRecord knows about.
        posts_by_rowid[rowid] = Models::Post.select(:relative_path).find_by(rowid: rowid)
      end

      related_posts = rowids.map do |rowid|
        relative_path = posts_by_rowid[rowid]["relative_path"]
        @indexed_posts[relative_path]
      end

      post.data["ai_related_posts"] = related_posts
    end

    def embedding_text(post, summary: nil)
      text = "Title: #{post.data["title"]}"
      description = post.data["description"].to_s.strip
      text += "; Description: #{description}" unless description.empty?
      summary_text = summary.to_s.strip
      text += "; Summary: #{summary_text}" unless summary_text.empty?
      categories = Array(post.data["categories"])
      text += "; Categories: #{categories.join(", ")}" unless categories.empty?
      tags = Array(post.data["tags"])
      text += "; Tags: #{tags.join(", ")}" unless tags.empty?

      text
    end

    def embedding_for(post, input = nil)
      Jekyll.logger.info "AI Related Posts:", "Fetching embedding for #{post.relative_path}"
      input ||= embedding_text(post)

      @embeddings_fetcher.embedding_for(input)
    end

    def setup_database
      db_path = @site.in_source_dir(".ai_related_posts_cache.sqlite3")
      if File.exist?(db_path)
        Jekyll.logger.debug "AI Related Posts:", "Found cache [.ai_related_posts_cache.sqlite3]"
      else
        Jekyll.logger.info "AI Related Posts:", "Creating cache [.ai_related_posts_cache.sqlite3]"
      end

      ActiveRecord::Base.establish_connection(
        adapter: "sqlite3",
        database: db_path
      )
      # We don't need WAL mode for this.
      ActiveRecord::Base.connection.execute("PRAGMA journal_mode=DELETE;")

      # Enable sqlite-vss vector extension
      db = ActiveRecord::Base.connection.raw_connection
      db.enable_load_extension(true)
      SqliteVss.load(db)
      db.enable_load_extension(false)

      create_posts = <<-SQL
        CREATE TABLE IF NOT EXISTS posts(
          relative_path TEXT PRIMARY KEY,
          embedding_text TEXT,
          embedding TEXT,
          summary TEXT,
          summary_input_hash TEXT
        );
      SQL
      ActiveRecord::Base.connection.execute(create_posts)
      migrate_posts_table_columns!

      create_vss_posts = <<-SQL
        CREATE VIRTUAL TABLE IF NOT EXISTS vss_posts using vss0(
          post_embedding(#{embedding_dimensions})
        );
      SQL
      ActiveRecord::Base.connection.execute(create_vss_posts)

      Jekyll.logger.debug "AI Related Posts:", "DB setup complete"
    end

    def migrate_posts_table_columns!
      columns = ActiveRecord::Base.connection.execute("PRAGMA table_info(posts);")
      column_names = columns.map { |c| c["name"] || c[1] }

      unless column_names.include?("summary")
        ActiveRecord::Base.connection.execute("ALTER TABLE posts ADD COLUMN summary TEXT;")
      end

      unless column_names.include?("summary_input_hash")
        ActiveRecord::Base.connection.execute("ALTER TABLE posts ADD COLUMN summary_input_hash TEXT;")
      end
    end
  end
end
