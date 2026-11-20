# frozen_string_literal: true

require "test_helper"

class SmokeTest < ActionDispatch::IntegrationTest
  test "health check endpoint responds with 200 OK" do
    get rails_health_check_path
    assert_response :success
  end

  test "root catalog page renders successfully with search elements" do
    get root_path
    assert_response :success
    assert_select "title"
    assert_select "form.search-query-form, form[role='search']"
  end

  test "devise user sign in page renders login form" do
    get new_user_session_path
    assert_response :success
    assert_select "form"
    assert_select "input[type='email']"
    assert_select "input[type='password']"
  end

  test "web app manifest endpoint returns valid json" do
    get pwa_manifest_path(format: :json)
    assert_response :success
    json = JSON.parse(response.body)
    assert_not_nil json["name"]
  end
end
