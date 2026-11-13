# frozen_string_literal: true

# Configure GeoblacklightSidecarImages to support local images from public/thumbnails/
# as well as remote URLs.
Rails.application.config.to_prepare do
  # Bridge for Geoblacklight::SolrDocument.find called by StoreImageJob
  module Geoblacklight
    module SolrDocument
      def self.find(id)
        ::SolrDocument.find(id)
      end
    end
  end

  GeoblacklightSidecarImages::ImageService.prepend(Module.new do
    def image_tempfile(document_id)
      filename = gblsi_thumbnail_uri
      if filename.present? && !filename.to_s.start_with?("http://", "https://")
        # Sanitize filename to prevent directory traversal
        safe_filename = File.basename(filename.to_s)
        local_path = Rails.root.join("public", "thumbnails", safe_filename)
        if File.exist?(local_path)
          @metadata["local_thumbnail_path"] = local_path.to_s
          return File.open(local_path, "rb")
        end
      end

      super
    end
  end)
end
