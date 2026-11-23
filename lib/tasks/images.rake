# frozen_string_literal: true

namespace :sfei do
  namespace :images do
    desc "Harvest and attach all dataset images from public/images/ based on Solr metadata"
    task harvest_all: :environment do
      puts "Harvesting dataset images from public/images/..."
      solr = Blacklight.default_index.connection

      # Query all documents from Solr
      response = solr.get("select", params: { q: "*:*", rows: 1000, fl: "id,sfei_image_name_s,sfei_image_names_sm" })
      docs = response.dig("response", "docs") || []
      puts "Found #{docs.size} documents in Solr to inspect."

      updated_count = 0
      skipped_count = 0
      missing_files = []

      docs.each do |doc|
        doc_id = doc["id"]
        # Extract ordered image filenames
        image_names = doc["sfei_image_names_sm"]
        if image_names.blank? && doc["sfei_image_name_s"].present?
          image_names = [ doc["sfei_image_name_s"] ]
        end
        target_filenames = Array(image_names).map { |f| File.basename(f.to_s.strip) }.reject(&:blank?)

        sidecar = SolrDocumentSidecar.find_or_create_by!(
          document_id: doc_id,
          document_type: "SolrDocument"
        )

        current_filenames = sidecar.images.attached? ? sidecar.images.map { |a| a.filename.to_s } : []

        # If already attached and filenames match exactly, skip re-attaching
        if current_filenames == target_filenames && (!target_filenames.any? || sidecar.image.attached?)
          skipped_count += 1
          next
        end

        # User requirement: automatically replace attachments on re-sync so carousel matches sheet
        sidecar.images.purge if sidecar.images.attached?
        sidecar.image.purge if sidecar.image.attached?

        attached_count = 0
        target_filenames.each do |filename|
          file_path = Rails.root.join("public", "images", filename)
          if File.exist?(file_path)
            content_type = Marcel::MimeType.for(Pathname.new(file_path)) || "image/png"
            File.open(file_path, "rb") do |file|
              sidecar.images.attach(
                io: file,
                filename: filename,
                content_type: content_type
              )
            end
            attached_count += 1
          else
            missing_files << "#{doc_id}: #{filename}"
          end
        end

        # Attach first image to sidecar.image for upstream gem compatibility
        if sidecar.images.attached? && sidecar.images.any?
          first_blob = sidecar.images.first.blob
          sidecar.image.attach(first_blob)
          if sidecar.respond_to?(:image_state) && sidecar.image_state.can_transition_to?(:succeeded)
            sidecar.image_state.transition_to!(:succeeded)
          end
        end

        sidecar.prewarm_variants
        updated_count += 1
        print "."
      end

      puts "\nFinished image harvest:"
      puts "  Updated / attached: #{updated_count} documents"
      puts "  Already up to date: #{skipped_count} documents"
      if missing_files.any?
        puts "  Missing files on disk (#{missing_files.size}):"
        missing_files.first(10).each { |m| puts "    - #{m}" }
        puts "    ... (truncated)" if missing_files.size > 10
      end
    end

    desc "Pre-process and cache (hydrate) all Active Storage image variants"
    task prewarm: :environment do
      puts "Pre-warming image variants..."
      count = 0
      SolrDocumentSidecar.find_each do |sidecar|
        next unless sidecar.images.attached? || sidecar.image.attached?

        sidecar.prewarm_variants
        count += 1
        print "."
      end
      puts "\nSuccessfully pre-warmed image variants for #{count} documents."
    end
  end
end
