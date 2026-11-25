# Stands in for a speech-to-text service. It records each call and answers fetch with the given result.
class FakeTranscriptionService
  attr_reader :calls
  attr_accessor :result

  def initialize(result = Transcripts::Result.new(state: :processing))
    @result = result
    @calls = []
  end

  def start(name, _blob)
    calls << [:start, name]
  end

  def fetch(name)
    calls << [:fetch, name]
    result
  end

  def cleanup(name)
    calls << [:cleanup, name]
  end
end
