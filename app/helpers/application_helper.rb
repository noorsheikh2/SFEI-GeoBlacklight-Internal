# frozen_string_literal: true

module ApplicationHelper
  # Renders the sidecar image thumbnail with a clickable lightbox modal
  # as a metadata row on the document show page.
  def render_sidecar_image_show(options = {}, *args, **kwargs)
    doc = if options.is_a?(Hash) && options[:document]
      options[:document]
    else
      kwargs[:document]
    end
    sidecar = doc.respond_to?(:sidecar) ? doc.sidecar : nil
    primary = sidecar&.primary_image
    return unless primary.present?

    all_imgs = sidecar&.all_images || []
    has_multiple = all_imgs.size > 1
    modal_id = "show-image-lightbox-#{doc.id.to_s.parameterize}"

    content_tag(:div, class: "my-2") do
      thumbnail = link_to("#", data: { bs_toggle: "modal", bs_target: "##{modal_id}" }, title: "Click to enlarge image") do
        image_tag(primary.variant(resize_to_fit: [ 400, 400 ]), class: "img-fluid img-thumbnail rounded shadow-sm", style: "max-height: 250px; width: auto; object-fit: contain; cursor: pointer;", alt: doc.title)
      end

      caption_text = has_multiple ? "Click to enlarge (#{all_imgs.size} images)" : "Click to enlarge"
      caption = content_tag(:div, class: "small text-muted mt-1", style: "cursor: pointer;", data: { bs_toggle: "modal", bs_target: "##{modal_id}" }) do
        raw('<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" fill="currentColor" class="me-1" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M6.5 12a5.5 5.5 0 1 0 0-11 5.5 5.5 0 0 0 0 11M13 6.5a6.5 6.5 0 1 1-13 0 6.5 6.5 0 0 1 13 0"/><path d="M10.344 11.742q.044.06.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1 1 0 0 0-.115-.1 6.5 6.5 0 0 1-1.398 1.4z"/><path fill-rule="evenodd" d="M6.5 3a.5.5 0 0 1 .5.5V6h2.5a.5.5 0 0 1 0 1H7v2.5a.5.5 0 0 1-1 0V7H3.5a.5.5 0 0 1 0-1H6V3.5a.5.5 0 0 1 .5-.5"/></svg>') + caption_text
      end

      modal = content_tag(:div, class: "modal fade", id: modal_id, tabindex: "-1", aria: { labelledby: "#{modal_id}-title", hidden: "true" }, data: { controller: "lightbox-carousel" }) do
        content_tag(:div, class: "modal-dialog modal-dialog-centered modal-xl") do
          content_tag(:div, class: "modal-content") do
            header = content_tag(:div, class: "modal-header") do
              counter_badge = if has_multiple
                content_tag(:span, "Image 1 of #{all_imgs.size}", class: "badge bg-secondary me-2 text-nowrap", data: { lightbox_carousel_target: "counter" })
              else
                "".html_safe
              end

              full_size_link = link_to(rails_blob_path(primary, disposition: "inline"), target: "_blank", rel: "noopener", class: "btn btn-sm btn-outline-secondary me-2 text-nowrap", data: { lightbox_carousel_target: "fullSizeLink" }, title: "Open full-resolution image in new tab") do
                raw('<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" fill="currentColor" class="me-1" viewBox="0 0 16 16" aria-hidden="true"><path fill-rule="evenodd" d="M8.636 3.5a.5.5 0 0 0-.5-.5H1.5A1.5 1.5 0 0 0 0 4.5v10A1.5 1.5 0 0 0 1.5 16h10a1.5 1.5 0 0 0 1.5-1.5V7.864a.5.5 0 0 0-1 0V14.5a.5.5 0 0 1-.5.5h-10a.5.5 0 0 1-.5-.5v-10a.5.5 0 0 1 .5-.5h6.636a.5.5 0 0 0 .5-.5"/><path fill-rule="evenodd" d="M16 .5a.5.5 0 0 0-.5-.5h-5a.5.5 0 0 0 0 1h3.793L6.146 9.146a.5.5 0 1 0 .708.708L15 1.707V5.5a.5.5 0 0 0 1 0z"/></svg>Open full size')
              end

              content_tag(:h5, doc.title, class: "modal-title text-truncate me-2", id: "#{modal_id}-title") +
                content_tag(:div, class: "d-flex align-items-center ms-auto") do
                  counter_badge + full_size_link + button_tag("", type: "button", class: "btn-close", data: { bs_dismiss: "modal" }, aria: { label: "Close" })
                end
            end

            body = content_tag(:div, class: "modal-body text-center p-3 bg-dark") do
              if has_multiple
                carousel_id = "#{modal_id}-carousel"
                indicators = content_tag(:div, class: "carousel-indicators mb-0", style: "bottom: -20px;") do
                  all_imgs.map.with_index do |_img, idx|
                    button_tag("", type: "button", data: { bs_target: "##{carousel_id}", bs_slide_to: idx }, class: (idx.zero? ? "active" : ""), aria: { current: (idx.zero? ? "true" : nil), label: "Slide #{idx + 1}" })
                  end.join.html_safe
                end

                items = content_tag(:div, class: "carousel-inner pb-4") do
                  all_imgs.map.with_index do |img, idx|
                    full_url = rails_blob_path(img, disposition: "inline")
                    content_tag(:div, class: "carousel-item #{'active' if idx.zero?}", data: { slide_index: idx + 1, total_slides: all_imgs.size, full_url: full_url }) do
                      image_tag(img.variant(resize_to_fit: [ 1200, 1200 ]), class: "img-fluid rounded mx-auto d-block", style: "max-height: 75vh; max-width: 100%; object-fit: contain;", alt: "#{doc.title} - Image #{idx + 1}")
                    end
                  end.join.html_safe
                end

                prev_btn = button_tag(class: "carousel-control-prev", type: "button", data: { bs_target: "##{carousel_id}", bs_slide: "prev" }, aria: { label: "Previous" }) do
                  raw('<span class="carousel-control-prev-icon" aria-hidden="true"></span><span class="visually-hidden">Previous</span>')
                end
                next_btn = button_tag(class: "carousel-control-next", type: "button", data: { bs_target: "##{carousel_id}", bs_slide: "next" }, aria: { label: "Next" }) do
                  raw('<span class="carousel-control-next-icon" aria-hidden="true"></span><span class="visually-hidden">Next</span>')
                end

                content_tag(:div, id: carousel_id, class: "carousel slide", data: { bs_interval: "false", bs_keyboard: "true" }, tabindex: "0") do
                  indicators + items + prev_btn + next_btn
                end
              else
                image_tag(primary, class: "img-fluid rounded", style: "max-height: 80vh; max-width: 100%; object-fit: contain;", alt: doc.title)
              end
            end
            header + body
          end
        end
      end

      thumbnail + caption + modal
    end
  end
end
