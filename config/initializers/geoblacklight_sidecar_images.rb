# frozen_string_literal: true

# Configure GeoblacklightSidecarImages to support local images from public/images/
# as well as remote URLs, and extend SolrDocumentSidecar with multiple-image attachments.
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
        local_path = Rails.root.join("public", "images", safe_filename)
        if File.exist?(local_path)
          @metadata["local_thumbnail_path"] = local_path.to_s
          @metadata["local_image_path"] = local_path.to_s
          return File.open(local_path, "rb")
        end
      end

      super
    end
  end)

  # Extend SolrDocumentSidecar with multi-image support and variant prewarming
  SolrDocumentSidecar.class_eval do
    has_many_attached :images

    after_commit :prewarm_variants, on: [ :create, :update ]

    # Primary image attachment used for search thumbnails and detail sidebar
    def primary_image
      if images.attached? && images.any?
        images.first
      elsif image.attached?
        image
      end
    end

    # Ordered array of all attached images
    def all_images
      if images.attached? && images.any?
        images.to_a
      elsif image.attached?
        [ image ]
      else
        []
      end
    end

    def prewarm_variants
      # Pre-generate list page square thumbnail and detail page sidebar thumbnail for primary image
      if image.attached?
        image.variant(resize_to_fit: [ 300, 300 ]).processed
        image.variant(resize_to_fit: [ 400, 400 ]).processed
      end

      # Pre-warm variants across all attached images in the images collection
      if images.attached?
        images.each_with_index do |img, idx|
          if idx == 0
            img.variant(resize_to_fit: [ 300, 300 ]).processed
            img.variant(resize_to_fit: [ 400, 400 ]).processed
          end
          # Lightbox variant (1200x1200 max)
          img.variant(resize_to_fit: [ 1200, 1200 ]).processed
        end
      end
    rescue StandardError => e
      Rails.logger.warn("Failed to prewarm image variants for #{document_id}: #{e.message}")
    end
  end
end
