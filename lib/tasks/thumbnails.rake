# frozen_string_literal: true

namespace :sfei do
  namespace :images do
    desc "Pre-process and cache (hydrate) all Active Storage thumbnail variants"
    task prewarm: :environment do
      puts "Pre-warming thumbnail variants..."
      count = 0
      SolrDocumentSidecar.find_each do |sidecar|
        next unless sidecar.image.attached?

        # List page square variant (300x300 for retina clarity)
        sidecar.image.variant(resize_to_fit: [300, 300]).processed
        # Detail page sidebar variant
        sidecar.image.variant(resize_to_fit: [400, 400]).processed
        count += 1
        print "."
      end
      puts "\nSuccessfully pre-warmed thumbnail variants for #{count} documents."
    end
  end
end
