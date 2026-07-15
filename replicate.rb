#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "net/http"
require "optparse"
require "uri"
require_relative "voice_vault"

module VoiceVault
  REPLICATE_MODEL_VERSION = "b9fd8313c0d492bf1ce501b3d188f945389327730773ec1deb6ef233df6ea119"

  class ReplicateClient
    API_URL = "https://api.replicate.com/v1/predictions"

    def initialize(token:, timeout: 300, api_url: API_URL)
      @token = token
      @timeout = timeout
      @api_url = api_url
    end

    def create_job(file_url:, prompt:, num_speakers:)
      input = {
        file: file_url,
        prompt: prompt,
        file_url: "",
        group_segments: true,
        offset_seconds: 0,
        transcript_output_format: "both"
      }
      input[:num_speakers] = num_speakers if num_speakers
      post_json(
        URI(@api_url),
        version: REPLICATE_MODEL_VERSION,
        input: input
      )
    end

    def job_status(job_id)
      uri = URI("#{@api_url}/#{URI.encode_www_form_component(job_id)}")
      request_json(uri, Net::HTTP::Get.new(uri))
    end

    private

    def post_json(uri, body)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)
      request_json(uri, request)
    end

    def request_json(uri, request)
      request["Authorization"] = "Bearer #{@token}"
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Replicate request failed: HTTP #{response.code} #{response.message}"
      end

      parsed = JSON.parse(response.body)
      raise Error, "Replicate returned an invalid response" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError => e
      raise Error, "Replicate returned invalid JSON: #{e.message}"
    rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "Replicate request failed: #{e.class}: #{e.message}"
    end
  end

  class ReplicateWorkflow
    def initialize(client:, stdout: $stdout, sleeper: ->(seconds) { sleep(seconds) })
      @client = client
      @stdout = stdout
      @sleeper = sleeper
    end

    def run(file_url:, archive_path:, prompt: "", num_speakers: nil, poll_interval: 10)
      job = @client.create_job(
        file_url: file_url,
        prompt: prompt,
        num_speakers: num_speakers
      )
      raise Error, "Error creating Replicate job: #{job["error"]}" if job["error"]

      job_id = job["id"]
      raise Error, "Replicate did not return a job ID" if job_id.to_s.empty?

      @stdout.puts "Job created with ID: #{job_id}. Checking status..."
      loop do
        result = @client.job_status(job_id)
        case result["status"]
        when "succeeded"
          save_results(archive_path, result)
          return
        when "failed", "canceled", "cancelled", "aborted"
          raise Error, "Replicate job #{result["status"]}: #{result["error"]}"
        when "starting", "processing"
          @stdout.puts "Job status: #{result["status"]}. Waiting..."
          @sleeper.call(poll_interval)
        else
          raise Error, "Replicate returned unknown job status: #{result["status"].inspect}"
        end
      end
    end

    private

    def save_results(archive_path, result)
      segments = result.dig("output", "segments")
      raise Error, "Replicate response did not contain output segments" unless segments.is_a?(Array)

      cleaned_segments = segments.map do |segment|
        raise Error, "Replicate response contained an invalid segment" unless segment.is_a?(Hash)

        {
          "start" => segment["start"],
          "end" => segment["end"],
          "speaker" => segment["speaker"],
          "text" => segment["text"]
        }
      end
      FileUtils.mkdir_p(archive_path, mode: 0o700)
      write_private(File.join(archive_path, "result.json"), JSON.pretty_generate(result))
      legacy_stream = cleaned_segments.map { |segment| JSON.pretty_generate(segment) }.join("\n")
      write_private(
        File.join(archive_path, "result_cleaned.json"),
        legacy_stream.empty? ? "" : "#{legacy_stream}\n"
      )
      write_private(
        File.join(archive_path, "result_segments.json"),
        JSON.pretty_generate(cleaned_segments)
      )
      @stdout.puts "Results saved in #{archive_path}"
    end

    def write_private(path, content)
      File.open(path, "w", 0o600) do |file|
        file.chmod(0o600)
        file.write(content)
      end
    end
  end

  class ReplicateCLI
    def self.run(argv, stdout: $stdout, stderr: $stderr, client_class: ReplicateClient)
      options = {
        config_path: DEFAULT_CONFIG_PATH,
        poll_interval: 10,
        timeout: 300
      }
      parser = option_parser(options)
      parser.parse!(argv)

      if options[:help]
        stdout.puts parser
        return 0
      end
      validate_options(options, argv)

      config = Config.load(File.expand_path(options[:config_path]))
      token = config.required_string("replicate_api_token", context: "Replicate")
      client = client_class.new(token: token, timeout: options[:timeout])
      stderr.puts "Warning: replicate.rb is deprecated; use the transcribe provider for new setups."
      ReplicateWorkflow.new(client: client, stdout: stdout).run(
        file_url: options[:file_url],
        archive_path: File.expand_path(options[:archive_path]),
        prompt: options[:prompt] || "",
        num_speakers: options[:num_speakers],
        poll_interval: options[:poll_interval]
      )
      0
    rescue OptionParser::ParseError => e
      stderr.puts e.message
      stderr.puts "Run `replicate.rb --help` for usage."
      64
    rescue Error, SystemCallError => e
      stderr.puts e.message
      1
    end

    def self.option_parser(options)
      OptionParser.new do |parser|
        parser.banner = "Usage: replicate.rb --file_url URL --archive_path PATH [options]"
        parser.on("-f", "--file_url URL", "Public audio URL (required)") do |value|
          options[:file_url] = value
        end
        parser.on("-a", "--archive_path PATH", "Existing Voice Vault archive (required)") do |value|
          options[:archive_path] = value
        end
        parser.on("-p", "--prompt PROMPT", "Optional vocabulary and context prompt") do |value|
          options[:prompt] = value
        end
        parser.on("-n", "--num_speakers COUNT", Integer, "Expected number of speakers") do |value|
          options[:num_speakers] = value
        end
        parser.on("--poll-interval SECONDS", Integer, "Polling interval (default: 10)") do |value|
          options[:poll_interval] = value
        end
        parser.on("--timeout SECONDS", Integer, "HTTP timeout (default: 300)") do |value|
          options[:timeout] = value
        end
        parser.on("--config PATH", "Voice Vault config (default: #{DEFAULT_CONFIG_PATH})") do |value|
          options[:config_path] = value
        end
        parser.on("-h", "--help", "Show this help") do
          options[:help] = true
        end
      end
    end

    def self.validate_options(options, argv)
      raise OptionParser::InvalidArgument, "unexpected arguments: #{argv.join(" ")}" unless argv.empty?
      raise OptionParser::MissingArgument, "--file_url" unless options[:file_url]
      raise OptionParser::MissingArgument, "--archive_path" unless options[:archive_path]
      if options[:num_speakers] && options[:num_speakers] <= 0
        raise OptionParser::InvalidArgument, "--num_speakers must be positive"
      end
      raise OptionParser::InvalidArgument, "--poll-interval must be positive" unless options[:poll_interval].positive?
      raise OptionParser::InvalidArgument, "--timeout must be positive" unless options[:timeout].positive?

      uri = URI.parse(options[:file_url])
      unless uri.is_a?(URI::HTTP) && uri.host
        raise OptionParser::InvalidArgument, "--file_url must be a full HTTP(S) URL"
      end
    rescue URI::InvalidURIError
      raise OptionParser::InvalidArgument, "--file_url must be a full HTTP(S) URL"
    end

    private_class_method :option_parser, :validate_options
  end
end

exit VoiceVault::ReplicateCLI.run(ARGV) if $PROGRAM_NAME == __FILE__
