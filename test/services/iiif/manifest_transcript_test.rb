require "test_helper"

class Iiif::ManifestTranscriptTest < ActiveSupport::TestCase
  setup do
    @resource = Resource.create!(project: projects(:one), name: "Interview")
    @resource.content.attach(io: StringIO.new("audio"), filename: "interview.mp3", content_type: "audio/mpeg")
  end

  test "adds the transcript to the canvas as a supplementing annotation" do
    @resource.update_columns(transcript_identifier: @resource.content.key, transcript_language: "en-US")

    canvas = manifest["items"].first
    annotation = canvas["annotations"].first["items"].first

    assert_equal "supplementing", annotation["motivation"]
    assert_equal canvas["id"], annotation["target"]
    assert_equal "#{ENV["HOSTNAME"]}/public/resources/#{@resource.uuid}/transcript.vtt", annotation["body"]["id"]
    assert_equal "text/vtt", annotation["body"]["format"]
    assert_equal "Text", annotation["body"]["type"]
    assert_equal "en-US", annotation["body"]["language"]
  end

  test "leaves the annotations out without a transcript" do
    assert_nil manifest["items"].first["annotations"]
  end

  private

  def manifest
    JSON.parse(Iiif::Manifest.create_for_resource(Resource.find(@resource.id)))
  end
end
