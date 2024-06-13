#!/usr/bin/env ruby
# coding: utf-8

require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'optparse'

@config = YAML.load_file("#{ENV['HOME']}/.config/voice_vault/config.yml")
%w(archive_path).each do |path|
  @config[path].gsub!(/^~\//, ENV['HOME'] + '/')
end

def create_job(file_url, prompt = '', num_speakers)
  uri = URI('https://api.replicate.com/v1/predictions')
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  input = {
    file: file_url,
    prompt: prompt,
    file_url: '',
    group_segments: true,
    offset_seconds: 0,
    transcript_output_format: 'both'
  }
  input[:num_speakers] = num_speakers unless num_speakers.nil?

  request_body = {
    version: 'b9fd8313c0d492bf1ce501b3d188f945389327730773ec1deb6ef233df6ea119',
    input: input
  }.to_json

  request =
    Net::HTTP::Post.new(
      uri.request_uri,
      'Authorization' => "Bearer #{@config['replicate_api_token']}",
      'Content-Type' => 'application/json'
    )
  request.body = request_body

  response = http.request(request)
  JSON.parse(response.body)
end

def check_job_status(job_id)
  uri = URI("https://api.replicate.com/v1/predictions/#{job_id}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  request =
    Net::HTTP::Get.new(
      uri.request_uri,
      'Authorization' => "Bearer #{@config['replicate_api_token']}"
    )

  response = http.request(request)
  JSON.parse(response.body)
end

def save_to_file(data, filename)
  File.open(filename, 'w') { |file| file.write(JSON.pretty_generate(data)) }
  puts "Results saved to #{filename}"
end

def clean_result_file(input_filename, output_filename)
  cleaned_json = `cat #{input_filename} | jq '.output.segments[] | {start: .start, end: .end, speaker: .speaker, text: .text}'`

  File.open(output_filename, 'w') do |file|
    file.write(cleaned_json)
  end

  puts "Cleaned results saved to #{output_filename}"
end

def main
  options = {}

  opt_parser = OptionParser.new do |opts|
    opts.banner = "Usage: script.rb [options]"

    opts.on('-f', '--file_url FILE_URL', 'File URL for processing (required)') do |file_url|
      options[:file_url] = file_url
    end

    opts.on('-p', '--prompt PROMPT', 'Optionalal Vocabulary: provide names, acronyms and loanwords in a list. Use punctuation for best accuracy.') do |prompt|
      options[:prompt] = prompt
    end

    opts.on('-n', '--num_speakers NUM_SPEAKERS', 'Number of speakers (optional, but encouraged)') do |num_speakers|
      options[:num_speakers] = num_speakers.to_i
    end

    opts.on('-a', '--archive_path ARCHIVE_PATH', 'Path to save the archived results (required)') do |archive_path|
      options[:archive_path] = archive_path
    end

    opts.on('-h', '--help', 'Displays help') do
      puts opts
      exit
    end
  end

  opt_parser.parse!

  if options[:archive_path].nil?
    puts "archive path is required."
    puts opt_parser
    exit 1
  end

  if options[:file_url].nil?
    puts "file URL is required."
    puts opt_parser
    exit 1
  end

  file_url = options[:file_url]
  prompt = options[:prompt] || ''
  num_speakers = options[:num_speakers]
  archive_path = options[:archive_path]

  job_response = create_job(file_url, prompt, num_speakers)

  if job_response['error']
    puts "Error creating job: #{job_response['error']}"
    exit 1
  end

  job_id = job_response['id']
  puts "Job created with ID: #{job_id}. Checking status..."

  loop do
    job_status_response = check_job_status(job_id)
    status = job_status_response['status']

    case status
    when 'succeeded'
      puts 'Job succeeded. Saving results...'
      result_file = File.join(archive_path, 'result.json')
      cleaned_result_file = File.join(archive_path, 'result_cleaned.json')
      save_to_file(job_status_response, result_file)
      clean_result_file(result_file, cleaned_result_file)
      break
    when 'failed'
      puts "Job failed: #{job_status_response['error']}"
      break
    when 'cancelled'
      puts "Job cancelled: #{job_status_response['error']}"
      break
    else
      puts "Job status: #{status}. Waiting..."
      sleep 10 # Poll every 10 seconds
    end
  end
end

main if __FILE__ == $PROGRAM_NAME
