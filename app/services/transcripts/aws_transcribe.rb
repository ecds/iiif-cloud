require 'aws-sdk-transcribeservice'

module Transcripts
  # Amazon Transcribe batch jobs. Transcribe reads the file straight from the S3 bucket, so the content must be stored
  # in S3 in the same region. Its output stays in Transcribe's own storage until the job is deleted.
  #
  # Settings:
  #   TRANSCRIPTION_LANGUAGE          language code such as en-US. When blank, Transcribe identifies the language.
  #   TRANSCRIPTION_LANGUAGE_OPTIONS  comma-separated codes to choose from when identifying, e.g. "en-US,es-US".
  #   TRANSCRIPTION_MAX_SPEAKERS      2 to 30 turns on speaker labels in the JSON output.
  #   TRANSCRIPTION_AWS_REGION        defaults to AWS_REGION.
  class AwsTranscribe
    NOT_FOUND = [
      Aws::TranscribeService::Errors::BadRequestException,
      Aws::TranscribeService::Errors::NotFoundException
    ].freeze

    def initialize(client: nil)
      @client = client || Aws::TranscribeService::Client.new(region: ENV['TRANSCRIPTION_AWS_REGION'].presence || ENV['AWS_REGION'])
    end

    def start(name, blob)
      @client.start_transcription_job(job_params(name, blob))
    rescue Aws::TranscribeService::Errors::ConflictException
      # A job with this name is already running or finished
      nil
    end

    def fetch(name)
      job = @client.get_transcription_job(transcription_job_name: name).transcription_job

      case job.transcription_job_status
      when 'COMPLETED'
        Result.new(
          state: :succeeded,
          vtt: download(job.subtitles&.subtitle_file_uris&.first),
          json: download(job.transcript&.transcript_file_uri),
          language: job.language_code
        )
      when 'FAILED'
        Result.new(state: :failed, error: job.failure_reason.presence || 'Transcription failed')
      else
        Result.new(state: :processing)
      end
    rescue *NOT_FOUND
      Result.new(state: :missing)
    end

    def cleanup(name)
      @client.delete_transcription_job(transcription_job_name: name)
    rescue *NOT_FOUND
      nil
    end

    def job_params(name, blob)
      params = {
        transcription_job_name: name,
        media: { media_file_uri: media_file_uri(blob) },
        subtitles: { formats: ['vtt'], output_start_index: 1 }
      }

      language = ENV['TRANSCRIPTION_LANGUAGE'].presence

      if language
        params[:language_code] = language
      else
        params[:identify_language] = true
        options = ENV['TRANSCRIPTION_LANGUAGE_OPTIONS'].to_s.split(',').map(&:strip).reject(&:blank?)
        params[:language_options] = options if options.any?
      end

      speakers = ENV['TRANSCRIPTION_MAX_SPEAKERS'].to_i
      params[:settings] = { show_speaker_labels: true, max_speaker_labels: speakers.clamp(2, 30) } if speakers >= 2

      params
    end

    private

    def media_file_uri(blob)
      service = blob.service
      raise ConfigurationError, 'Amazon Transcribe needs content stored in S3' unless service.respond_to?(:bucket)

      "s3://#{service.bucket.name}/#{blob.key}"
    end

    # The output URLs are pre-signed and expire after a few minutes
    def download(url)
      return nil if url.blank?

      response = HTTParty.get(url)
      raise "Unable to download transcription output (HTTP #{response.code})" unless response.success?

      response.body.to_s.dup.force_encoding(Encoding::UTF_8)
    end
  end
end
