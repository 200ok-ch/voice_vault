#!/usr/bin/env ruby
# coding: utf-8

require 'open3'
require 'date'
require 'yaml'
require 'optparse'

@config = YAML.load_file("#{ENV['HOME']}/.config/voice_vault/config.yml")
%w(archive_path whisper_path).each do |path|
  @config[path].gsub!(/^~\//, ENV['HOME'] + '/')
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

def transcribe_to_text(wav_file)
  puts "Transcribe audio to text...\n"
  command = "#{@config['whisper_path']}/main --language auto --model #{@config['whisper_path']}/models/ggml-#{@config['whisper_model']}.bin -t #{@config['whisper_threads']} --file #{wav_file}"
  transcribed_text, _, _ = Open3.capture3(command)
  return transcribed_text
end

def encode_to_mp3(wav_file)
  mp3_file = `mktemp --dry-run --suffix=.mp3`.strip
  command = "ffmpeg -i #{wav_file} #{mp3_file}"
  Open3.capture3(command)
  return mp3_file
end

def save_files(folder, mp3_file, wav_file, transcribed_text = nil)
  `mkdir -p #{folder}`
  `mv #{mp3_file} #{folder}/recording.mp3`
  `rm #{wav_file}`
  File.write("#{folder}/transcription.txt", transcribed_text) unless transcribed_text.nil?
end

options = {}
OptionParser.new do |opts|
  opts.banner = "Usage: voice_vault.rb [options]"

  opts.on('--no-transcription', 'Do not perform transcription') do
    options[:no_transcription] = true
  end

  opts.on('-h', '--help', 'Displays help') do
    puts opts
    exit
  end
end.parse!

sources = `pactl list short sources`
input_source, monitor_source = get_sources(sources)
wav_file = `mktemp --dry-run --suffix=.wav`.strip
capture_audio(wav_file, input_source, monitor_source)
folder = "#{@config['archive_path']}/#{DateTime.now.strftime('%Y-%m-%d_%H-%M-%S')}"
mp3_file = encode_to_mp3(wav_file)

if options[:no_transcription]
  save_files(folder, mp3_file, wav_file)
else
  transcribed_text = transcribe_to_text(wav_file)
  save_files(folder, mp3_file, wav_file, transcribed_text)
end

puts "Recording saved in: #{folder}"
