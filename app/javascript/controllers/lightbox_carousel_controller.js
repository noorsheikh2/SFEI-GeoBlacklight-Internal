import { Controller } from "@hotwired/stimulus"

// Connects to data-controller="lightbox-carousel"
export default class extends Controller {
  static targets = ["counter", "fullSizeLink"]

  connect() {
    this.boundOnSlid = this.onSlid.bind(this)
    this.element.addEventListener("slid.bs.carousel", this.boundOnSlid)

    // Focus carousel when modal opens so keyboard arrow keys work immediately
    this.boundOnShown = this.onShown.bind(this)
    this.element.addEventListener("shown.bs.modal", this.boundOnShown)
  }

  disconnect() {
    this.element.removeEventListener("slid.bs.carousel", this.boundOnSlid)
    this.element.removeEventListener("shown.bs.modal", this.boundOnShown)
  }

  onShown() {
    const carouselEl = this.element.querySelector(".carousel")
    if (carouselEl) {
      carouselEl.focus()
    }
  }

  onSlid(event) {
    const activeItem = event.relatedTarget
    if (!activeItem) return

    const slideIndex = activeItem.dataset.slideIndex
    const totalSlides = activeItem.dataset.totalSlides
    const fullUrl = activeItem.dataset.fullUrl

    if (this.hasCounterTarget && slideIndex && totalSlides) {
      this.counterTarget.textContent = `Image ${slideIndex} of ${totalSlides}`
    }

    if (this.hasFullSizeLinkTarget && fullUrl) {
      this.fullSizeLinkTarget.href = fullUrl
    }
  }
}
