# Starts transcribing a resource's audio or video, then hands off to FetchTranscriptJob to wait for the result.
class TranscribeJob < ApplicationJob

  retry_on Exceptions::FileNotUploadedError, wait: 10.seconds

  def perform(resource_id)
    service = Transcripts.service
    return unless service

    resource = Resource.find_by(id: resource_id)
    return unless resource && Transcripts.transcribable?(resource)

    raise Exceptions::FileNotUploadedError unless resource.content_uploaded?

    blob = resource.content.blob

    started = Transcripts.with_current_content(resource.id, blob) do |current|
      current.update!(transcript_status: 'processing', transcript_error: nil)
    end

    return unless started

    name = Transcripts.job_name(resource, blob)

    begin
      # A finished job with the same name would block a new one, e.g. when transcribing the same file again
      service.cleanup(name)
      service.start(name, blob)
    rescue StandardError => e
      FetchTranscriptJob.record_failure(resource.id, blob, e.message)
      Rails.logger.error "Failed to start transcribing resource #{resource.id}: #{e.message}"
      raise
    end

    FetchTranscriptJob.set(wait: FetchTranscriptJob::WAIT).perform_later(resource.id, blob.id, name)
  end
end
