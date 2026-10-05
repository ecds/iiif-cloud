require 'aws-sdk-s3'

module Ecds
  module Iip
    def self.process(id)
      resource = Resource.find(id)
      return unless resource.image?

      # Only convert if there is content attached
      content = resource.content_converted
      return unless content.attached?

      s3 = Aws::S3::Resource.new(
        client: Aws::S3::Client.new(region: 'us-east-1')
      )

      destination_bucket = s3.bucket('ecds-iiif')

      content.open do |file|
        begin
          # Convert the image
          tmp_file = Tempfile.new
          image = Vips::Image.new_from_buffer(URI.open(content.url) { |f| f.read }, '')
          image.tiffsave(
            tmp_file.path,
            pyramid: true,
            tile: true,
            tile_width: 256,
            tile_height: 256,
            compression: image.has_alpha? ? :lzw : :deflate
          )

          destination_bucket.put_object(
            key: File.join('images', *@prefix, content .attachment.key),
            body: File.read(tmp_file.path)
          )

          File.delete(tmp_file.path)

        rescue => e
          # Content cannot be converted
          Rails.logger.error e.message
          Rails.logger.error e.backtrace.join("\n")
        end
      end

    end
  end
end