# Changelog

## 1.0.1 - 2026-07-15

### Fixed

- Explicitly enable FFmpeg standard-input interaction so pressing `q`
  reliably stops and finalizes live recordings.

## 1.0.0 - 2026-07-15

First versioned release.

### Added

- Recommended `transcribe` provider with speaker diarization and executable
  discovery through `PATH`.
- Provider-specific architecture for `transcribe`, local whisper.cpp, and
  remote Whisper APIs.
- Support for both whisper.cpp's historical `main` binary and current
  `whisper-cli` binary.
- Collision-safe archive directory names.
- Owner-only permissions for newly archived recordings and transcripts.
- `--config` and `--version` command-line options.
- Automated coverage for recording, imports, all providers, failure recovery,
  configuration compatibility, and the deprecated Replicate workflow.

### Changed

- Audio is archived before transcription begins.
- Transcription failures retain `recording.mp3`, remove partial result files,
  report the archive path, and return a nonzero exit status.
- Temporary audio uses private, automatically cleaned directories.
- External commands receive argument arrays instead of interpolated shell
  strings.
- Non-MP3 imports are converted directly unless local whisper.cpp requires a
  normalized WAV.
- Replicate now writes a valid cleaned JSON array to `result_segments.json`.

### Compatibility

- Existing CLI options are unchanged.
- Existing local and remote configuration keys and provider inference remain
  supported.
- Existing remote `result.json`, `result_cleaned.json`, and timestamped text
  output remain supported.
- The standalone `replicate.rb` command and `replicate_api_token` setting
  remain available.
- Replicate's `result_cleaned.json` JSON stream remains available with its
  historical shape.

### Deprecated

- `replicate.rb` is retained for compatibility but new installations should
  use the `transcribe` provider.
