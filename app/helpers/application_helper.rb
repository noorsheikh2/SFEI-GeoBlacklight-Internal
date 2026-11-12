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
    return unless doc.respond_to?(:sidecar) && doc.sidecar&.image&.attached?

    modal_id = "show-image-lightbox-#{doc.id.to_s.parameterize}"

    content_tag(:div, class: "my-2") do
      thumbnail = link_to("#", data: { bs_toggle: "modal", bs_target: "##{modal_id}" }, title: "Click to enlarge image") do
        sidecar_thumbnail_tag(doc, size: [400, 400], class: "img-fluid img-thumbnail rounded shadow-sm", style: "max-height: 250px; width: auto; object-fit: contain; cursor: pointer;", alt: doc.title)
      end

      caption = content_tag(:div, class: "small text-muted mt-1", style: "cursor: pointer;", data: { bs_toggle: "modal", bs_target: "##{modal_id}" }) do
        raw('<svg xmlns="http://www.w3.org/2000/svg" width="13" height="13" fill="currentColor" class="me-1" viewBox="0 0 16 16"><path fill-rule="evenodd" d="M6.5 12a5.5 5.5 0 1 0 0-11 5.5 5.5 0 0 0 0 11M13 6.5a6.5 6.5 0 1 1-13 0 6.5 6.5 0 0 1 13 0"/><path d="M10.344 11.742q.044.06.098.115l3.85 3.85a1 1 0 0 0 1.415-1.414l-3.85-3.85a1 1 0 0 0-.115-.1 6.5 6.5 0 0 1-1.398 1.4z"/><path fill-rule="evenodd" d="M6.5 3a.5.5 0 0 1 .5.5V6h2.5a.5.5 0 0 1 0 1H7v2.5a.5.5 0 0 1-1 0V7H3.5a.5.5 0 0 1 0-1H6V3.5a.5.5 0 0 1 .5-.5"/></svg>Click to enlarge')
      end

      modal = content_tag(:div, class: "modal fade", id: modal_id, tabindex: "-1", aria: { labelledby: "#{modal_id}-title", hidden: "true" }) do
        content_tag(:div, class: "modal-dialog modal-dialog-centered modal-xl") do
          content_tag(:div, class: "modal-content") do
            header = content_tag(:div, class: "modal-header") do
              content_tag(:h5, doc.title, class: "modal-title", id: "#{modal_id}-title") +
                button_tag("", type: "button", class: "btn-close", data: { bs_dismiss: "modal" }, aria: { label: "Close" })
            end
            body = content_tag(:div, class: "modal-body text-center p-3 bg-dark") do
              image_tag(doc.sidecar.image, class: "img-fluid rounded", style: "max-height: 80vh; max-width: 100%; object-fit: contain;", alt: doc.title)
            end
            header + body
          end
        end
      end

      thumbnail + caption + modal
    end
  end
end
