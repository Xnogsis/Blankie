//
//  MixExporter.swift
//  Blankie
//
//  Created by Cody Bromley on 6/29/26.
//

import AVFoundation
import Accelerate
import Foundation
import Observation
import os

/// Offline mixdown of the current mix: each audible sound is looped (or
/// played once, for non-looping sounds) for the chosen duration at its
/// effective gain, summed, peak-limited, and written as stereo AAC.
@Observable
@MainActor
final class MixExporter {
  static let shared = MixExporter()

  enum Duration: Int, CaseIterable, Identifiable {
    case oneMinute = 1
    case fiveMinutes = 5
    case tenMinutes = 10
    case thirtyMinutes = 30
    case oneHour = 60

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }

    var label: String {
      switch self {
      case .oneMinute: String(localized: "1 Minute")
      case .fiveMinutes: String(localized: "5 Minutes")
      case .tenMinutes: String(localized: "10 Minutes")
      case .thirtyMinutes: String(localized: "30 Minutes")
      case .oneHour: String(localized: "1 Hour")
      }
    }
  }

  enum ExportError: LocalizedError {
    case nothingToExport
    case alreadyExporting
    case fileNotFound(String)
    case renderFailed

    var errorDescription: String? {
      switch self {
      case .nothingToExport:
        String(localized: "No sounds are playing to export")
      case .alreadyExporting:
        String(localized: "An export is already in progress")
      case .fileNotFound(let name):
        String(localized: "Missing sound file: \(name)")
      case .renderFailed:
        String(localized: "Couldn't render the mix")
      }
    }
  }

  private(set) var isExporting = false
  private(set) var progress: Double = 0

  /// One source in the mixdown.
  struct Track {
    let url: URL
    let gain: Float
    let loops: Bool
  }

  /// Sounds that are audible right now: the solo sound alone when solo mode is
  /// active, else every selected sound. Skips gain-0 sounds and throws for the
  /// first sound whose file can't be found.
  func currentTracks() throws -> [Track] {
    let audio = AudioManager.shared
    let audible: [Sound]
    if let solo = audio.soloModeSound {
      audible = [solo]
    } else {
      audible = audio.sounds.filter(\.isSelected)
    }

    var tracks: [Track] = []
    for sound in audible {
      let gain = sound.mixdownGain()
      guard gain > 0 else { continue }
      guard let url = sound.getSoundURL() else {
        throw ExportError.fileNotFound(sound.title)
      }
      let loops =
        SoundCustomizationManager.shared.getCustomization(for: sound.fileName)?.loopSound ?? true
      tracks.append(Track(url: url, gain: gain, loops: loops))
    }
    return tracks
  }

  /// Base name (no extension) for the exported file: the solo sound's title,
  /// "Quick Mix", the active preset's name, or "Blankie Mix" — sanitized for
  /// filesystem use.
  static func suggestedFileName() -> String {
    let audio = AudioManager.shared
    let name: String
    if let solo = audio.soloModeSound {
      name = solo.localizedTitle
    } else if audio.isQuickMix {
      name = String(localized: "Quick Mix")
    } else if let preset = PresetManager.shared.currentPreset, !preset.isDefault {
      name = preset.name
    } else {
      name = String(localized: "Blankie Mix")
    }
    return
      name
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
  }

  /// Renders `tracks` for `duration` into a temp .m4a and returns its URL.
  /// Sets `isExporting`/`progress` while running; the caller moves or shares
  /// the returned file and deletes it when done.
  func export(tracks: [Track], duration: Duration, fileName: String) async throws -> URL {
    guard !isExporting else { throw ExportError.alreadyExporting }
    guard !tracks.isEmpty else { throw ExportError.nothingToExport }
    isExporting = true
    progress = 0
    defer { isExporting = false }

    let url = try await Self.render(tracks: tracks, duration: duration, fileName: fileName) {
      [weak self] value in
      Task { @MainActor in self?.progress = value }
    }
    progress = 1
    return url
  }

  /// Per-track decode state kept alive across the chunk loop.
  private final class TrackReader {
    let file: AVAudioFile
    let converter: AVAudioConverter
    var gain: Float
    let loops: Bool
    var finished = false

    init(track: Track, outputFormat: AVAudioFormat) throws {
      file = try AVAudioFile(forReading: track.url)
      guard
        let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat)
      else { throw ExportError.renderFailed }
      self.converter = converter
      gain = track.gain
      loops = track.loops
    }
  }

  /// Chunked render: converts each track into a scratch buffer in the output
  /// format (the converter handles rate and channel mapping), accumulates it
  /// into the mix at the track's gain, peak-limits, and writes the chunk.
  /// Runs off the main actor; `onProgress` fires at most ~20 times.
  private nonisolated static func render(
    tracks: [Track],
    duration: Duration,
    fileName: String,
    onProgress: @Sendable (Double) -> Void
  ) async throws -> URL {
    guard
      let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
    else { throw ExportError.renderFailed }

    let finalURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(fileName).m4a")
    let renderURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("\(fileName)-render-\(UUID().uuidString).m4a")
    try? FileManager.default.removeItem(at: renderURL)

    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 44_100,
      AVNumberOfChannelsKey: 2,
      AVEncoderBitRateKey: 192_000,
    ]
    let outFile = try AVAudioFile(forWriting: renderURL, settings: settings)

    let readers = try tracks.map { try TrackReader(track: $0, outputFormat: outputFormat) }

    let totalFrames = AVAudioFrameCount(duration.seconds * outputFormat.sampleRate)
    let chunkFrames: AVAudioFrameCount = 44_100
    let channelCount = Int(outputFormat.channelCount)
    var framesDone: AVAudioFrameCount = 0
    var framesSinceReport: AVAudioFrameCount = 0

    // Peak limiter state persists across chunks so the release envelope
    // doesn't restart each second.
    var gainReduction: Float = 1
    let ceiling: Float = 0.98
    let release = 1 - expf(-1 / (Float(outputFormat.sampleRate) * 0.2))

    while framesDone < totalFrames {
      try Task.checkCancellation()

      let frames = min(chunkFrames, totalFrames - framesDone)
      guard
        let mix = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames),
        let scratch = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frames)
      else { throw ExportError.renderFailed }
      mix.frameLength = frames
      for c in 0..<channelCount {
        mix.floatChannelData![c].initialize(repeating: 0, count: Int(frames))
      }

      for reader in readers where !reader.finished {
        scratch.frameLength = 0
        var conversionError: NSError?
        let file = reader.file
        let loops = reader.loops
        let status = reader.converter.convert(to: scratch, error: &conversionError) {
          packetCount, outStatus in
          if file.framePosition >= file.length {
            if loops {
              file.framePosition = 0
            } else {
              outStatus.pointee = .endOfStream
              return nil
            }
          }
          guard
            let input = AVAudioPCMBuffer(
              pcmFormat: file.processingFormat, frameCapacity: packetCount)
          else {
            outStatus.pointee = .endOfStream
            return nil
          }
          do {
            try file.read(into: input, frameCount: packetCount)
          } catch {
            outStatus.pointee = .endOfStream
            return nil
          }
          if input.frameLength == 0 {
            if loops, file.length > 0 {
              file.framePosition = 0
              try? file.read(into: input, frameCount: packetCount)
            }
            guard input.frameLength > 0 else {
              outStatus.pointee = .endOfStream
              return nil
            }
          }
          outStatus.pointee = .haveData
          return input
        }

        let produced = Int(scratch.frameLength)
        if produced > 0, let mixData = mix.floatChannelData,
          let trackData = scratch.floatChannelData
        {
          for c in 0..<channelCount {
            var gain = reader.gain
            vDSP_vsma(
              trackData[c], 1, &gain, mixData[c], 1, mixData[c], 1, vDSP_Length(produced))
          }
        }
        if status == .endOfStream || status == .error {
          reader.finished = true
        }
      }

      // Per-frame peak limiter over the summed mix.
      let frameCount = Int(frames)
      if channelCount == 2, let data = mix.floatChannelData {
        let left = data[0]
        let right = data[1]
        for i in 0..<frameCount {
          let peak = max(abs(left[i]), abs(right[i]))
          if peak * gainReduction > ceiling {
            gainReduction = ceiling / peak
          } else {
            gainReduction += (1 - gainReduction) * release
          }
          left[i] *= gainReduction
          right[i] *= gainReduction
        }
      }

      try outFile.write(from: mix)

      framesDone += frames
      framesSinceReport += frames
      // ~20 progress updates across the whole render.
      if framesSinceReport >= totalFrames / 20 || framesDone == totalFrames {
        onProgress(Double(framesDone) / Double(totalFrames))
        framesSinceReport = 0
      }
    }

    // A cancelled/failed render never leaves a half-written file at the
    // caller-facing URL; move the finished render into place atomically.
    try? FileManager.default.removeItem(at: finalURL)
    try FileManager.default.moveItem(at: renderURL, to: finalURL)
    return finalURL
  }
}
