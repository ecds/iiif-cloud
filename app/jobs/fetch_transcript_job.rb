# Checks on a transcription job, queueing itself again until the job finishes. A finished transcript is stored with
# the resource's files and added to its manifest.
class FetchTranscriptJob < ApplicationJob
  WAIT = 1.minute

  # Transcription takes up to about the length of the recording, so this allows for a long one and a busy service
  MAX_ATTEMPTS = 12 * 60

  def perform(resource_id, blob_id, name, attempt = 1)
    service = Transcripts.service
    return unless service

    resource = Resource.find_by(id: resource_id)
    blob = ActiveStorage::Blob.find_by(id: blob_id)

    # The resource was deleted or its content replaced, so nothing will use this transcript
    unless resource && blob && resource.content_attachment&.blob_id == blob.id
      service.cleanup(name)
      return
    end

    result = service.fetch(name)

    case result.state
    when :processing
      if attempt >= MAX_ATTEMPTS
        self.class.record_failure(resource.id, blob, 'Transcription did not finish in time')
        service.cleanup(name)
      else
        self.class.set(wait: WAIT).perform_later(resource_id, blob_id, name, attempt + 1)
      end
    when :failed
      self.class.record_failure(resource.id, blob, result.error)
      service.cleanup(name)
    when :succeeded
      publish(resource, blob, result)
      service.cleanup(name)
    when :missing
      # Another check already stored this transcript, or the job was deleted before it finished
      Transcripts.with_current_content(resource.id, blob) do |current|
        if current.transcript_status == 'processing'
          current.update!(transcript_status: 'failed',
                          transcript_error: 'Transcription job not found')
        end
      end
    end
  end

  # Returns false if the failure wasn't recorded because the content has changed
  def self.record_failure(resource_id, blob, error)
    recorded = Transcripts.with_current_content(resource_id, blob) do |current|
      current.update!(transcript_status: 'failed', transcript_error: error)
    end

    recorded.present?
  end

  private

  def publish(resource, blob, result)
    prefix = Transcripts.prefix(resource, blob.key)
    Transcripts.upload(prefix, result)

    previous_identifier = nil

    published = Transcripts.with_current_content(resource.id, blob) do |current|
      previous_identifier = current.transcript_identifier
      current.update!(
        transcript_status: 'succeeded',
        transcript_error: nil,
        transcript_identifier: blob.key,
        transcript_language: result.language
      )
    end

    unless published
      DeleteTranscriptJob.perform_now(prefix)
      return
    end

    if previous_identifier.present? && previous_identifier != blob.key
      DeleteTranscriptJob.perform_later(Transcripts.prefix(resource, previous_identifier))
    end

    CreateManifestJob.perform_later(resource.id)

    Rails.logger.info "Stored transcript for resource #{resource.id}"
  end
end
