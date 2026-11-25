# Transcripts of audio and video content, made by a speech-to-text service.
#
# TRANSCRIPTION_SERVICE picks the service; transcription is off when it is blank. A service implements:
#
#   start(name, blob)  begins transcribing the blob. Calling it again with the same name must not start a second job.
#   fetch(name)        returns a Transcripts::Result, with state :missing when the service has no such job.
#   cleanup(name)      removes anything the service kept for the job. Safe to call for a job that doesn't exist.
#
# The transcript is stored next to the resource's other files as WebVTT captions and the service's full JSON output.
module Transcripts
  SERVICES = {
    'aws_transcribe' => 'Transcripts::AwsTranscribe'
  }.freeze

  DIRECTORY = 'transcripts'

  FILES = {
    'vtt' => 'text/vtt',
    'json' => 'application/json'
  }.freeze

  class ConfigurationError < StandardError; end

  # state is :processing, :succeeded, :failed or :missing. A succeeded result carries the transcript; a failed one,
  # its error.
  Result = Struct.new(:state, :vtt, :json, :language, :error, keyword_init: true)

  def self.enabled?
    ENV['TRANSCRIPTION_SERVICE'].present?
  end

  def self.service
    name = ENV['TRANSCRIPTION_SERVICE'].presence
    return nil unless name

    class_name = SERVICES[name]
    raise ConfigurationError, "Unknown TRANSCRIPTION_SERVICE #{name.inspect}. Use one of: #{SERVICES.keys.join(', ')}" unless class_name

    class_name.constantize.new
  end

  def self.transcribable?(resource)
    resource.content.attached? && (resource.audio? || resource.video?)
  end

  # Name of the service's job for a blob. The prefix keeps environments that share an account apart.
  def self.job_name(resource, blob)
    prefix = ENV['TRANSCRIPTION_JOB_PREFIX'].presence || "iiif-cloud-#{Rails.env}"
    "#{prefix}-#{resource.uuid}-#{blob.id}".gsub(/[^0-9A-Za-z._-]/, '-').first(200)
  end

  def self.directory(resource)
    [resource.storage_key.presence, DIRECTORY, resource.uuid].compact.join('/')
  end

  def self.prefix(resource, key = resource.transcript_identifier)
    raise ArgumentError, "Missing transcript identifier for resource #{resource.id}" if key.blank?

    "#{directory(resource)}/#{key}"
  end

  def self.key(resource, extension)
    "#{prefix(resource)}/transcript.#{extension}"
  end

  def self.upload(prefix, result)
    service = ActiveStorage::Blob.service

    { 'vtt' => result.vtt, 'json' => result.json }.each do |extension, body|
      next if body.blank?

      service.upload("#{prefix}/transcript.#{extension}", StringIO.new(body), content_type: FILES[extension])
    end
  end

  # Yields the locked resource if it still exists and its content is still the given blob. Returns the block's value,
  # or nil if the content has changed.
  def self.with_current_content(resource_id, blob)
    Resource.transaction do
      current = Resource.lock.find_by(id: resource_id)
      yield current if current&.content_attachment&.blob_id == blob.id
    end
  end
end
