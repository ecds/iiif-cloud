require "test_helper"

class PublicResourcesTranscriptTest < ActionDispatch::IntegrationTest
  VTT = "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.500\nHello\n".freeze

  setup do
    @resource = Resource.create!(project: projects(:one), name: "Interview", storage_key: SecureRandom.uuid)
    @resource.content.attach(io: StringIO.new("audio"), filename: "interview.mp3", content_type: "audio/mpeg")
    @resource.update_columns(transcript_status: "succeeded", transcript_identifier: @resource.content.key)

    service = ActiveStorage::Blob.service
    service.upload(Transcripts.key(@resource, "vtt"), StringIO.new(VTT))
    service.upload(Transcripts.key(@resource, "json"), StringIO.new('{"results":{}}'))
  end

  test "serves the WebVTT transcript without authentication" do
    get "/public/resources/#{@resource.uuid}/transcript.vtt"

    assert_response :ok
    assert_equal "text/vtt", response.media_type
    assert_equal VTT, response.body
  end

  test "serves the full JSON transcript" do
    get "/public/resources/#{@resource.uuid}/transcript.json"

    assert_response :ok
    assert_equal "application/json", response.media_type
  end

  test "returns not found for other files" do
    get "/public/resources/#{@resource.uuid}/transcript.txt"

    assert_response :not_found
  end

  test "returns not found without a transcript" do
    @resource.update_columns(transcript_identifier: nil)

    get "/public/resources/#{@resource.uuid}/transcript.vtt"

    assert_response :not_found
  end

  test "returns not found once the content is replaced" do
    Resource.find(@resource.id).content.attach(io: StringIO.new("new audio"), filename: "new.mp3", content_type: "audio/mpeg")

    get "/public/resources/#{@resource.uuid}/transcript.vtt"

    assert_response :not_found
  end
end
