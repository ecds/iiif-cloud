namespace :transcripts do
  desc 'Queues transcription of audio and video resources that have no transcript (PROJECT_ID limits it to one project)'
  task create: :environment do
    abort 'Transcription is off. Set TRANSCRIPTION_SERVICE to turn it on.' unless Transcripts.enabled?

    query = Resource.with_attachment('content') do |subquery|
      subquery
        .joins(:blob)
        .where("active_storage_blobs.content_type LIKE 'audio/%' OR active_storage_blobs.content_type LIKE 'video/%'")
    end

    query = query.where(project_id: ENV['PROJECT_ID']) if ENV['PROJECT_ID'].present?
    query = query.where(transcript_identifier: nil).where("transcript_status IS NULL OR transcript_status <> 'processing'")

    # Duration is known once a resource's manifest has been built
    seconds = query.includes(content_attachment: :blob).sum { |resource| resource.content.blob.metadata['duration'].to_f }
    puts "Found #{query.count} resources, about #{(seconds / 60).ceil} minutes of recordings where the length is known."

    next puts('Nothing to transcribe.') if query.none?

    unless ENV['CONFIRM'] == 'true'
      print 'Queue these for transcription? [y/N] '
      $stdout.flush
      next puts('Aborted.') unless %w[y yes].include?($stdin.gets.to_s.strip.downcase)
    end

    query.in_batches do |resources|
      resources.pluck(:id).each { |resource_id| TranscribeJob.set(queue: :bulk).perform_later(resource_id) }
    end
  end
end
