#!/usr/bin/env ruby
# coding: utf-8

require 'open3'
require 'date'

sources = `pactl list short sources`
input_source = ''
monitor_source = ''

sources.each_line do |line|
  tokens = line.split("\t")
  source = tokens[1]
  if source.include?('analog-stereo.echo-cancel')
    if source.start_with?('alsa_input')
      input_source = source
    elsif source.start_with?('alsa_output')
      monitor_source = source
    end
  end
end

wav_file = `mktemp --dry-run --suffix=.wav`.strip
command = "ffmpeg -f pulse -ac 2 -ar 16000 -i #{input_source} -f pulse -ac 2 -ar 16000 -i #{monitor_source} -filter_complex\ \"[0:a][1:a]amerge=inputs=2[a]\" -map \"[a]\" -ac 2 #{wav_file}"

# Putting ffmpeg in a separate thread, so that it can be quit with
# Ctrl-c at any time without ending the Ruby script or throwing error
# messages.
begin
  puts "Capturing audio to #{wav_file}...\n"
  stdin, stdout, stderr, _ = Open3.popen3(command)
  stdin.close
  stdout.read.chomp
  stderr.read.chomp
  stdout.close
  stderr.close
rescue SystemExit, Interrupt

end

puts "Transcoding to text...\n"
command = "/home/munen/src/whisper.cpp/main --language auto --model /home/munen/src/whisper.cpp/models/ggml-small.bin -t 8 --file #{wav_file}"
transcribed_text, _, _ = Open3.capture3(command)

# puts "Encoding to mp3...\n"
mp3_file = `mktemp --dry-run --suffix=.mp3`.strip

folder = "/tmp/#{DateTime.now.strftime('%Y-%m-%d_%H-%M-%S')}"
`mkdir #{folder}`

command = "ffmpeg -i #{wav_file} #{mp3_file}"
Open3.capture3(command)

`mv #{mp3_file} #{folder}/recording.mp3`
`rm #{wav_file}`
File.write("#{folder}/transcription.txt", transcribed_text)

puts "Recording and transcription: #{folder}"
