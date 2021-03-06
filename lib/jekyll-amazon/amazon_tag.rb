# coding: utf-8
require 'amazon/ecs'
require 'singleton'

module Jekyll
  module Amazon
    class AmazonResultCache
      include Singleton

      CACHE_DIR = '.amazon-cache/'.freeze

      ITEM_HASH = {
        asin:             'ASIN',
        salesrank:        'SalesRank',
        title:            'ItemAttributes/Title',
        author:           'ItemAttributes/Author',
        publisher:        'ItemAttributes/Manufacturer',
        publication_date: 'ItemAttributes/PublicationDate',
        release_date:     'ItemAttributes/ReleaseDate',
        detail_page_url:  'DetailPageURL',
        small_image_url:  'SmallImage/URL',
        medium_image_url: 'MediumImage/URL',
        large_image_url:  'LargeImage/URL'
      }.freeze

      ECS_ASSOCIATE_TAG = ENV['ECS_ASSOCIATE_TAG'] || ''
      AWS_ACCESS_KEY_ID = ENV['AWS_ACCESS_KEY'] || ''
      AWS_SECRET_KEY = ENV['AWS_SECRET_KEY'] || ''

      raise 'AWS_ACCESS_KEY_ID env variable is not set' if AWS_ACCESS_KEY_ID.empty?
      raise 'AWS_SECRET_KEY env variable is not set' if AWS_SECRET_KEY.empty?
      raise 'ECS_ASSOCIATE_TAG env variable is not set' if ECS_ASSOCIATE_TAG.empty?

      def initialize
        @result_cache = {}
        FileUtils.mkdir_p(CACHE_DIR)
      end

      def setup(context)
        context.registers[:site]
        # ::Amazon::Ecs.debug = true
        ::Amazon::Ecs.configure do |options|
          options[:associate_tag]     = ECS_ASSOCIATE_TAG
          options[:AWS_access_key_id] = AWS_ACCESS_KEY_ID
          options[:AWS_secret_key]    = AWS_SECRET_KEY
          options[:response_group]    = 'SalesRank,Images,ItemAttributes'
          options[:country]           = ENV['ECS_COUNTRY'] || 'jp'
        end
      end

      def item_lookup(asin)
        return @result_cache[asin] if @result_cache.key?(asin)
        return read_cache(asin) if read_cache(asin)

        retry_api do
          res = ::Amazon::Ecs.item_lookup(asin)
          item = res.first_item
          data = create_data(item)
          write_cache(asin, data)
          @result_cache[asin] = data
          @result_cache[asin]
        end
      end

      private

      def read_cache(asin)
        path = File.join(CACHE_DIR, asin)
        return nil unless File.exist?(path)
        File.open(path, 'r') { |f| Marshal.load(f.read) }
      end

      def write_cache(asin, obj)
        path = File.join(CACHE_DIR, asin)
        File.open(path, 'w') { |f| f.write(Marshal.dump(obj)) }
      end

      def retry_api
        yield
      rescue
        retry_count ||= 0
        retry_count += 1
        sleep retry_count
        retry if retry_count <= 5
        raise
      end

      def create_data(item)
        ITEM_HASH.each_with_object({}) do |(key, value), hash|
          hash[key] = item.get(value).to_s
        end
      end
    end

    class AmazonTag < Liquid::Tag
      attr_accessor :asin
      attr_accessor :template_type

      def initialize(tag_name, markup, tokens)
        super
        parse_options(markup)
        if asin.nil? || asin.empty?
          raise SyntaxError, "No ASIN given in #{tag_name} tag"
        end
      end

      def render(context)
        type = template_type || :detail
        AmazonResultCache.instance.setup(context)
        item = AmazonResultCache.instance.item_lookup(asin.to_s)
        return unless item
        send(type, item)
      end

      private

      def parse_options(markup)
        options = (markup || '').split(' ').map(&:strip)
        self.asin = options.shift
        self.template_type = options.shift || :title
      end

      def title(item)
        url   = item[:detail_page_url]
        title = item[:title]
        format(%(<a href="%s" target="_blank">%s</a>), url, title)
      end

      def image(item)
        url       = item[:detail_page_url]
        title     = item[:title]
        image_url = item[:medium_image_url]
        str = <<-"EOS"
<a href="#{url}" target="_blank">
  <img src="#{image_url}" alt="#{title}" />
</a>
  EOS
        str.to_s
      end

      def detail(item)
        author    = item[:author]
        publisher = item[:publisher]
        date      = item[:publication_date] || item[:release_date]
        salesrank = item[:salesrank]
        str = <<-"EOS"
<div class="jk-amazon-item">
  <div class="jk-amazon-image">
    #{image(item)}
  </div>
  <div class="jk-amazon-info">
    <div class="jk-amazon-info-title">
      #{title(item)}
    </div>
    <div class="jk-amazon-info-author">
      #{labeled("Author: ", author)}
    </div>
    <div class="jk-amazon-info-publisher">
      #{labeled("Publisher: ", publisher)}
    </div>
    <div class="jk-amazon-info-date">
      #{labeled("Date: ", date)}
    </div>
    <div class="jk-amazon-info-salesrank">
      #{labeled("Sales Rank: ", salesrank)}
    </div>
  </div>
</div>
  EOS
        str.to_s
      end

      def labeled(label, value)
        return "" if value.nil? || value.empty?
        "<span class=\"amazon-info-label\">#{label} </span>#{value}"
      end
    end
  end
end

Liquid::Template.register_tag('amazon', Jekyll::Amazon::AmazonTag)
