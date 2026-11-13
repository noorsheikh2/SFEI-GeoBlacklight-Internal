# frozen_string_literal: true

require "test_helper"

class SolrDocumentSidecarTest < ActiveSupport::TestCase
  def setup
    @sidecar = SolrDocumentSidecar.create!(
      document_id: "sfei-test-doc-1",
      document_type: "SolrDocument",
      version: 12345
    )
  end

  def teardown
    @sidecar&.destroy
    FileUtils.rm_f(Rails.root.join("public", "thumbnails", "unit_test_img.png"))
  end

  test "creates sidecar with expected attributes" do
    assert_equal "sfei-test-doc-1", @sidecar.document_id
    assert_equal "SolrDocument", @sidecar.document_type.to_s
    assert_equal 12345, @sidecar.version
  end

  test "supports ActiveStorage image attachment" do
    assert_not @sidecar.image.attached?

    @sidecar.image.attach(
      io: StringIO.new("fake-image-bytes-png"),
      filename: "test.png",
      content_type: "image/png"
    )

    assert @sidecar.image.attached?
    assert_equal "test.png", @sidecar.image.filename.to_s
    assert_equal "image/png", @sidecar.image.content_type
  end

  test "tracks image states with state machine" do
    assert_includes %w[unprocessed initialized], @sidecar.image_state.current_state.to_s

    @sidecar.image_state.transition_to!(:queued, { "job" => "test" })
    assert_equal "queued", @sidecar.image_state.current_state

    @sidecar.image_state.transition_to!(:processing)
    assert_equal "processing", @sidecar.image_state.current_state

    @sidecar.image_state.transition_to!(:succeeded)
    assert_equal "succeeded", @sidecar.image_state.current_state
  end

  test "resolves local thumbnail from public/thumbnails when sfei_image_name_s matches" do
    test_file_path = Rails.root.join("public", "thumbnails", "unit_test_img.png")
    File.write(test_file_path, "PNG_TEST_CONTENT")

    doc = SolrDocument.new(
      id: "sfei-test-doc-1",
      Settings.GBLSI_THUMBNAIL_FIELD => "unit_test_img.png"
    )

    service = GeoblacklightSidecarImages::ImageService.new(doc)
    tempfile = service.send(:image_tempfile, doc.id)

    assert_not_nil tempfile
    assert_equal "PNG_TEST_CONTENT", tempfile.read
    assert_equal test_file_path.to_s, service.instance_variable_get(:@metadata)["local_thumbnail_path"]
  ensure
    tempfile&.close
    FileUtils.rm_f(test_file_path) if test_file_path
  end

  test "sanitizes thumbnail filename and prevents path traversal" do
    # Create a secret test file outside public/thumbnails
    secret_path = Rails.root.join("tmp", "secret_test_file.txt")
    File.write(secret_path, "SECRET_DATA")

    # Attempt directory traversal pointing to secret_path
    traversal_filename = "../../tmp/secret_test_file.txt"
    doc = SolrDocument.new(
      id: "sfei-test-traversal",
      Settings.GBLSI_THUMBNAIL_FIELD => traversal_filename
    )

    service = GeoblacklightSidecarImages::ImageService.new(doc)
    # image_tempfile should NOT return the secret file outside public/thumbnails
    file_or_nil = service.send(:image_tempfile, doc.id)

    # It must not read the secret outside public/thumbnails
    resolved_path = service.instance_variable_get(:@metadata)["local_thumbnail_path"]
    assert_nil resolved_path
  ensure
    file_or_nil&.close if file_or_nil.respond_to?(:close)
    FileUtils.rm_f(secret_path) if secret_path
  end

  test "falls back to placeholder when local thumbnail does not exist" do
    doc = SolrDocument.new(
      id: "sfei-test-missing",
      Settings.GBLSI_THUMBNAIL_FIELD => "non_existent_image_12345.png"
    )

    service = GeoblacklightSidecarImages::ImageService.new(doc)
    result = service.send(:image_tempfile, doc.id)

    assert_nil result
    assert service.instance_variable_get(:@metadata)["placeheld"]
  end
end
