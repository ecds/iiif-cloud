# Transcripts are uploaded outside of ActiveStorage, so they aren't purged with the content attachment
class DeleteTranscriptJob < ApplicationJob
  def perform(prefix)
    raise ArgumentError, "Invalid transcript prefix: #{prefix.inspect}" unless prefix.to_s.include?("#{Transcripts::DIRECTORY}/")

    ActiveStorage::Blob.service.delete_prefixed("#{prefix}/")
  end
end
