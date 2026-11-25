require "test_helper"
require "minitest/mock"
require "aws-sdk-transcribeservice"

class Transcripts::AwsTranscribeTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body) do
    def success? = code == 200
  end

  SETTINGS = %w[TRANSCRIPTION_LANGUAGE TRANSCRIPTION_LANGUAGE_OPTIONS TRANSCRIPTION_MAX_SPEAKERS].freeze

  setup do
    @previous = SETTINGS.index_with { |key| ENV[key] }
    SETTINGS.each { |key| ENV.delete(key) }

    @client = Aws::TranscribeService::Client.new(stub_responses: true, region: "us-east-1")
    @transcribe = Transcripts::AwsTranscribe.new(client: @client)
    @blob = Struct.new(:key).new("project/abc123")
  end

  teardown do
    @previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  test "asks for WebVTT subtitles and identifies the language by default" do
    params = job_params

    assert_equal "s3://bucket/project/abc123", params[:media][:media_file_uri]
    assert_equal ["vtt"], params[:subtitles][:formats]
    assert params[:identify_language]
    assert_nil params[:language_code]
    assert_nil params[:settings]
  end

  test "uses the configured language" do
    ENV["TRANSCRIPTION_LANGUAGE"] = "en-US"

    params = job_params

    assert_equal "en-US", params[:language_code]
    assert_nil params[:identify_language]
  end

  test "limits language identification to the configured options" do
    ENV["TRANSCRIPTION_LANGUAGE_OPTIONS"] = "en-US, es-US"

    assert_equal ["en-US", "es-US"], job_params[:language_options]
  end

  test "turns on speaker labels" do
    ENV["TRANSCRIPTION_MAX_SPEAKERS"] = "4"

    assert_equal({ show_speaker_labels: true, max_speaker_labels: 4 }, job_params[:settings])
  end

  test "refuses content that isn't stored in S3" do
    blob = Struct.new(:key, :service).new("key", Object.new)

    assert_raises(Transcripts::ConfigurationError) { @transcribe.job_params("job", blob) }
  end

  test "treats a job that already exists as started" do
    @client.stub_responses(:start_transcription_job, "ConflictException")

    @transcribe.stub(:media_file_uri, "s3://bucket/key") do
      assert_nothing_raised { @transcribe.start("job", @blob) }
    end
  end

  test "downloads the transcript once the job completes" do
    @client.stub_responses(:get_transcription_job, transcription_job: {
      transcription_job_status: "COMPLETED",
      language_code: "en-US",
      transcript: { transcript_file_uri: "https://example.com/transcript.json" },
      subtitles: { subtitle_file_uris: ["https://example.com/transcript.vtt"] }
    })
    downloads = { "https://example.com/transcript.json" => "{}", "https://example.com/transcript.vtt" => "WEBVTT" }

    result = HTTParty.stub(:get, ->(url) { Response.new(200, downloads.fetch(url)) }) { @transcribe.fetch("job") }

    assert_equal :succeeded, result.state
    assert_equal "WEBVTT", result.vtt
    assert_equal "{}", result.json
    assert_equal "en-US", result.language
  end

  test "reports a failed job's reason" do
    @client.stub_responses(:get_transcription_job, transcription_job: { transcription_job_status: "FAILED", failure_reason: "Unsupported media format" })

    result = @transcribe.fetch("job")

    assert_equal :failed, result.state
    assert_equal "Unsupported media format", result.error
  end

  test "reports a job that is still running" do
    @client.stub_responses(:get_transcription_job, transcription_job: { transcription_job_status: "IN_PROGRESS" })

    assert_equal :processing, @transcribe.fetch("job").state
  end

  test "reports a job that doesn't exist" do
    @client.stub_responses(:get_transcription_job, "BadRequestException")

    assert_equal :missing, @transcribe.fetch("job").state
  end

  test "ignores cleaning up a job that doesn't exist" do
    @client.stub_responses(:delete_transcription_job, "BadRequestException")

    assert_nothing_raised { @transcribe.cleanup("job") }
  end

  private

  def job_params
    @transcribe.stub(:media_file_uri, ->(blob) { "s3://bucket/#{blob.key}" }) do
      @transcribe.job_params("job", @blob)
    end
  end
end
