#!/usr/bin/env python3
"""Headless virtual surround setup for Linux and macOS."""

import argparse
import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import wave

import dsp
import platforms

def state_dir():
  return Path(os.environ.get('XDG_CONFIG_HOME', Path.home() / '.config')) / 'vss'

def read_profile(path):
  settings = json.loads(path.read_text(encoding='utf-8'))
  if not isinstance(settings, dict):
    raise ValueError('profile.json must contain a JSON object.')
  for name in ('platform', 'hrir_path', 'output', 'capture', 'camilladsp'):
    if name in settings and (not isinstance(settings[name], str) or not settings[name].strip()):
      raise ValueError(f'Profile {name} must be a nonempty string.')
  if 'platform' in settings and settings['platform'] not in ('linux', 'macos'):
    raise ValueError('Profile platform must be linux or macos.')
  return settings

def write_json(path, value):
  path.parent.mkdir(parents=True, exist_ok=True)
  pending = None
  try:
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                     delete=False) as stream:
      pending = Path(stream.name)
      json.dump(value, stream, indent=2, allow_nan=False)
      stream.write('\n')
    pending.replace(path)
  finally:
    if pending is not None:
      pending.unlink(missing_ok=True)

def device_config(settings):
  if settings['platform'] == 'linux':
    return ({'type': 'PipeWire', 'channels': 8, 'node_name': 'vss_capture'},
            {'type': 'PipeWire', 'channels': 2, 'node_name': 'vss_playback',
             'autoconnect_to': settings['output']})
  return ({'type': 'CoreAudio', 'channels': 16, 'device': settings['capture']},
          {'type': 'CoreAudio', 'channels': 2, 'device': settings['output'],
           'exclusive': False})

def engine_path(name):
  engine = shutil.which(name)
  if not engine:
    raise ValueError(f'CamillaDSP executable not found: {name}')
  return str(Path(engine).resolve())

def check_config(engine, path):
  subprocess.run([engine, '--check', str(path)], check=True, timeout=30)

def configure(args, directory):
  settings_path = directory / 'profile.json'
  settings = read_profile(settings_path) if settings_path.exists() else {}
  settings.setdefault('platform', 'macos' if sys.platform == 'darwin' else 'linux')
  settings.setdefault('capture', 'BlackHole 16ch')
  settings.setdefault('camilladsp', 'camilladsp')
  for name in ('platform', 'output', 'capture', 'camilladsp', 'preamp_db', 'lfe_gain_db', 'chunksize'):
    value = getattr(args, name)
    if value is not None:
      settings[name] = value
  if args.hrir:
    settings['hrir_path'] = str(Path(args.hrir).expanduser().resolve())
  if args.eq:
    settings['headphone_eq'] = json.loads(Path(args.eq).read_text(encoding='utf-8'))
  if args.clear_eq:
    settings.pop('headphone_eq', None)
  if not settings.get('hrir_path') or not settings.get('output'):
    raise ValueError('First configure requires --hrir AND --output (see devices).')
  if settings['output'] in ('vss_7_1', 'vss_capture', 'vss_playback', settings['capture']):
    raise ValueError('Output must be a physical device, routing into capture causes feedback.')
  config = dsp.build_config(settings, *device_config(settings))
  directory.mkdir(parents=True, exist_ok=True)
  with tempfile.TemporaryDirectory(dir=directory) as staging:
    config_path = Path(staging) / 'config.json'
    write_json(config_path, config)
    if not args.export_only:
      settings['camilladsp'] = engine_path(settings['camilladsp'])
      check_config(settings['camilladsp'], config_path)
    write_json(settings_path, settings)
    write_json(directory / 'config.json', config)
  print(f'Configured {settings["platform"]}: {directory / "config.json"}')
  print('Run install to enable background processing, or start to apply changes to an installed service.')

def tones(path, rate):
  with wave.open(str(path), 'wb') as audio:
    audio.setparams((8, 2, rate, 0, 'NONE', 'not compressed'))
    for channel in range(8):
      frames = bytearray()
      for frame in range(rate):
        envelope = min(1, frame / (rate * 0.02), max(0, (rate * 0.75 - frame) / (rate * 0.02)))
        frequency = 60 if channel == 3 else 440
        sample = int(3276 * envelope * math.sin(2 * math.pi * frequency * frame / rate))
        values = [0] * 8
        values[channel] = sample
        frames.extend(struct.pack('<8h', *values))
      audio.writeframes(frames)
  print(f'{path}: one second each, FL FR FC LFE RL RR SL SR, -20 dBFS peak')

def main():
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--config-dir', type=Path, default=state_dir())
  commands = parser.add_subparsers(dest='command', required=True)
  commands.add_parser('devices', help='List output identifiers for configure --output.')
  config_parser = commands.add_parser('configure', help='Create or update the profile and DSP configuration.')
  config_parser.add_argument('--hrir', help='User-supplied HeSuVi 7-channel or 14-channel WAV.')
  config_parser.add_argument('--output', help='Exact output identifier from devices.')
  config_parser.add_argument('--capture', help='macOS virtual capture device name.')
  config_parser.add_argument('--platform', choices=('linux', 'macos'))
  config_parser.add_argument('--camilladsp', help='CamillaDSP executable path.')
  config_parser.add_argument('--preamp-db', type=float)
  config_parser.add_argument('--lfe-gain-db', type=float)
  config_parser.add_argument('--chunksize', type=int)
  eq_group = config_parser.add_mutually_exclusive_group()
  eq_group.add_argument('--eq', help='JSON array of Peaking EQ bands: type, freq, gain, q.')
  eq_group.add_argument('--clear-eq', action='store_true')
  config_parser.add_argument('--export-only', action='store_true', help='Generate config without local engine validation.')
  for command in ('check', 'run', 'install', 'start', 'stop', 'status', 'uninstall'):
    commands.add_parser(command)
  tone_parser = commands.add_parser('tones', help='Write an eight-channel listening test WAV.')
  tone_parser.add_argument('path', type=Path)
  tone_parser.add_argument('--rate', type=int, default=48000, choices=(44100, 48000, 88200, 96000))
  args = parser.parse_args()
  directory = args.config_dir.expanduser().resolve()
  if args.command == 'configure':
    configure(args, directory)
  elif args.command == 'tones':
    tones(args.path, args.rate)
  elif args.command == 'devices':
    print(json.dumps(platforms.list_outputs(), indent=2))
  elif args.command == 'status':
    result = platforms.status()
    print(json.dumps(result, indent=2))
    return 0 if result.get('healthy', result['running']) else 1
  elif args.command in ('stop', 'uninstall'):
    (platforms.stop if args.command == 'stop' else platforms.uninstall_service)()
  else:
    settings = read_profile(directory / 'profile.json')
    if any(name not in settings for name in ('platform', 'camilladsp', 'capture', 'output')):
      raise ValueError('Incomplete profile, run configure --hrir FILE --output DEVICE.')
    current_platform = 'macos' if sys.platform == 'darwin' else 'linux' if sys.platform.startswith('linux') else 'windows'
    if settings['platform'] != current_platform:
      raise ValueError(f'Profile targets {settings["platform"]}, current platform is {current_platform}.')
    engine = engine_path(settings['camilladsp'])
    config = dsp.build_config(settings, *device_config(settings))
    with tempfile.TemporaryDirectory(dir=directory) as staging:
      pending = Path(staging) / 'config.json'
      write_json(pending, config)
      check_config(engine, pending)
      write_json(directory / 'config.json', config)
    if args.command in ('run', 'install', 'start'):
      problems = platforms.check_prerequisites(engine)
      if problems:
        raise ValueError('\n'.join(problems))
      platforms.validate_devices(settings['output'], settings['capture'])
      if args.command == 'run':
        if platforms.status()['dsp_running']:
          raise ValueError('Background processing is active, run stop before run.')
        if current_platform == 'linux':
          platforms.install_service(directory / 'config.json', engine)
        print('Foreground processing, Ctrl+C to stop. macOS may request audio input access.', flush=True)
        subprocess.run([engine, str(directory / 'config.json')], check=True)
      else:
        platforms.install_service(directory / 'config.json', engine)
        platforms.start()
  return 0

if __name__ == '__main__':
  try:
    sys.exit(main())
  except KeyboardInterrupt:
    sys.exit(130)
  except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
    print(f'vss: {error}', file=sys.stderr)
    sys.exit(1)
