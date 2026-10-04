"""Build a CamillaDSP 4.1 binaural pipeline from a HeSuVi HRIR."""

import json
import math
import struct
from pathlib import Path

# Capture channel order is fixed at the platform boundary.
INPUT_CHANNELS = ("FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR")

# HeSuVi stores left speaker ears L/R, then center L, then right speaker
# ears R/L, then center R. Seven-channel files reuse these tracks twice.
# LFE uses the center responses.
HRIR_CHANNELS = {
  "FL": (0, 1),
  "FR": (8, 7),
  "FC": (6, 13),
  "RL": (4, 5),
  "RR": (12, 11),
  "SL": (2, 3),
  "SR": (10, 9),
}

def validate_hrir(path):
  """Return the WAV sample rate and frame count, or raise ValueError."""
  path = Path(path)
  try:
    with path.open("rb") as wav:
      header = wav.read(12)
      if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
        raise ValueError("HRIR must be a RIFF WAVE file")
      riff_end = struct.unpack_from("<I", header, 4)[0] + 8
      if riff_end > path.stat().st_size:
        raise ValueError("HRIR has a truncated RIFF body")
      fmt = None
      data_size = None
      while wav.tell() < riff_end:
        chunk = wav.read(8)
        if len(chunk) != 8:
          raise ValueError("HRIR has a truncated WAV chunk")
        chunk_id, size = struct.unpack("<4sI", chunk)
        if wav.tell() + size + (size & 1) > riff_end:
          raise ValueError("HRIR has a truncated WAV chunk")
        if chunk_id == b"fmt ":
          if fmt is not None:
            raise ValueError("HRIR has duplicate format chunks")
          fmt = wav.read(min(size, 40))
          if len(fmt) != min(size, 40):
            raise ValueError("HRIR has a truncated format chunk")
          wav.seek(size - len(fmt), 1)
        elif chunk_id == b"data":
          if data_size is not None:
            raise ValueError("HRIR has duplicate audio data chunks")
          data_size = size
          wav.seek(size, 1)
        else:
          wav.seek(size, 1)
        wav.seek(size & 1, 1)
      if fmt is None or data_size is None or len(fmt) < 16:
        raise ValueError("HRIR needs WAV format and audio data chunks")
      kind, channels, rate, byte_rate, block_align, bits = struct.unpack_from("<HHIIHH", fmt)
      if kind == 0xFFFE:
        if len(fmt) < 40 or struct.unpack_from("<H", fmt, 16)[0] < 22:
          raise ValueError("HRIR has an invalid extensible WAV format")
        if fmt[26:40] != bytes.fromhex("000000001000800000aa00389b71"):
          raise ValueError("HRIR has an unsupported extensible WAV subformat")
        kind = struct.unpack_from("<H", fmt, 24)[0]
      if kind not in (1, 3) or (kind == 1 and bits not in (16, 24, 32)) or (kind == 3 and bits != 32):
        raise ValueError("HRIR must contain PCM or IEEE float samples")
      if channels not in (7, 14):
        raise ValueError(f"HeSuVi HRIR needs 7 or 14 channels, found {channels}")
      if rate < 8000 or rate > 192000:
        raise ValueError(f"HRIR has an unsupported sample rate: {rate}")
      if block_align != channels * (bits // 8) or byte_rate != rate * block_align:
        raise ValueError("HRIR WAV format has inconsistent frame size")
      if data_size == 0 or data_size % block_align:
        raise ValueError("HRIR WAV data is empty or has incomplete frames")
      return {"sample_rate": rate, "frames": data_size // block_align, "channels": channels}
  except OSError as error:
    raise ValueError(f"Cannot read HRIR: {path}: {error}") from error

def _gain(value, name):
  if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
    raise ValueError(f"{name} must be a finite number")
  if value < -150 or value > 150:
    raise ValueError(f"{name} must be between -150 and 150 dB")
  return float(value)

def build_config(profile, capture, playback):
  """Return a CamillaDSP config dict; JSON serialization is valid YAML."""
  hrir_path = Path(profile["hrir_path"]).expanduser().resolve()
  hrir = validate_hrir(hrir_path)
  rate = profile.get("sample_rate", hrir["sample_rate"])
  if isinstance(rate, bool) or not isinstance(rate, int) or rate != hrir["sample_rate"]:
    raise ValueError(f"sample_rate must match HRIR rate {hrir['sample_rate']}")
  if capture.get("channels") not in (8, 16) or playback.get("channels") != 2:
    raise ValueError("capture needs 8 or 16 channels and playback needs 2")
  preamp_db = _gain(profile.get("preamp_db", -12), "preamp_db")
  lfe_gain_db = _gain(profile.get("lfe_gain_db", 6.020599913), "lfe_gain_db")
  _gain(preamp_db + lfe_gain_db, "combined LFE gain")
  chunksize = profile.get("chunksize", 256 if rate <= 48000 else 512 if rate <= 96000 else 1024)
  if isinstance(chunksize, bool) or not isinstance(chunksize, int) or chunksize < 64:
    raise ValueError("chunksize must be an integer of at least 64 frames")

  filters = {
    "lfe_lowpass": {"type": "Biquad", "parameters": {"type": "Lowpass", "freq": 111, "q": 0.7071067811865476}},
  }
  mapping = []
  pipeline = [
    {"type": "Filter", "channels": [3], "names": ["lfe_lowpass"]},
    {"type": "Mixer", "name": "input_to_ears"},
  ]
  for source, speaker in enumerate(INPUT_CHANNELS):
    if speaker == "LFE":
      continue
    for hrir_channel in HRIR_CHANNELS[speaker]:
      hrir_channel %= hrir["channels"]
      dest = len(mapping)
      sources = [{"channel": source, "gain": preamp_db}]
      if speaker == "FC":
        sources.append({"channel": 3, "gain": preamp_db + lfe_gain_db})
      mapping.append({"dest": dest, "sources": sources})
      filter_name = f"hrir_{hrir_channel}"
      if filter_name not in filters:
        filters[filter_name] = {
          "type": "Conv",
          "parameters": {"type": "Wav", "filename": str(hrir_path), "channel": hrir_channel},
        }
      pipeline.append({"type": "Filter", "channels": [dest], "names": [filter_name]})

  pipeline.append({"type": "Mixer", "name": "ears_to_stereo"})
  eq_bands = profile.get("headphone_eq", [])
  if not isinstance(eq_bands, list):
    raise ValueError("headphone_eq must be a list")
  eq_names = []
  for index, band in enumerate(eq_bands):
    if not isinstance(band, dict):
      raise ValueError("headphone_eq bands must be objects")
    if band.get("type") != "Peaking":
      raise ValueError("headphone_eq supports Peaking bands only")
    freq = band.get("freq")
    q = band.get("q")
    if any(isinstance(item, bool) or not isinstance(item, (int, float)) or not math.isfinite(item) for item in (freq, q)):
      raise ValueError("headphone_eq freq and q must be finite numbers")
    if not 0 < freq < rate / 2 or not 0 < q <= 100:
      raise ValueError("headphone_eq freq or q is outside the valid range")
    gain = _gain(band.get("gain"), "headphone_eq gain")
    name = f"headphone_eq_{index}"
    filters[name] = {"type": "Biquad", "parameters": {"type": "Peaking", "freq": freq, "gain": gain, "q": q}}
    eq_names.append(name)
  if eq_names:
    pipeline.append({"type": "Filter", "channels": [0, 1], "names": eq_names})

  devices = {"samplerate": rate, "chunksize": chunksize, "capture": dict(capture), "playback": dict(playback)}
  if capture.get("type") == "CoreAudio" and playback.get("type") == "CoreAudio":
    devices["enable_rate_adjust"] = True
    devices["resampler"] = {"type": "AsyncSinc", "profile": "Balanced"}

  return {
    "devices": devices,
    "filters": filters,
    "mixers": {
      "input_to_ears": {"channels": {"in": capture["channels"], "out": 14}, "mapping": mapping},
      "ears_to_stereo": {
        "channels": {"in": 14, "out": 2},
        "mapping": [
          {"dest": ear, "sources": [{"channel": source * 2 + ear} for source in range(7)]}
          for ear in range(2)
        ],
      },
    },
    "pipeline": pipeline,
  }

def write_config(path, config):
  """Write a config as JSON, a YAML-compatible CamillaDSP config."""
  Path(path).write_text(json.dumps(config, indent=2, allow_nan=False) + "\n", encoding="utf-8")
