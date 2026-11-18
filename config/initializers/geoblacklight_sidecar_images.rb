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

  # Automatically pre-warm and cache thumbnail variants whenever an image is attached/harvested
  SolrDocumentSidecar.class_eval do
    after_commit :prewarm_variants, on: [ :create, :update ]

    def prewarm_variants
      return unless image.attached?

      # Pre-generate list page square thumbnail (300x300 for retina clarity)
      image.variant(resize_to_fit: [ 300, 300 ]).processed
      # Pre-generate detail page sidebar thumbnail
      image.variant(resize_to_fit: [ 400, 400 ]).processed
    rescue StandardError => e
      Rails.logger.warn("Failed to prewarm image variants for #{document_id}: #{e.message}")
    end
  end
end
