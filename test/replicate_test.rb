#!/usr/bin/env ruby
# frozen_string_literal: true

require "minitest/autorun"
require "socket"
require "stringio"
require "tmpdir"
require_relative "../replicate"

class ReplicateTest < Minitest::Test
  class FakeClient
    attr_reader :create_options

    def initialize(results)
      @results = results
    end

    def create_job(**options)
      @create_options = options
      { "id" => "job-123" }
    end

    def job_status(_job_id)
      @results.shift
    end
  end

  class CLIFakeClient
    class << self
      attr_accessor :initialization, :result
    end

    def initialize(**options)
      self.class.initialization = options
    end

    def create_job(**_options)
      { "id" => "job-123" }
    end

    def job_status(_job_id)
      self.class.result
    end
  end

  def setup
    @temporary_directory = Dir.mktmpdir("replicate-test")
  end

  def teardown
    FileUtils.remove_entry(@temporary_directory)
  end

  def test_workflow_polls_and_writes_valid_private_json
    client = FakeClient.new([
      { "status" => "processing" },
      {
        "status" => "succeeded",
        "output" => {
          "segments" => [
            {
              "start" => 1,
              "end" => 2,
              "speaker" => "SPEAKER_00",
              "text" => "Hello",
              "unrelated" => "removed"
            },
            { "text" => "Missing fields become null" }
          ]
        }
      }
    ])
    sleeps = []
    workflow = VoiceVault::ReplicateWorkflow.new(
      client: client,
      stdout: StringIO.new,
      sleeper: ->(seconds) { sleeps << seconds }
    )
    archive_path = File.join(@temporary_directory, "archive with spaces")

    workflow.run(
      file_url: "https://example.test/audio.mp3",
      archive_path: archive_path,
      prompt: "Names",
      num_speakers: 2,
      poll_interval: 3
    )

    assert_equal [3], sleeps
    assert_equal 2, client.create_options.fetch(:num_speakers)
    expected_segment = {
      "start" => 1,
      "end" => 2,
      "speaker" => "SPEAKER_00",
      "text" => "Hello"
    }
    second_segment = {
      "start" => nil,
      "end" => nil,
      "speaker" => nil,
      "text" => "Missing fields become null"
    }
    expected_stream = "#{JSON.pretty_generate(expected_segment)}\n#{JSON.pretty_generate(second_segment)}\n"
    assert_equal expected_stream, File.read(File.join(archive_path, "result_cleaned.json"))
    assert_equal(
      [expected_segment, second_segment],
      JSON.parse(File.read(File.join(archive_path, "result_segments.json")))
    )
    assert_equal 0o600, File.stat(File.join(archive_path, "result.json")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(archive_path, "result_cleaned.json")).mode & 0o777
    assert_equal 0o600, File.stat(File.join(archive_path, "result_segments.json")).mode & 0o777
  end

  def test_failed_job_raises_an_error
    client = FakeClient.new([{ "status" => "failed", "error" => "model failed" }])
    workflow = VoiceVault::ReplicateWorkflow.new(
      client: client,
      stdout: StringIO.new,
      sleeper: ->(_seconds) {}
    )

    error = assert_raises(VoiceVault::Error) do
      workflow.run(
        file_url: "https://example.test/audio.mp3",
        archive_path: @temporary_directory
      )
    end

    assert_match(/model failed/, error.message)
  end

  def test_all_replicate_terminal_failure_statuses_raise
    %w[canceled cancelled aborted].each do |status|
      client = FakeClient.new([{ "status" => status, "error" => "stopped" }])
      workflow = VoiceVault::ReplicateWorkflow.new(
        client: client,
        stdout: StringIO.new,
        sleeper: ->(_seconds) {}
      )

      error = assert_raises(VoiceVault::Error) do
        workflow.run(
          file_url: "https://example.test/audio.mp3",
          archive_path: @temporary_directory
        )
      end
      assert_match(/#{status}/, error.message)
    end
  end

  def test_client_sends_legacy_authenticated_creation_payload
    server = TCPServer.new("127.0.0.1", 0)
    captured = Queue.new
    response_body = JSON.generate("id" => "job-123")
    thread = Thread.new do
      socket = server.accept
      request_line = socket.gets
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length").to_i)
      captured << [request_line, headers, body]
      socket.write(
        "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\n" \
        "Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}"
      )
      socket.close
    end
    client = VoiceVault::ReplicateClient.new(
      token: "test-token",
      timeout: 5,
      api_url: "http://127.0.0.1:#{server.addr[1]}/v1/predictions"
    )

    assert_equal(
      { "id" => "job-123" },
      client.create_job(
        file_url: "https://example.test/audio.mp3",
        prompt: "Names",
        num_speakers: 2
      )
    )
    request_line, headers, body = captured.pop
    payload = JSON.parse(body)
    assert_match(%r{POST /v1/predictions HTTP/1\.1}, request_line)
    assert_equal "Bearer test-token", headers.fetch("authorization")
    assert_equal VoiceVault::REPLICATE_MODEL_VERSION, payload.fetch("version")
    assert_equal "https://example.test/audio.mp3", payload.dig("input", "file")
    assert_equal 2, payload.dig("input", "num_speakers")
  ensure
    server&.close
    thread&.join
  end

  def test_cli_preserves_original_options_and_loads_token
    config_path = File.join(@temporary_directory, "config.yml")
    archive_path = File.join(@temporary_directory, "archive")
    File.write(config_path, <<~YAML)
      archive_path: #{@temporary_directory}
      replicate_api_token: test-token
    YAML
    CLIFakeClient.result = {
      "status" => "succeeded",
      "output" => { "segments" => [] }
    }
    stdout = StringIO.new
    stderr = StringIO.new

    status = VoiceVault::ReplicateCLI.run(
      [
        "--config", config_path,
        "--file_url", "https://example.test/audio.mp3",
        "--archive_path", archive_path,
        "--num_speakers", "2"
      ],
      stdout: stdout,
      stderr: stderr,
      client_class: CLIFakeClient
    )

    assert_equal 0, status
    assert_equal({ token: "test-token", timeout: 300 }, CLIFakeClient.initialization)
    assert_includes stderr.string, "deprecated"
    assert_path_exists File.join(archive_path, "result.json")
    assert_path_exists File.join(archive_path, "result_cleaned.json")
    assert_path_exists File.join(archive_path, "result_segments.json")
  end

  def test_cli_returns_nonzero_without_artifacts_for_failed_job
    config_path = File.join(@temporary_directory, "config.yml")
    archive_path = File.join(@temporary_directory, "failed-archive")
    File.write(config_path, <<~YAML)
      archive_path: #{@temporary_directory}
      replicate_api_token: test-token
    YAML
    CLIFakeClient.result = { "status" => "canceled", "error" => "stopped" }
    stdout = StringIO.new
    stderr = StringIO.new

    status = VoiceVault::ReplicateCLI.run(
      [
        "--config", config_path,
        "--file_url", "https://example.test/audio.mp3",
        "--archive_path", archive_path
      ],
      stdout: stdout,
      stderr: stderr,
      client_class: CLIFakeClient
    )

    assert_equal 1, status
    assert_includes stderr.string, "canceled"
    refute_path_exists archive_path
  end

  def test_invalid_segment_is_rejected_before_writing_artifacts
    client = FakeClient.new([
      { "status" => "succeeded", "output" => { "segments" => ["invalid"] } }
    ])
    workflow = VoiceVault::ReplicateWorkflow.new(
      client: client,
      stdout: StringIO.new,
      sleeper: ->(_seconds) {}
    )
    archive_path = File.join(@temporary_directory, "invalid-archive")

    error = assert_raises(VoiceVault::Error) do
      workflow.run(
        file_url: "https://example.test/audio.mp3",
        archive_path: archive_path
      )
    end

    assert_match(/invalid segment/, error.message)
    refute_path_exists archive_path
  end

  def test_help_does_not_load_config
    stdout = StringIO.new
    stderr = StringIO.new

    status = VoiceVault::ReplicateCLI.run(["--help"], stdout: stdout, stderr: stderr)

    assert_equal 0, status
    assert_includes stdout.string, "Usage: replicate.rb"
    assert_empty stderr.string
  end
end
