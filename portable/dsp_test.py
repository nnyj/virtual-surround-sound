"""Offline audio checks for the shared CamillaDSP pipeline."""

import math
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from dsp import build_config, validate_hrir, write_config

ENGINE = os.environ.get("CAMILLADSP")
if len(sys.argv) > 2 and sys.argv[1] == "--engine":
  ENGINE = sys.argv[2]
  del sys.argv[1:3]

def make_hrir(path, channels=14, truncate=False):
  samples = [0.02 * (channel + 1) for channel in range(channels)]
  samples += [0.005 * (channel + 1) for channel in range(channels)]
  data = struct.pack(f"<{len(samples)}f", *samples)
  fmt = struct.pack("<HHIIHH", 3, channels, 48000, 48000 * channels * 4, channels * 4, 32)
  body = b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt
  body += b"data" + struct.pack("<I", len(data)) + data
  wav = b"RIFF" + struct.pack("<I", len(body)) + body
  path.write_bytes(wav[:-1] if truncate else wav)

def make_input(path, values):
  raw = bytearray(len(values) * 4)
  for index, value in enumerate(values):
    struct.pack_into("<f", raw, index * 4, value)
  path.write_bytes(raw)

def run_engine(folder, hrir, values, eq=None, capture_channels=8):
  input_path = folder / "input.raw"
  output_path = folder / "output.raw"
  config_path = folder / "config.yml"
  make_input(input_path, values)
  profile = {"hrir_path": str(hrir)}
  if eq is not None:
    profile["headphone_eq"] = eq
  capture = {"type": "RawFile", "channels": capture_channels, "filename": str(input_path), "format": "F32_LE"}
  playback = {"type": "File", "channels": 2, "filename": str(output_path), "format": "F32_LE"}
  config = build_config(profile, capture, playback)
  write_config(config_path, config)
  checked = subprocess.run([ENGINE, "--check", str(config_path)], capture_output=True, text=True, timeout=15)
  if checked.returncode:
    raise AssertionError(checked.stderr)
  played = subprocess.run([ENGINE, str(config_path)], capture_output=True, text=True, timeout=15)
  if played.returncode:
    raise AssertionError(played.stderr)
  raw = output_path.read_bytes()
  return struct.unpack(f"<{len(raw) // 4}f", raw)

class DspTest(unittest.TestCase):
  def setUp(self):
    self.temp = tempfile.TemporaryDirectory()
    self.addCleanup(self.temp.cleanup)
    self.folder = Path(self.temp.name)
    self.hrir = self.folder / "hrir.wav"
    make_hrir(self.hrir)

  def test_hrir_metadata_and_boundaries(self):
    self.assertEqual(validate_hrir(self.hrir), {"sample_rate": 48000, "frames": 2, "channels": 14})
    make_hrir(self.hrir, channels=7)
    self.assertEqual(validate_hrir(self.hrir), {"sample_rate": 48000, "frames": 2, "channels": 7})
    make_hrir(self.hrir, channels=13)
    with self.assertRaisesRegex(ValueError, "7 or 14 channels"):
      validate_hrir(self.hrir)
    make_hrir(self.hrir, truncate=True)
    with self.assertRaisesRegex(ValueError, "truncated"):
      validate_hrir(self.hrir)

  def test_rate_mismatch(self):
    with self.assertRaisesRegex(ValueError, "match HRIR rate"):
      build_config({"hrir_path": str(self.hrir), "sample_rate": 44100}, {"channels": 8}, {"channels": 2})

  def test_sixteen_channel_capture_uses_first_eight(self):
    config = build_config({"hrir_path": str(self.hrir)}, {"type": "CoreAudio", "channels": 16}, {"type": "CoreAudio", "channels": 2})
    self.assertTrue(config["devices"]["enable_rate_adjust"])
    self.assertEqual(config["devices"]["resampler"], {"type": "AsyncSinc", "profile": "Balanced"})
    if ENGINE:
      values = [0.0] * (1024 * 16)
      values[128 * 16] = 0.25
      for channel in range(8, 16):
        values[512 * 16 + channel] = 0.5
      output = run_engine(self.folder, self.hrir, values, capture_channels=16)
      self.assertAlmostEqual(max(output[0::2]), 0.25 * 10 ** (-12 / 20) * 0.02, delta=2e-5)
      self.assertLess(max(abs(value) for value in output[768 * 2:]), 2e-5)
      if sys.platform.startswith("linux"):
        capture = {"type": "PipeWire", "channels": 8, "node_name": "vss_capture"}
        playback = {"type": "PipeWire", "channels": 2, "node_name": "vss_playback", "autoconnect_to": "alsa_output.example"}
      elif sys.platform == "darwin":
        capture = {"type": "CoreAudio", "channels": 16, "device": "BlackHole 16ch"}
        playback = {"type": "CoreAudio", "channels": 2, "device": None}
      else:
        return
      config_path = self.folder / "native.yml"
      write_config(config_path, build_config({"hrir_path": str(self.hrir)}, capture, playback))
      checked = subprocess.run([ENGINE, "--check", str(config_path)], capture_output=True, text=True, timeout=15)
      self.assertEqual(checked.returncode, 0, checked.stderr)

  @unittest.skipUnless(ENGINE, "set CAMILLADSP to run audio checks")
  def test_all_eight_inputs_and_lfe_gain(self):
    frames = 17408
    values = [0.0] * (frames * 8)
    for source in range(8):
      values[(256 + 2048 * source) * 8 + source] = 0.25
    # Independent HeSuVi WAV order: FL, FR, FC, LFE, RL, RR, SL, SR.
    expected_hrir = ((0, 1), (8, 7), (6, 13), (6, 13), (4, 5), (12, 11), (2, 3), (10, 9))
    for channels in (14, 7):
      with self.subTest(hrir_channels=channels):
        make_hrir(self.hrir, channels=channels)
        output = run_engine(self.folder, self.hrir, values)
        self.assertGreaterEqual(len(output), 2 * 16896)
        first_peak = max(range(512), key=lambda frame: abs(output[frame * 2]))
        delay = first_peak - 256
        self.assertGreaterEqual(delay, 0)
        self.assertLess(delay, 256)
        expected_indices = set()
        for source, ear_channels in enumerate(expected_hrir):
          frame = 256 + 2048 * source + delay
          for ear, track in enumerate(ear_channels):
            hrir_channel = track % channels
            if source == 3:
              samples = [output[(frame + tap) * 2 + ear] for tap in range(1024)]
              expected_total = 0.25 * 10 ** (-12 / 20) * 2 * 0.025 * (hrir_channel + 1)
              self.assertAlmostEqual(sum(samples), expected_total, delta=1e-4)
              self.assertLess(abs(samples[0]), expected_total * 0.001)
              expected_indices.update((frame + tap) * 2 + ear for tap in range(1024))
              continue
            for tap, coefficient in enumerate((0.02, 0.005)):
              expected = 0.25 * 10 ** (-12 / 20) * coefficient * (hrir_channel + 1)
              output_index = (frame + tap) * 2 + ear
              self.assertAlmostEqual(output[output_index], expected, delta=2e-5)
              expected_indices.add(output_index)
        unexpected = max(abs(value) for index, value in enumerate(output) if index not in expected_indices)
        self.assertLess(unexpected, 2e-5)

  @unittest.skipUnless(ENGINE, "set CAMILLADSP to run audio checks")
  def test_headphone_eq_at_center_frequency(self):
    frames = 48000
    values = [0.0] * (frames * 8)
    for frame in range(frames):
      values[frame * 8] = 0.25 * math.sin(2 * math.pi * 1000 * frame / 48000)
    plain = run_engine(self.folder, self.hrir, values)
    eq = [{"type": "Peaking", "freq": 1000, "gain": -6, "q": 1}]
    corrected = run_engine(self.folder, self.hrir, values, eq=eq)
    start = 24000 * 2
    plain_rms = math.sqrt(sum(value * value for value in plain[start::2]) / len(plain[start::2]))
    eq_rms = math.sqrt(sum(value * value for value in corrected[start::2]) / len(corrected[start::2]))
    self.assertAlmostEqual(eq_rms / plain_rms, 10 ** (-6 / 20), delta=0.01)

if __name__ == "__main__":
  unittest.main()
