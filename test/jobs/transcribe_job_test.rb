require "test_helper"
require "minitest/mock"
require_relative "../support/fake_transcription_service"

class TranscribeJobTest < ActiveJob::TestCase
  VTT = "WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.500\nHello\n".freeze

  setup do
    @service = ActiveStorage::Blob.service
    @fake = FakeTranscriptionService.new
    @resource = Resource.create!(project: projects(:one), name: "Interview", storage_key: SecureRandom.uuid)
    @resource.content.attach(io: StringIO.new("audio"), filename: "interview.mp3", content_type: "audio/mpeg")
    @blob = @resource.content.blob
    @name = Transcripts.job_name(@resource, @blob)
    clear_enqueued_jobs
  end

  test "does nothing when transcription is off" do
    TranscribeJob.perform_now(@resource.id)

    assert_nil @resource.reload.transcript_status
    assert_no_enqueued_jobs only: FetchTranscriptJob
  end

  test "starts a transcription and waits for it" do
    with_service { TranscribeJob.perform_now(@resource.id) }

    assert_equal "processing", @resource.reload.transcript_status
    assert_equal [[:cleanup, @name], [:start, @name]], @fake.calls
    assert_enqueued_with job: FetchTranscriptJob, args: [@resource.id, @blob.id, @name]
  end

  test "skips content that isn't audio or video" do
    image = Resource.create!(project: projects(:one), name: "Photo")
    image.content.attach(io: StringIO.new("image"), filename: "photo.jpg", content_type: "image/jpeg")

    with_service { TranscribeJob.perform_now(image.id) }

    assert_nil image.reload.transcript_status
    assert_empty @fake.calls
  end

  test "records a failure when the service can't start" do
    failing = FakeTranscriptionService.new
    def failing.start(*) = raise("access denied")

    Transcripts.stub(:service, failing) do
      assert_raises(RuntimeError) { TranscribeJob.perform_now(@resource.id) }
    end

    @resource.reload
    assert_equal "failed", @resource.transcript_status
    assert_equal "access denied", @resource.transcript_error
  end

  test "stores a finished transcript and rebuilds the manifest" do
    @fake.result = Transcripts::Result.new(state: :succeeded, vtt: VTT, json: '{"results":{}}', language: "en-US")
    @resource.update_columns(transcript_status: "processing")

    with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name) }

    @resource.reload
    assert_equal "succeeded", @resource.transcript_status
    assert_equal @blob.key, @resource.transcript_identifier
    assert_equal "en-US", @resource.transcript_language
    assert @resource.transcript?
    assert_equal VTT, @service.download(Transcripts.key(@resource, "vtt"))
    assert_equal '{"results":{}}', @service.download(Transcripts.key(@resource, "json"))
    assert_enqueued_with job: CreateManifestJob, args: [@resource.id]
    assert_includes @fake.calls, [:cleanup, @name]
  end

  test "deletes the previous content's transcript once the new one is stored" do
    previous_prefix = Transcripts.prefix(@resource, "previous")
    @service.upload("#{previous_prefix}/transcript.vtt", StringIO.new("old"))
    @resource.update_columns(transcript_identifier: "previous")
    @fake.result = Transcripts::Result.new(state: :succeeded, vtt: VTT)

    perform_enqueued_jobs(only: DeleteTranscriptJob) do
      with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name) }
    end

    assert_not @service.exist?("#{previous_prefix}/transcript.vtt")
    assert @resource.reload.transcript?
  end

  test "checks again later while the transcription is running" do
    with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name, 3) }

    assert_enqueued_with job: FetchTranscriptJob, args: [@resource.id, @blob.id, @name, 4]
  end

  test "gives up after the last check" do
    @resource.update_columns(transcript_status: "processing")

    with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name, FetchTranscriptJob::MAX_ATTEMPTS) }

    assert_equal "failed", @resource.reload.transcript_status
    assert_no_enqueued_jobs only: FetchTranscriptJob
    assert_includes @fake.calls, [:cleanup, @name]
  end

  test "records the service's failure reason" do
    @resource.update_columns(transcript_status: "processing")
    @fake.result = Transcripts::Result.new(state: :failed, error: "Unsupported media format")

    with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name) }

    @resource.reload
    assert_equal "failed", @resource.transcript_status
    assert_equal "Unsupported media format", @resource.transcript_error
    assert_not @resource.transcript?
  end

  test "marks a running transcription failed when its job is gone" do
    @resource.update_columns(transcript_status: "processing")
    @fake.result = Transcripts::Result.new(state: :missing)

    with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name) }

    assert_equal "failed", @resource.reload.transcript_status
  end

  test "leaves a stored transcript alone when its job is gone" do
    @resource.update_columns(transcript_status: "succeeded", transcript_identifier: @blob.key)
    @fake.result = Transcripts::Result.new(state: :missing)

    with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name) }

    assert_equal "succeeded", @resource.reload.transcript_status
  end

  test "discards the transcription when the content was replaced" do
    Resource.find(@resource.id).content.attach(io: StringIO.new("new audio"), filename: "new.mp3", content_type: "audio/mpeg")
    @fake.result = Transcripts::Result.new(state: :succeeded, vtt: VTT)

    with_service { FetchTranscriptJob.perform_now(@resource.id, @blob.id, @name) }

    assert_equal [[:cleanup, @name]], @fake.calls
    assert_not @service.exist?("#{Transcripts.prefix(@resource, @blob.key)}/transcript.vtt")
  end

  test "replacing the content removes the transcript" do
    prefix = Transcripts.prefix(@resource, @blob.key)
    @service.upload("#{prefix}/transcript.vtt", StringIO.new(VTT))
    @resource.update_columns(transcript_status: "succeeded", transcript_identifier: @blob.key, transcript_language: "en-US")

    perform_enqueued_jobs(only: DeleteTranscriptJob) do
      Resource.find(@resource.id).content.attach(io: StringIO.new("new audio"), filename: "new.mp3", content_type: "audio/mpeg")
    end

    @resource.reload
    assert_nil @resource.transcript_identifier
    assert_nil @resource.transcript_language
    assert_not @resource.transcript?
    assert_not @service.exist?("#{prefix}/transcript.vtt")
  end

  test "destroying the resource deletes its transcripts" do
    prefix = Transcripts.prefix(@resource, @blob.key)
    @service.upload("#{prefix}/transcript.vtt", StringIO.new(VTT))

    perform_enqueued_jobs(only: DeleteTranscriptJob) do
      Resource.find(@resource.id).destroy!
    end

    assert_not @service.exist?("#{prefix}/transcript.vtt")
  end

  test "queues transcription on upload when it is on" do
    Transcripts.stub(:enabled?, true) do
      resource = Resource.create!(project: projects(:one), name: "Another interview")

      assert_enqueued_with job: TranscribeJob, args: [resource.id]
    end
  end

  private

  def with_service(&block)
    Transcripts.stub(:service, @fake, &block)
  end
end
