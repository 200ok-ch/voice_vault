#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "open3"
require "optparse"
require "tempfile"
require "tmpdir"
require "uri"
require "yaml"

module VoiceVault
  VERSION = "1.0.1"
  DEFAULT_CONFIG_PATH = File.expand_path("~/.config/voice_vault/config.yml")

  class Error < StandardError; end

  Result = Struct.new(:text, :payload, keyword_init: true)
  PreparedAudio = Struct.new(:mp3_path, :wav_path, keyword_init: true)

  class Config
    attr_reader :archive_path

    def initialize(values)
      raise Error, "Invalid config: expected a YAML object" unless values.is_a?(Hash)

      @values = values
      @archive_path = expanded_path("archive_path")
      raise Error, "Missing or invalid `archive_path`" unless @archive_path
    end

    def self.load(path)
      values = YAML.safe_load(File.read(path), permitted_classes: [], aliases: true)
      new(values)
    rescue Errno::ENOENT
      raise Error, "Config file not found: #{path}"
    rescue Psych::Exception => e
      raise Error, "Invalid YAML in #{path}: #{e.message}"
    rescue Error => e
      raise Error, "#{e.message} in #{path}"
    end

    def [](key)
      @values[key]
    end

    def provider
      configured = optional_string("whisper_provider")
      return configured if configured
      return "remote" if optional_string("whisper_base_url")

      "local"
    end

    def optional_string(key)
      value = self[key]
      return if value.nil? || value.to_s.strip.empty?

      value.to_s
    end

    def required_string(key, context: nil)
      optional_string(key) || raise(Error, "Missing `#{key}`#{" for #{context}" if context}")
    end

    def expanded_path(key)
      value = optional_string(key)
      File.expand_path(value) if value
    end

    def boolean(key, default: false)
      value = self[key]
      return default if value.nil?
      return value if value == true || value == false
      return true if value.to_s.casecmp?("true")
      return false if value.to_s.casecmp?("false")

      raise Error, "`#{key}` must be true or false"
    end

    def positive_integer(key, default: nil)
      value = self[key]
      return default if value.nil? || value.to_s.empty?

      integer = value.is_a?(Integer) ? value : Integer(value.to_s, 10)
      raise Error, "`#{key}` must be positive" unless integer.positive?

      integer
    rescue ArgumentError, TypeError
      raise Error, "`#{key}` must be a positive integer"
    end

    def speaker_counts
      exact = positive_integer("whisper_num_speakers")
      minimum = positive_integer("whisper_min_speakers")
      maximum = positive_integer("whisper_max_speakers")
      if exact && (minimum || maximum)
        raise Error, "`whisper_num_speakers` cannot be combined with speaker bounds"
      end
      if minimum && maximum && minimum > maximum
        raise Error, "`whisper_min_speakers` cannot exceed `whisper_max_speakers`"
      end

      { exact: exact, minimum: minimum, maximum: maximum }
    end
  end

  class CommandRunner
    def capture(*command)
      stdout, stderr, status = Open3.capture3(*command)
      return stdout if status.success?

      detail = stderr.strip
      detail = "exit #{status.exitstatus}" if detail.empty?
      raise Error, "#{File.basename(command.first)} failed: #{detail}"
    rescue SystemCallError => e
      raise Error, "Could not run #{command.first}: #{e.message}"
    end

    def interactive(*command)
      return if system(*command)

      raise Error, "#{File.basename(command.first)} failed"
    rescue SystemCallError => e
      raise Error, "Could not run #{command.first}: #{e.message}"
    end
  end

  class TranscribeProvider
    attr_reader :input_format

    def initialize(config:, runner:)
      @config = config
      @runner = runner
      @input_format = :mp3
    end

    def name
      "transcribe"
    end

    def transcribe(audio_path)
      Dir.mktmpdir("voice-vault-transcribe") do |directory|
        output_path = File.join(directory, "transcription.txt")
        command = ["transcribe"]
        diarize = @config.boolean("whisper_diarize", default: true)
        command << "--diarize" if diarize
        add_option(command, "--model", @config.optional_string("whisper_model"))
        add_option(command, "--language", @config.optional_string("whisper_language"))
        add_speaker_options(command) if diarize
        add_option(command, "--timeout", @config.positive_integer("whisper_read_timeout"))
        command.concat(["--output", output_path, audio_path])

        @runner.capture(*command)
        raise Error, "transcribe did not create its requested output" unless File.file?(output_path)

        Result.new(text: File.read(output_path), payload: nil)
      end
    end

    private

    def add_option(command, flag, value)
      command.concat([flag, value.to_s]) unless value.nil?
    end

    def add_speaker_options(command)
      counts = @config.speaker_counts
      add_option(command, "--num-speakers", counts.fetch(:exact))
      add_option(command, "--min-speakers", counts.fetch(:minimum))
      add_option(command, "--max-speakers", counts.fetch(:maximum))
    end
  end

  class LocalWhisperProvider
    attr_reader :input_format

    def initialize(config:, runner:)
      @config = config
      @runner = runner
      @input_format = :wav
    end

    def name
      "local whisper.cpp"
    end

    def transcribe(audio_path)
      whisper_path = @config.expanded_path("whisper_path")
      raise Error, "Missing `whisper_path` for local provider" unless whisper_path

      model = @config.required_string("whisper_model", context: "local provider")
      model_path = File.join(whisper_path, "models", "ggml-#{model}.bin")
      raise Error, "Whisper model not found: #{model_path}" unless File.file?(model_path)

      command = [
        whisper_executable(whisper_path),
        "--language", "auto",
        "--model", model_path
      ]
      threads = @config.positive_integer("whisper_threads")
      command.concat(["-t", threads.to_s]) if threads
      command.concat(["--file", audio_path])

      Result.new(text: @runner.capture(*command), payload: nil)
    end

    private

    def whisper_executable(whisper_path)
      candidates = [
        File.join(whisper_path, "main"),
        File.join(whisper_path, "whisper-cli"),
        File.join(whisper_path, "build", "bin", "whisper-cli")
      ]
      candidates.find { |path| File.file?(path) && File.executable?(path) } ||
        raise(Error, "Whisper executable not found: #{candidates.join(" or ")}")
    end
  end

  class RemoteWhisperProvider
    attr_reader :input_format

    def initialize(config:, runner:)
      @config = config
      @runner = runner
      @input_format = :mp3
    end

    def name
      "remote Whisper"
    end

    def transcribe(audio_path)
      uri = transcription_uri
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = timeout("whisper_open_timeout", 30)
      http.read_timeout = timeout("whisper_read_timeout", 3600)
      http.write_timeout = timeout("whisper_write_timeout", 300) if http.respond_to?(:write_timeout=)
      form_fields = remote_form_fields(audio_path)

      request = Net::HTTP::Post.new(uri)
      token = @config.optional_string("whisper_api_token")
      request["Authorization"] = "Bearer #{token}" if token
      request.set_form(form_fields, "multipart/form-data")
      response = http.request(request)
      payload = parse_json(response.body)
      transcription_text = extract_transcription_text(payload) if payload

      if response.is_a?(Net::HTTPSuccess) && !transcription_text.nil?
        return Result.new(text: transcription_text, payload: payload)
      end

      raise Error, "Remote whisper transcription failed: #{remote_error_message(response, payload)}"
    rescue URI::InvalidURIError => e
      raise Error, "Invalid `whisper_base_url`: #{e.message}"
    rescue Net::OpenTimeout => e
      raise Error, "Remote whisper connection timed out after #{timeout("whisper_open_timeout", 30)}s: #{e.class}"
    rescue Net::ReadTimeout => e
      raise Error, "Remote whisper transcription timed out after #{timeout("whisper_read_timeout", 3600)}s: #{e.class}"
    rescue Net::WriteTimeout => e
      raise Error, "Remote whisper upload timed out after #{timeout("whisper_write_timeout", 300)}s: #{e.class}"
    rescue EOFError, IOError, Net::HTTPBadResponse, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "Remote whisper request failed: #{e.class}: #{e.message}"
    ensure
      form_fields&.each { |_, value| value.close if value.respond_to?(:close) }
    end

    private

    def diarization_enabled?
      @config.boolean("whisper_diarize")
    end

    def transcription_uri
      base_url = @config.required_string("whisper_base_url", context: "remote provider")
      path = diarization_enabled? ? "/asr" : "/v1/audio/transcriptions"
      uri = URI("#{base_url.sub(%r{/*$}, "")}#{path}")
      raise Error, "Invalid `whisper_base_url`: expected HTTP or HTTPS" unless uri.is_a?(URI::HTTP) && uri.host

      query = remote_query_params
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end

    def remote_query_params
      return {} unless diarization_enabled?

      params = { "diarize" => "true", "output_format" => "json" }
      counts = @config.speaker_counts
      {
        exact: "num_speakers",
        minimum: "min_speakers",
        maximum: "max_speakers"
      }.each do |count_key, field_name|
        value = counts.fetch(count_key)
        params[field_name] = value.to_s if value
      end
      params
    end

    def remote_form_fields(audio_path)
      file_field = diarization_enabled? ? "audio_file" : "file"
      fields = [[file_field, File.open(audio_path, "rb")]]
      fields << ["model", @config.required_string("whisper_model", context: "remote provider")]

      mappings = if diarization_enabled?
                   {
                     "whisper_language" => "language",
                     "whisper_prompt" => "initial_prompt",
                     "whisper_hotwords" => "hotwords"
                   }
                 else
                   {
                     "whisper_language" => "language",
                     "whisper_prompt" => "prompt",
                     "whisper_hotwords" => "hotwords"
                   }
                 end
      mappings.each do |config_key, field_name|
        value = @config.optional_string(config_key)
        fields << [field_name, value] if value
      end
      fields
    end

    def timeout(key, default)
      @config.positive_integer(key, default: default)
    end

    def parse_json(body)
      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def extract_transcription_text(payload)
      return payload["text"] if payload["text"].is_a?(String)
      return render_segments(payload["text"]) if payload["text"].is_a?(Array)
      return render_segments(payload["segments"]) if payload["segments"].is_a?(Array)

      nil
    end

    def render_segments(segments)
      speakers_present = segments.any? { |segment| !segment["speaker"].to_s.empty? }
      segments.map do |segment|
        timestamp = segment_timestamp(segment)
        speaker = "[#{segment["speaker"] || "UNKNOWN"}]" if speakers_present
        [timestamp, speaker, segment["text"].to_s.strip].compact.join(" ")
      end.join("\n")
    end

    def segment_timestamp(segment)
      return if segment["start"].nil? || segment["end"].nil?

      "[#{format_timestamp(segment["start"])}-#{format_timestamp(segment["end"])}]"
    end

    def format_timestamp(total_seconds)
      total_seconds = total_seconds.to_f
      hours = (total_seconds / 3600).floor
      minutes = ((total_seconds % 3600) / 60).floor
      seconds = (total_seconds % 60).floor
      format("%02d:%02d:%02d", hours, minutes, seconds)
    end

    def remote_error_message(response, payload)
      if payload
        message = payload["error"]
        message = message["message"] if message.is_a?(Hash)
        return message unless message.to_s.empty?
      end

      body = response.body.to_s.strip
      body = "(empty response body)" if body.empty?
      body = "#{body[0, 500]}..." if body.length > 500
      "HTTP #{response.code} #{response.message}: #{body}"
    end
  end

  class App
    def initialize(config:, runner: CommandRunner.new, clock: -> { Time.now }, stdout: $stdout)
      @config = config
      @runner = runner
      @clock = clock
      @stdout = stdout
    end

    def run(source_file: nil, transcribe: true)
      source_file = validate_source_file(source_file) if source_file
      started_at = @clock.call

      Dir.mktmpdir("voice-vault") do |temporary_directory|
        prepared_audio = prepare_audio(
          temporary_directory,
          source_file,
          local_transcription: transcribe && @config.provider == "local"
        )
        archive_directory = create_archive_directory(started_at)
        recording_path = File.join(archive_directory, "recording.mp3")
        FileUtils.mv(prepared_audio.mp3_path, recording_path)
        File.chmod(0o600, recording_path)

        if transcribe
          transcribe_recording(recording_path, prepared_audio.wav_path, archive_directory)
        end

        @stdout.puts "Recording saved in: #{archive_directory}"
        archive_directory
      end
    end

    private

    def validate_source_file(path)
      expanded_path = File.expand_path(path)
      raise Error, "Audio file not found: #{expanded_path}" unless File.file?(expanded_path)

      expanded_path
    end

    def prepare_audio(temporary_directory, source_file, local_transcription:)
      mp3_path = File.join(temporary_directory, "recording.mp3")
      wav_path = File.join(temporary_directory, "recording.wav") if !source_file || local_transcription

      if source_file
        convert_to_wav(source_file, wav_path) if local_transcription
        if File.extname(source_file).casecmp?(".mp3")
          FileUtils.copy_file(source_file, mp3_path)
        else
          encode_mp3(local_transcription ? wav_path : source_file, mp3_path)
        end
      else
        capture_audio(wav_path)
        encode_mp3(wav_path, mp3_path)
      end

      PreparedAudio.new(mp3_path: mp3_path, wav_path: wav_path)
    end

    def capture_audio(wav_path)
      input_source = pulse_default("get-default-source", "source")
      monitor_source = "#{pulse_default("get-default-sink", "sink")}.monitor"

      @stdout.puts "Capturing audio. Press 'q' to stop."
      @runner.interactive(
        "ffmpeg", "-stdin", "-hide_banner", "-loglevel", "error",
        "-f", "pulse", "-ac", "2", "-ar", "16000", "-i", input_source,
        "-f", "pulse", "-ac", "2", "-ar", "16000", "-i", monitor_source,
        "-filter_complex", "[0:a][1:a]amerge=inputs=2[a]",
        "-map", "[a]", "-ac", "2", "-y", wav_path
      )
    end

    def pulse_default(command, kind)
      value = @runner.capture("pactl", command).strip
      raise Error, "PulseAudio returned an empty default #{kind}" if value.empty?

      value
    rescue Error => modern_error
      begin
        pulse_default_from_info(kind)
      rescue Error => fallback_error
        raise Error, "#{modern_error.message}; pactl info fallback failed: #{fallback_error.message}"
      end
    end

    def pulse_default_from_info(kind)
      label = kind == "source" ? "Default Source" : "Default Sink"
      line = @runner.capture("pactl", "info").lines.find { |entry| entry.start_with?("#{label}:") }
      value = line&.split(":", 2)&.last&.strip
      raise Error, "PulseAudio returned no default #{kind}" if value.to_s.empty?

      value
    end

    def convert_to_wav(input_path, output_path)
      @runner.capture(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", input_path,
        "-vn", "-ac", "2", "-ar", "16000", "-c:a", "pcm_s16le", "-y", output_path
      )
    end

    def encode_mp3(input_path, output_path)
      @runner.capture(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", input_path,
        "-vn", "-ac", "2", "-ar", "16000", "-y", output_path
      )
    end

    def create_archive_directory(started_at)
      FileUtils.mkdir_p(@config.archive_path, mode: 0o700)
      base_name = started_at.strftime("%Y-%m-%d_%H-%M-%S")
      suffix = nil

      loop do
        path = File.join(@config.archive_path, "#{base_name}#{suffix}")
        Dir.mkdir(path, 0o700)
        return path
      rescue Errno::EEXIST
        suffix = suffix ? "_#{suffix.delete_prefix("_").to_i + 1}" : "_2"
      end
    end

    def transcribe_recording(recording_path, wav_path, archive_directory)
      provider = transcription_provider
      input_path = provider.input_format == :wav ? wav_path : recording_path
      raise Error, "A normalized WAV was not prepared for the local provider" unless input_path

      @stdout.puts "Transcribing with #{provider.name}..."
      result = provider.transcribe(input_path)
      raise Error, "Transcription provider returned no text" unless result.text.is_a?(String)

      write_private(File.join(archive_directory, "transcription.txt"), result.text)
      save_payload(archive_directory, result.payload) if result.payload
    rescue Error, SystemCallError => e
      %w[transcription.txt result.json result_cleaned.json].each do |filename|
        FileUtils.rm_f(File.join(archive_directory, filename))
      end
      raise Error, "Transcription failed; recording saved in #{archive_directory}: #{e.message}"
    end

    def transcription_provider
      provider_class = case @config.provider
                       when "transcribe" then TranscribeProvider
                       when "local" then LocalWhisperProvider
                       when "remote" then RemoteWhisperProvider
                       else
                         raise Error, "Unsupported `whisper_provider`: #{@config.provider}"
                       end
      provider_class.new(config: @config, runner: @runner)
    end

    def save_payload(archive_directory, payload)
      write_private(File.join(archive_directory, "result.json"), JSON.pretty_generate(payload))
      segments = payload["segments"] || payload["text"]
      return unless segments.is_a?(Array)

      write_private(
        File.join(archive_directory, "result_cleaned.json"),
        JSON.pretty_generate(segments)
      )
    end

    def write_private(path, content)
      temporary = Tempfile.new([".voice-vault", ".tmp"], File.dirname(path))
      temporary.chmod(0o600)
      temporary.write(content)
      temporary.close
      File.rename(temporary.path, path)
    ensure
      temporary&.close!
    end
  end

  class CLI
    def self.run(argv, stdout: $stdout, stderr: $stderr)
      options = { transcribe: true, config_path: DEFAULT_CONFIG_PATH }
      parser = option_parser(options)
      parser.parse!(argv)

      if options[:help]
        stdout.puts parser
        return 0
      end
      if options[:version]
        stdout.puts "voice_vault #{VERSION}"
        return 0
      end
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(" ")}" unless argv.empty?

      config = Config.load(File.expand_path(options[:config_path]))
      App.new(config: config, stdout: stdout).run(
        source_file: options[:file],
        transcribe: options[:transcribe]
      )
      0
    rescue OptionParser::ParseError => e
      stderr.puts e.message
      stderr.puts "Run `voice_vault.rb --help` for usage."
      64
    rescue Error, SystemCallError => e
      stderr.puts e.message
      1
    end

    def self.option_parser(options)
      OptionParser.new do |parser|
        parser.banner = "Usage: voice_vault.rb [options]"

        parser.on("-f", "--file FILE", "Archive an existing audio file instead of recording") do |file|
          options[:file] = file
        end
        parser.on("--no-transcription", "Archive audio without transcription") do
          options[:transcribe] = false
        end
        parser.on("--config PATH", "Voice Vault config (default: #{DEFAULT_CONFIG_PATH})") do |path|
          options[:config_path] = path
        end
        parser.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
        parser.on("-v", "--version", "Show the version") do
          options[:version] = true
        end
      end
    end
    private_class_method :option_parser
  end
end

exit VoiceVault::CLI.run(ARGV) if $PROGRAM_NAME == __FILE__
