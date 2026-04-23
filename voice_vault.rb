#!/usr/bin/env ruby
# coding: utf-8

require 'open3'
require 'date'
require 'yaml'
require 'optparse'
require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

@config = YAML.load_file("#{ENV['HOME']}/.config/voice_vault/config.yml")
%w(archive_path whisper_path).each do |path|
  next unless @config[path]

  @config[path].gsub!(/^~\//, ENV['HOME'] + '/')
end

def whisper_provider
  return @config['whisper_provider'] if @config['whisper_provider']
  return 'remote' if @config['whisper_base_url']

  'local'
end

def validate_config!
  case whisper_provider
  when 'local'
    abort 'Missing whisper_path for local whisper provider' if @config['whisper_path'].to_s.empty?
    abort 'Missing whisper_model for local whisper provider' if @config['whisper_model'].to_s.empty?
  when 'remote'
    abort 'Missing whisper_base_url for remote whisper provider' if @config['whisper_base_url'].to_s.empty?
    abort 'Missing whisper_model for remote whisper provider' if @config['whisper_model'].to_s.empty?
  else
    abort "Unsupported whisper_provider: #{whisper_provider}"
  end

  abort 'Missing archive_path' if @config['archive_path'].to_s.empty?
end

def get_sources(sources)
  input_source = `pactl info | grep 'Default Source' | cut -d: -f 2`.strip
  monitor_source =  `pactl info | grep 'Default Sink' | cut -d: -f 2`.strip + ".monitor"
  return input_source, monitor_source
end

def capture_audio(wav_file, input_source, monitor_source)
  puts "Capturing audio to #{wav_file}. Press 'q' to quit."
  `ffmpeg -loglevel quiet -f pulse -ac 2 -ar 16000 -i #{input_source} -f pulse -ac 2 -ar 16000 -i #{monitor_source} -filter_complex\ \"[0:a][1:a]amerge=inputs=2[a]\" -map \"[a]\" -ac 2 #{wav_file}`
end

def diarization_enabled?
  @config['whisper_diarize'] == true || @config['whisper_diarize'].to_s == 'true'
end

def remote_form_fields(wav_file)
  fields = [['file', File.open(wav_file, 'rb')], ['model', @config['whisper_model']]]

  if diarization_enabled?
    fields << ['diarize', 'true']
    fields << ['response_format', 'json']
    fields << ['output_format', 'json']
  end

  {
    'whisper_language' => 'language',
    'whisper_prompt' => 'prompt',
    'whisper_hotwords' => 'hotwords',
    'whisper_num_speakers' => 'num_speakers',
    'whisper_min_speakers' => 'min_speakers',
    'whisper_max_speakers' => 'max_speakers'
  }.each do |config_key, field_name|
    value = @config[config_key]
    fields << [field_name, value.to_s] unless value.nil? || value.to_s.empty?
  end

  fields
end

def stringify_segment_speaker(segment)
  return segment['speaker'] if segment['speaker']
  return segment[:speaker] if segment[:speaker]

  'UNKNOWN'
end

def stringify_segment_text(segment)
  segment['text'] || segment[:text] || ''
end

def render_diarized_text(segments)
  segments.map do |segment|
    "[#{stringify_segment_speaker(segment)}] #{stringify_segment_text(segment).strip}"
  end.join("\n")
end

def extract_remote_transcription_text(payload)
  return payload['text'] if payload['text'].is_a?(String)
  return render_diarized_text(payload['text']) if payload['text'].is_a?(Array)
  return render_diarized_text(payload['segments']) if payload['segments'].is_a?(Array)

  nil
end

def transcribe_locally(wav_file)
  command = [
    "#{@config['whisper_path']}/main",
    '--language', 'auto',
    '--model', "#{@config['whisper_path']}/models/ggml-#{@config['whisper_model']}.bin",
    '-t', @config['whisper_threads'].to_s,
    '--file', wav_file
  ]
  transcribed_text, stderr, status = Open3.capture3(*command)

  return { text: transcribed_text, payload: nil } if status.success?

  abort "Local whisper transcription failed: #{stderr}"
end

def remote_transcription_uri
  URI("#{@config['whisper_base_url'].sub(%r{/*$}, '')}/v1/audio/transcriptions")
end

def whisper_open_timeout
  (@config['whisper_open_timeout'] || 30).to_i
end

def whisper_read_timeout
  (@config['whisper_read_timeout'] || 3600).to_i
end

def whisper_write_timeout
  (@config['whisper_write_timeout'] || 300).to_i
end

def parse_json_response(response)
  JSON.parse(response.body)
rescue JSON::ParserError
  nil
end

def response_body_excerpt(response, limit = 500)
  body = response.body.to_s.strip
  return '(empty response body)' if body.empty?

  body.length > limit ? "#{body[0, limit]}..." : body
end

def remote_error_message(response, payload)
  if payload
    error_message = payload['error']
    error_message = error_message['message'] if error_message.is_a?(Hash)
    return error_message if error_message && !error_message.to_s.empty?
  end

  "HTTP #{response.code} #{response.message}: #{response_body_excerpt(response)}"
end

def transcribe_remotely(wav_file)
  uri = remote_transcription_uri
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == 'https'
  http.open_timeout = whisper_open_timeout
  http.read_timeout = whisper_read_timeout
  http.write_timeout = whisper_write_timeout if http.respond_to?(:write_timeout=)

  form_fields = remote_form_fields(wav_file)

  begin
    request = Net::HTTP::Post.new(uri)
    request['Authorization'] = "Bearer #{@config['whisper_api_token']}" unless @config['whisper_api_token'].to_s.empty?
    request.set_form(form_fields, 'multipart/form-data')

    response = http.request(request)
    payload = parse_json_response(response)
    transcription_text = payload ? extract_remote_transcription_text(payload) : nil

    return({ text: transcription_text, payload: payload }) if response.is_a?(Net::HTTPSuccess) && transcription_text

    abort "Remote whisper transcription failed: #{remote_error_message(response, payload)}"
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    abort "Remote whisper transcription timed out after #{whisper_read_timeout}s read timeout. Increase whisper_read_timeout in config if long files need more time. Original error: #{e.class}"
  ensure
    form_fields.each do |field|
      field[1].close if field[1].respond_to?(:close)
    end
  end
end

def transcribe_to_text(wav_file)
  puts "Transcribe audio to text...\n"

  case whisper_provider
  when 'local'
    transcribe_locally(wav_file)
  when 'remote'
    transcribe_remotely(wav_file)
  else
    abort "Unsupported whisper_provider: #{whisper_provider}"
  end
end

def encode_to_mp3(wav_file)
  mp3_file = `mktemp --dry-run --suffix=.mp3`.strip
  _, stderr, status = Open3.capture3('ffmpeg', '-loglevel', 'quiet', '-i', wav_file, mp3_file)

  return mp3_file if status.success?

  abort "MP3 encoding failed: #{stderr}"
end

def convert_to_wav(source_file)
  wav_file = `mktemp --dry-run --suffix=.wav`.strip
  _, stderr, status = Open3.capture3('ffmpeg', '-loglevel', 'quiet', '-i', source_file, '-ac', '2', '-ar', '16000', wav_file)

  return wav_file if status.success?

  abort "Audio conversion failed: #{stderr}"
end

def prepare_source_audio(source_file)
  wav_file = convert_to_wav(source_file)

  if File.extname(source_file).downcase == '.mp3'
    mp3_file = `mktemp --dry-run --suffix=.mp3`.strip
    FileUtils.cp(source_file, mp3_file)
  else
    mp3_file = encode_to_mp3(wav_file)
  end

  [wav_file, mp3_file]
end

def save_remote_payload(folder, payload)
  return if payload.nil?

  File.write("#{folder}/result.json", JSON.pretty_generate(payload))

  diarized_segments = payload['segments'] || payload['text']
  return unless diarized_segments.is_a?(Array)

  File.write("#{folder}/result_cleaned.json", JSON.pretty_generate(diarized_segments))
end

def save_files(folder, mp3_file, wav_file, transcription_result = nil)
  FileUtils.mkdir_p(folder)
  FileUtils.mv(mp3_file, "#{folder}/recording.mp3")
  File.delete(wav_file)

  return if transcription_result.nil?

  File.write("#{folder}/transcription.txt", transcription_result[:text]) unless transcription_result[:text].nil?
  save_remote_payload(folder, transcription_result[:payload])
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: voice_vault.rb [options]"

  opts.on('-f', '--file FILE', 'Transcribe an existing audio file instead of recording') do |file|
    options[:file] = file
  end

  opts.on('--no-transcription', 'Do not perform transcription') do
    options[:no_transcription] = true
  end

  opts.on('-h', '--help', 'Displays help') do
    puts opts
    exit
  end
end.parse!

validate_config!

folder = "#{@config['archive_path']}/#{DateTime.now.strftime('%Y-%m-%d_%H-%M-%S')}"

if options[:file]
  abort "Audio file not found: #{options[:file]}" unless File.exist?(options[:file])

  wav_file, mp3_file = prepare_source_audio(options[:file])
else
  sources = `pactl list short sources`
  input_source, monitor_source = get_sources(sources)
  wav_file = `mktemp --dry-run --suffix=.wav`.strip
  capture_audio(wav_file, input_source, monitor_source)
  mp3_file = encode_to_mp3(wav_file)
end

if options[:no_transcription]
  save_files(folder, mp3_file, wav_file)
else
  transcription_result = transcribe_to_text(wav_file)
  save_files(folder, mp3_file, wav_file, transcription_result)
end

puts "Recording saved in: #{folder}"
