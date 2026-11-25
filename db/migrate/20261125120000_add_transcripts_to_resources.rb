class AddTranscriptsToResources < ActiveRecord::Migration[8.0]
  def change
    # Status of the latest transcription request: processing, succeeded or failed. Blank when none was requested.
    add_column :resources, :transcript_status, :string
    add_column :resources, :transcript_error, :text

    # Key of the content blob the stored transcript was made from
    add_column :resources, :transcript_identifier, :string

    # Language the transcription service reported, e.g. "en-US"
    add_column :resources, :transcript_language, :string
  end
end
