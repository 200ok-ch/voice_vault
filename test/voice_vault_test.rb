#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "socket"
require "stringio"
require "tmpdir"
require "uri"
require_relative "../voice_vault"

class VoiceVaultTest < Minitest::Test
  class FakeRunner
    attr_reader :audio_prepared, :captured_commands, :interactive_commands, :local_audio,
                :recording_existed_at_transcription

    def initialize(fail_transcription: false, legacy_pactl: false, write_transcription: true)
      @fail_transcription = fail_transcription
      @legacy_pactl = legacy_pactl
      @write_transcription = write_transcription
      @captured_commands = []
      @interactive_commands = []
    end

    def capture(*command)
      @captured_commands << command

      case File.basename(command.first)
      when "pactl"
        if @legacy_pactl && command.last.start_with?("get-default-")
          raise VoiceVault::Error, "unsupported pactl command"
        end
        if command.last == "info"
          "Default Source: legacy-microphone\nDefault Sink: legacy-speakers\n"
        elsif command.last == "get-default-source"
          "test-microphone\n"
        else
          "test-speakers\n"
        end
      when "ffmpeg"
        content = File.extname(command.last) == ".wav" ? "normalized wav" : "encoded mp3"
        File.binwrite(command.last, content)
        @audio_prepared = true
        ""
      when "transcribe"
        @recording_existed_at_transcription = File.file?(command.last)
        output_path = command.fetch(command.index("--output") + 1)
        if @fail_transcription
          File.write(output_path, "partial transcript")
          raise VoiceVault::Error, "test transcription error"
        end

        File.write(output_path, "SPEAKER_00: Test transcript.\n") if @write_transcription
        "Wrote #{output_path}\n"
      when "main", "whisper-cli"
        @local_audio = File.binread(command.last)
        "Local transcript\n"
      else
        raise "Unexpected command: #{command.inspect}"
      end
    end

    def interactive(*command)
      @interactive_commands << command
      File.binwrite(command.last, "captured wav")
    end
  end

  def setup
    @temporary_directory = Dir.mktmpdir("voice-vault-test")
    @archive_path = File.join(@temporary_directory, "archives")
    @clock = -> { Time.new(2026, 7, 15, 10, 30, 0) }
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_transcribe_provider_uses_path_and_enables_diarization_by_default
    source_path = create_audio("meeting.mp3", "original mp3")
    runner = FakeRunner.new

    archive_directory = app(config: config("whisper_provider" => "transcribe"), runner: runner).run(
      source_file: source_path
    )

    command = runner.captured_commands.last
    assert_equal "transcribe", command.first
    assert_includes command, "--diarize"
    assert_includes command, "--output"
    assert_equal File.join(archive_directory, "recording.mp3"), command.last
    assert runner.recording_existed_at_transcription
    assert_equal "SPEAKER_00: Test transcript.\n", File.read(File.join(archive_directory, "transcription.txt"))
    assert_equal %w[recording.mp3 transcription.txt], Dir.children(archive_directory).sort
    assert_equal "original mp3", File.binread(source_path)
    assert_equal 0o700, File.stat(archive_directory).mode & 0o777
    assert_equal 0o600, File.stat(File.join(archive_directory, "recording.mp3")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(archive_directory, "transcription.txt")).mode & 0o777
  end

  def test_transcribe_provider_forwards_compatible_options
    source_path = create_audio("meeting.mp3", "mp3")
    runner = FakeRunner.new
    provider_config = config(
      "whisper_provider" => "transcribe",
      "whisper_model" => "medium",
      "whisper_language" => "de",
      "whisper_num_speakers" => 3,
      "whisper_read_timeout" => 120
    )

    app(config: provider_config, runner: runner).run(source_file: source_path)

    command = runner.captured_commands.last
    assert_option command, "--model", "medium"
    assert_option command, "--language", "de"
    assert_option command, "--num-speakers", "3"
    assert_option command, "--timeout", "120"
  end

  def test_transcribe_provider_forwards_valid_speaker_bounds
    source_path = create_audio("meeting.mp3", "mp3")
    runner = FakeRunner.new

    app(
      config: config(
        "whisper_provider" => "transcribe",
        "whisper_min_speakers" => 2,
        "whisper_max_speakers" => 5
      ),
      runner: runner
    ).run(source_file: source_path)

    command = runner.captured_commands.last
    assert_option command, "--min-speakers", "2"
    assert_option command, "--max-speakers", "5"
  end

  def test_transcribe_provider_can_disable_diarization
    source_path = create_audio("meeting.mp3", "mp3")
    runner = FakeRunner.new

    app(
      config: config(
        "whisper_provider" => "transcribe",
        "whisper_diarize" => false,
        "whisper_num_speakers" => 2
      ),
      runner: runner
    ).run(source_file: source_path)

    refute_includes runner.captured_commands.last, "--diarize"
    refute_includes runner.captured_commands.last, "--num-speakers"
  end

  def test_transcribe_failure_keeps_recording_and_removes_partial_output
    source_path = create_audio("meeting.mp3", "recoverable mp3")
    runner = FakeRunner.new(fail_transcription: true)

    error = assert_raises(VoiceVault::Error) do
      app(config: config("whisper_provider" => "transcribe"), runner: runner).run(
        source_file: source_path
      )
    end

    archive_directory = only_archive
    assert_match(/Transcription failed; recording saved in #{Regexp.escape(archive_directory)}/, error.message)
    assert_equal "recoverable mp3", File.binread(File.join(archive_directory, "recording.mp3"))
    assert_equal ["recording.mp3"], Dir.children(archive_directory)
  end

  def test_transcribe_success_without_output_is_a_failure
    source_path = create_audio("meeting.mp3", "recoverable mp3")
    runner = FakeRunner.new(write_transcription: false)

    error = assert_raises(VoiceVault::Error) do
      app(config: config("whisper_provider" => "transcribe"), runner: runner).run(
        source_file: source_path
      )
    end

    assert_match(/did not create its requested output/, error.message)
    assert_equal ["recording.mp3"], Dir.children(only_archive)
  end

  def test_installed_transcribe_is_resolved_through_path
    bin_directory = File.join(@temporary_directory, "bin")
    Dir.mkdir(bin_directory)
    executable = File.join(bin_directory, "transcribe")
    File.write(executable, <<~SH)
      #!/bin/sh
      [ "$1" = "--diarize" ] || exit 10
      shift
      [ "$1" = "--output" ] || exit 11
      output="$2"
      audio="$3"
      [ -f "$audio" ] || exit 12
      printf 'SPEAKER_00: PATH transcript.\n' > "$output"
    SH
    File.chmod(0o700, executable)
    source_path = create_audio("meeting.mp3", "mp3")
    previous_path = ENV.fetch("PATH")
    ENV["PATH"] = "#{bin_directory}:#{previous_path}"

    archive_directory = app(
      config: config("whisper_provider" => "transcribe"),
      runner: VoiceVault::CommandRunner.new
    ).run(source_file: source_path)

    assert_equal "SPEAKER_00: PATH transcript.\n", File.read(File.join(archive_directory, "transcription.txt"))
  ensure
    ENV["PATH"] = previous_path if previous_path
  end

  def test_legacy_local_config_uses_normalized_wav
    source_path = create_audio("meeting.mp3", "original mp3")
    whisper_path = create_whisper_install("main")
    runner = FakeRunner.new
    legacy_config = config(
      "whisper_path" => whisper_path,
      "whisper_model" => "small",
      "whisper_threads" => 4,
      "whisper_language" => "de"
    )

    archive_directory = app(config: legacy_config, runner: runner).run(source_file: source_path)

    local_command = runner.captured_commands.last
    assert_equal File.join(whisper_path, "main"), local_command.first
    assert_option local_command, "--language", "auto"
    assert_option local_command, "-t", "4"
    assert_equal "normalized wav", runner.local_audio
    assert_equal "Local transcript\n", File.read(File.join(archive_directory, "transcription.txt"))
    assert_equal "original mp3", File.binread(File.join(archive_directory, "recording.mp3"))
  end

  def test_local_provider_supports_new_whisper_cli_binary_name
    source_path = create_audio("meeting.wav", "wav")
    whisper_path = create_whisper_install("build/bin/whisper-cli")
    runner = FakeRunner.new

    app(
      config: config(
        "whisper_provider" => "local",
        "whisper_path" => whisper_path,
        "whisper_model" => "small"
      ),
      runner: runner
    ).run(source_file: source_path)

    assert_equal File.join(whisper_path, "build", "bin", "whisper-cli"), runner.captured_commands.last.first
  end

  def test_legacy_remote_config_inference_and_plain_response
    response_body = JSON.generate("text" => "Remote transcript")
    with_http_response(response_body) do |base_url, requests|
      source_path = create_audio("meeting.mp3", "mp3")
      remote_config = config(
        "whisper_base_url" => base_url,
        "whisper_api_token" => "test-token",
        "whisper_model" => "medium",
        "whisper_language" => "de",
        "whisper_prompt" => "Names",
        "whisper_hotwords" => "Voice Vault"
      )

      archive_directory = app(config: remote_config, runner: FakeRunner.new).run(source_file: source_path)
      request_line, headers, body = requests.pop

      assert_match(%r{POST /v1/audio/transcriptions HTTP/1\.1}, request_line)
      assert_equal "Bearer test-token", headers.fetch("authorization")
      assert_includes body, 'name="file"'
      assert_includes body, 'name="model"'
      assert_includes body, 'name="language"'
      assert_includes body, 'name="prompt"'
      assert_includes body, 'name="hotwords"'
      assert_equal "Remote transcript", File.read(File.join(archive_directory, "transcription.txt"))
      assert_equal %w[recording.mp3 result.json transcription.txt], Dir.children(archive_directory).sort
      assert_equal({ "text" => "Remote transcript" }, JSON.parse(File.read(File.join(archive_directory, "result.json"))))
      assert_equal 0o600, File.stat(File.join(archive_directory, "result.json")).mode & 0o777
    end
  end

  def test_remote_diarization_preserves_timestamped_json_artifacts
    response_body = JSON.generate(
      "segments" => [
        { "start" => 1.2, "end" => 3.8, "speaker" => "SPEAKER_00", "text" => " Hello." },
        { "start" => 4, "end" => 5, "speaker" => "SPEAKER_01", "text" => "Hi." }
      ]
    )
    with_http_response(response_body) do |base_url, requests|
      source_path = create_audio("meeting.mp3", "mp3")
      remote_config = config(
        "whisper_provider" => "remote",
        "whisper_base_url" => base_url,
        "whisper_model" => "medium",
        "whisper_diarize" => true,
        "whisper_num_speakers" => 2
      )

      archive_directory = app(config: remote_config, runner: FakeRunner.new).run(source_file: source_path)
      request_line, _headers, body = requests.pop

      uri = URI("http://example.test#{request_line.split.fetch(1)}")
      query = URI.decode_www_form(uri.query).to_h
      assert_equal "/asr", uri.path
      assert_equal "true", query.fetch("diarize")
      assert_equal "2", query.fetch("num_speakers")
      assert_includes body, 'name="audio_file"'
      assert_equal <<~TEXT.chomp, File.read(File.join(archive_directory, "transcription.txt"))
        [00:00:01-00:00:03] [SPEAKER_00] Hello.
        [00:00:04-00:00:05] [SPEAKER_01] Hi.
      TEXT
      assert_equal(
        %w[recording.mp3 result.json result_cleaned.json transcription.txt],
        Dir.children(archive_directory).sort
      )
      assert_equal 2, JSON.parse(File.read(File.join(archive_directory, "result_cleaned.json"))).length
      assert_equal JSON.parse(response_body), JSON.parse(File.read(File.join(archive_directory, "result.json")))
    end
  end

  def test_remote_failure_keeps_recording_and_removes_results
    with_http_response('{"error":"service unavailable"}', status: "503 Service Unavailable") do |base_url, _requests|
      source_path = create_audio("meeting.mp3", "recoverable mp3")

      error = assert_raises(VoiceVault::Error) do
        app(
          config: config(
            "whisper_provider" => "remote",
            "whisper_base_url" => base_url,
            "whisper_model" => "medium"
          ),
          runner: FakeRunner.new
        ).run(source_file: source_path)
      end

      assert_match(/service unavailable/, error.message)
      assert_equal ["recording.mp3"], Dir.children(only_archive)
    end
  end

  def test_abrupt_remote_failure_keeps_recording
    server = TCPServer.new("127.0.0.1", 0)
    thread = Thread.new do
      socket = server.accept
      socket.close
    end
    source_path = create_audio("meeting.mp3", "recoverable mp3")

    error = assert_raises(VoiceVault::Error) do
      app(
        config: config(
          "whisper_provider" => "remote",
          "whisper_base_url" => "http://127.0.0.1:#{server.addr[1]}",
          "whisper_model" => "medium"
        ),
        runner: FakeRunner.new
      ).run(source_file: source_path)
    end

    assert_match(/Transcription failed; recording saved in/, error.message)
    assert_equal ["recording.mp3"], Dir.children(only_archive)
  ensure
    server&.close
    thread&.join
  end

  def test_remote_speaker_constraints_are_validated_before_request
    invalid_counts = [
      {
        "whisper_num_speakers" => 2,
        "whisper_min_speakers" => 1
      },
      {
        "whisper_min_speakers" => 5,
        "whisper_max_speakers" => 2
      }
    ]

    invalid_counts.each_with_index do |counts, index|
      source_path = create_audio("meeting-#{index}.mp3", "mp3")
      error = assert_raises(VoiceVault::Error) do
        app(
          config: config({
            "whisper_provider" => "remote",
            "whisper_base_url" => "https://example.test",
            "whisper_model" => "medium",
            "whisper_diarize" => true
          }.merge(counts)),
          runner: FakeRunner.new
        ).run(source_file: source_path)
      end
      assert_match(/cannot be combined|cannot exceed/, error.message)
    end
  end

  def test_local_configuration_failure_keeps_recording
    source_path = create_audio("meeting.mp3", "recoverable mp3")
    missing_whisper = File.join(@temporary_directory, "missing-whisper")

    error = assert_raises(VoiceVault::Error) do
      app(
        config: config(
          "whisper_provider" => "local",
          "whisper_path" => missing_whisper,
          "whisper_model" => "small"
        ),
        runner: FakeRunner.new
      ).run(source_file: source_path)
    end

    assert_match(/Whisper model not found/, error.message)
    assert_equal ["recording.mp3"], Dir.children(only_archive)
  end

  def test_provider_selection_preserves_legacy_inference
    assert_equal "local", config.provider
    assert_equal "remote", config("whisper_base_url" => "https://example.test").provider
    assert_equal "transcribe", config("whisper_provider" => "transcribe").provider
  end

  def test_no_transcription_ignores_provider_configuration
    source_path = create_audio("meeting.mp3", "mp3")

    archive_directory = app(
      config: config("whisper_provider" => "unsupported"),
      runner: FakeRunner.new
    ).run(source_file: source_path, transcribe: false)

    assert_equal ["recording.mp3"], Dir.children(archive_directory)
  end

  def test_unsupported_provider_fails_after_archiving
    source_path = create_audio("meeting.mp3", "recoverable mp3")

    error = assert_raises(VoiceVault::Error) do
      app(
        config: config("whisper_provider" => "unsupported"),
        runner: FakeRunner.new
      ).run(source_file: source_path)
    end

    assert_match(/Unsupported `whisper_provider`/, error.message)
    assert_equal ["recording.mp3"], Dir.children(only_archive)
  end

  def test_non_mp3_import_uses_argument_array
    source_path = create_audio("meeting;not-a-command.wav", "wav")
    runner = FakeRunner.new

    app(config: config("whisper_provider" => "transcribe"), runner: runner).run(
      source_file: source_path,
      transcribe: false
    )

    command = runner.captured_commands.fetch(0)
    assert_equal [
      "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", source_path,
      "-vn", "-ac", "2", "-ar", "16000", "-y"
    ], command[0...-1]
    assert_match(%r{/voice-vault[^/]+/recording\.mp3\z}, command.last)
  end

  def test_live_recording_uses_pulse_defaults
    runner = FakeRunner.new

    app(config: config, runner: runner).run(transcribe: false)

    assert_equal ["pactl", "get-default-source"], runner.captured_commands.fetch(0)
    assert_equal ["pactl", "get-default-sink"], runner.captured_commands.fetch(1)
    capture_command = runner.interactive_commands.fetch(0)
    assert_includes capture_command, "test-microphone"
    assert_includes capture_command, "test-speakers.monitor"
  end

  def test_live_recording_falls_back_to_pactl_info
    runner = FakeRunner.new(legacy_pactl: true)

    app(config: config, runner: runner).run(transcribe: false)

    assert_equal ["pactl", "get-default-source"], runner.captured_commands.fetch(0)
    assert_equal ["pactl", "info"], runner.captured_commands.fetch(1)
    assert_equal ["pactl", "get-default-sink"], runner.captured_commands.fetch(2)
    assert_equal ["pactl", "info"], runner.captured_commands.fetch(3)
    capture_command = runner.interactive_commands.fetch(0)
    assert_includes capture_command, "legacy-microphone"
    assert_includes capture_command, "legacy-speakers.monitor"
  end

  def test_archive_directories_do_not_collide
    source_path = create_audio("meeting.mp3", "mp3")
    application = app(config: config, runner: FakeRunner.new)

    first = application.run(source_file: source_path, transcribe: false)
    second = application.run(source_file: source_path, transcribe: false)

    assert_equal "2026-07-15_10-30-00", File.basename(first)
    assert_equal "2026-07-15_10-30-00_2", File.basename(second)
  end

  def test_archive_timestamp_uses_recording_start_time
    source_path = create_audio("meeting.wav", "wav")
    runner = FakeRunner.new
    started_at = Time.new(2026, 7, 15, 10, 30, 0)
    finished_at = Time.new(2026, 7, 15, 12, 45, 0)
    clock = -> { runner.audio_prepared ? finished_at : started_at }

    archive_directory = app(config: config, runner: runner, clock: clock).run(
      source_file: source_path,
      transcribe: false
    )

    assert_equal "2026-07-15_10-30-00", File.basename(archive_directory)
  end

  def test_config_loads_legacy_keys_safely
    config_path = File.join(@temporary_directory, "config.yml")
    File.write(config_path, <<~YAML)
      archive_path: #{@archive_path}
      whisper_provider: local
      whisper_path: ~/src/whisper.cpp
      whisper_model: small
    YAML

    loaded = VoiceVault::Config.load(config_path)

    assert_equal @archive_path, loaded.archive_path
    assert_equal "local", loaded.provider
    assert_equal File.expand_path("~/src/whisper.cpp"), loaded.expanded_path("whisper_path")
  end

  def test_config_preserves_safe_yaml_aliases
    config_path = File.join(@temporary_directory, "config-with-alias.yml")
    File.write(config_path, <<~YAML)
      defaults: &defaults
        archive_path: #{@archive_path}
        whisper_provider: local
      <<: *defaults
    YAML

    loaded = VoiceVault::Config.load(config_path)

    assert_equal @archive_path, loaded.archive_path
    assert_equal "local", loaded.provider
  end

  def test_artifact_write_failure_is_cleaned_and_reports_recording
    source_path = create_audio("meeting.mp3", "recoverable mp3")
    failing_app_class = Class.new(VoiceVault::App) do
      private

      def write_private(path, _content)
        File.write(path, "partial")
        raise Errno::ENOSPC, "test disk full"
      end
    end
    application = failing_app_class.new(
      config: config("whisper_provider" => "transcribe"),
      runner: FakeRunner.new,
      clock: @clock,
      stdout: StringIO.new
    )

    error = assert_raises(VoiceVault::Error) { application.run(source_file: source_path) }

    assert_match(/Transcription failed; recording saved in/, error.message)
    assert_equal ["recording.mp3"], Dir.children(only_archive)
  end

  def test_help_does_not_require_config
    stdout = StringIO.new
    stderr = StringIO.new

    status = VoiceVault::CLI.run(["--help"], stdout: stdout, stderr: stderr)

    assert_equal 0, status
    assert_includes stdout.string, "Usage: voice_vault.rb"
    assert_empty stderr.string
  end

  def test_version_does_not_require_config
    stdout = StringIO.new
    stderr = StringIO.new

    status = VoiceVault::CLI.run(["--version"], stdout: stdout, stderr: stderr)

    assert_equal 0, status
    assert_equal "voice_vault 1.0.0\n", stdout.string
    assert_empty stderr.string
  end

  def test_cli_archives_file_without_transcription
    config_path = File.join(@temporary_directory, "config.yml")
    File.write(config_path, "archive_path: #{@archive_path}\n")
    source_path = create_audio("meeting.mp3", "mp3")
    stdout = StringIO.new
    stderr = StringIO.new

    status = VoiceVault::CLI.run(
      ["--config", config_path, "--file", source_path, "--no-transcription"],
      stdout: stdout,
      stderr: stderr
    )

    assert_equal 0, status
    assert_includes stdout.string, "Recording saved in:"
    assert_empty stderr.string
    assert_equal ["recording.mp3"], Dir.children(only_archive)
  end

  def test_cli_reports_provider_failure_and_retained_recording
    config_path = File.join(@temporary_directory, "config.yml")
    File.write(config_path, "archive_path: #{@archive_path}\nwhisper_provider: transcribe\n")
    source_path = create_audio("meeting.mp3", "mp3")
    empty_path = File.join(@temporary_directory, "empty-path")
    Dir.mkdir(empty_path)
    previous_path = ENV.fetch("PATH")
    ENV["PATH"] = empty_path
    stdout = StringIO.new
    stderr = StringIO.new

    status = VoiceVault::CLI.run(
      ["--config", config_path, "--file", source_path],
      stdout: stdout,
      stderr: stderr
    )

    assert_equal 1, status
    assert_includes stderr.string, "Transcription failed; recording saved in #{only_archive}"
    assert_includes stderr.string, "Could not run transcribe"
    assert_equal ["recording.mp3"], Dir.children(only_archive)
  ensure
    ENV["PATH"] = previous_path if previous_path
  end

  private

  def config(overrides = {})
    VoiceVault::Config.new({ "archive_path" => @archive_path }.merge(overrides))
  end

  def app(config:, runner:, clock: @clock)
    VoiceVault::App.new(config: config, runner: runner, clock: clock, stdout: StringIO.new)
  end

  def create_audio(filename, content)
    path = File.join(@temporary_directory, filename)
    File.binwrite(path, content)
    path
  end

  def create_whisper_install(executable_name)
    directory = File.join(@temporary_directory, "whisper-#{executable_name}")
    models_directory = File.join(directory, "models")
    FileUtils.mkdir_p(models_directory)
    executable = File.join(directory, executable_name)
    FileUtils.mkdir_p(File.dirname(executable))
    File.write(executable, "#!/bin/sh\n")
    File.chmod(0o700, executable)
    File.write(File.join(models_directory, "ggml-small.bin"), "model")
    directory
  end

  def only_archive
    Dir.glob(File.join(@archive_path, "*")).fetch(0)
  end

  def assert_option(command, flag, value)
    assert_equal value, command.fetch(command.index(flag) + 1)
  end

  def with_http_response(response_body, status: "200 OK")
    server = TCPServer.new("127.0.0.1", 0)
    requests = Queue.new
    server_thread = Thread.new do
      socket = server.accept
      request_line = socket.gets
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length").to_i)
      requests << [request_line, headers, body]
      socket.write(
        "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}"
      )
      socket.close
    end

    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    server&.close
    server_thread&.join
  end
end
