"""Opt-in Linux integration test for the real PipeWire routing lifecycle.

Run with:
  VSS_ROUTING_TEST=1 CAMILLADSP=/path/to/camilladsp python3 routing_test.py
"""

import json
import math
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent
CLI = ROOT / "vss.py"
ENGINE = os.environ.get("CAMILLADSP") or shutil.which("camilladsp")
ENABLED = os.environ.get("VSS_ROUTING_TEST") == "1"
CHANNELS = "FL,FR,FC,LFE,RL,RR,SL,SR"
OUTPUT_A = "vss_test_output_a"
OUTPUT_B = "vss_test_output_b"
UNIT = "vss_dsp.service"
ENDPOINT_UNIT = "vss_endpoint.service"
CLIENT_RULE = Path.home() / ".config" / "pipewire" / "client.conf.d" / "vss_audio.conf"

def run(args, check=True, timeout=20):
  result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
  if check and result.returncode:
    detail = result.stderr.strip() or result.stdout.strip()
    raise AssertionError(f"{' '.join(map(str, args))}: {detail}")
  return result

def wait_for(read, accept, description, timeout=12):
  deadline = time.monotonic() + timeout
  last = None
  while time.monotonic() < deadline:
    try:
      last = read()
      if accept(last):
        return last
    except (OSError, ValueError, AssertionError):
      pass
    time.sleep(0.1)
  raise AssertionError(f"Timed out waiting for {description}; last={last!r}")

def make_hrir(path):
  coefficients = [0.11, 0.12, 0.61, 0.62, 0.41, 0.42, 0.31,
                  0.22, 0.21, 0.72, 0.71, 0.52, 0.51, 0.32]
  data = struct.pack("<14f", *coefficients)
  fmt = struct.pack("<HHIIHH", 3, 14, 48000, 48000 * 56, 56, 32)
  body = b"WAVEfmt " + struct.pack("<I", len(fmt)) + fmt
  body += b"data" + struct.pack("<I", len(data)) + data
  path.write_bytes(b"RIFF" + struct.pack("<I", len(body)) + body)

def make_input(path):
  spacing = 8192
  lead = 4096
  frames = lead + spacing * 9
  samples = [0.0] * (frames * 8)
  for channel in range(8):
    samples[(lead + spacing * channel) * 8 + channel] = 0.05
  path.write_bytes(struct.pack(f"<{len(samples)}f", *samples))
  return spacing

class routing_test(unittest.TestCase):
  @classmethod
  def setUpClass(cls):
    if not ENABLED:
      raise unittest.SkipTest("set VSS_ROUTING_TEST=1 for real PipeWire integration")
    if sys.platform != "linux":
      raise unittest.SkipTest("Linux only")
    required = ("pw-cli", "pw-dump", "pw-play", "pw-record", "systemctl")
    missing = [name for name in required if shutil.which(name) is None]
    if missing:
      raise unittest.SkipTest("missing commands: " + ", ".join(missing))
    if not ENGINE or not Path(ENGINE).is_file():
      raise unittest.SkipTest(f"CamillaDSP missing: {ENGINE}")
    for service in ("pipewire.service", "wireplumber.service"):
      if run(["systemctl", "--user", "is-active", "--quiet", service], check=False).returncode:
        raise unittest.SkipTest(f"inactive user service: {service}")

  def setUp(self):
    self.temp = tempfile.TemporaryDirectory(prefix="vss_routing_")
    self.addCleanup(self.temp.cleanup)
    self.folder = Path(self.temp.name)
    self.state = self.folder / "state"
    self.hrir = self.folder / "synthetic_hrir.wav"
    self.outputs = []
    self.capture_index = 0
    self.installed = False
    make_hrir(self.hrir)
    unit_dir = Path.home() / ".config" / "systemd" / "user"
    for unit in (UNIT, ENDPOINT_UNIT):
      if (unit_dir / unit).exists() or run([
        "systemctl", "--user", "cat", unit,
      ], check=False).returncode == 0:
        self.skipTest(f"pre-existing {unit} must remain untouched")
    if CLIENT_RULE.exists():
      self.skipTest(f"pre-existing {CLIENT_RULE} must remain untouched")
    self.addCleanup(self._cleanup)

  def _cleanup(self):
    if self.installed:
      self._cli("uninstall", check=False)
    for node_id in reversed(self.outputs):
      self._stop_output(node_id)

  def _cli(self, *args, check=True):
    return run([sys.executable, str(CLI), "--config-dir", str(self.state), *args], check=check)

  def _status(self):
    result = self._cli("status", check=False)
    if not result.stdout.strip():
      return {}
    return json.loads(result.stdout)

  def _unit_pid(self, unit):
    return int(run([
      "systemctl", "--user", "show", "--property=MainPID", "--value", unit,
    ]).stdout.strip())

  def _start_output(self, name, device_id):
    properties = (
      "{ factory.name=support.null-audio-sink"
      f" node.name={name} node.description={name}"
      f" media.class=Audio/Sink device.id={device_id}"
      " node.virtual=false object.linger=true audio.position=[ FL FR ] }"
    )
    run(["pw-cli", "create-node", "adapter", properties])
    node_id = wait_for(lambda: self._node_id(name), lambda value: value is not None,
                       f"fake output {name}")
    self.outputs.append(node_id)
    return node_id

  def _stop_output(self, node_id):
    run(["pw-cli", "destroy", str(node_id)], check=False)

  def _objects(self):
    return json.loads(run(["pw-dump"]).stdout)

  def _node_id(self, name):
    for item in self._objects():
      if not item.get("type", "").endswith(":Node"):
        continue
      if item.get("info", {}).get("props", {}).get("node.name") == name:
        return item["id"]
    return None

  def _playback_target(self):
    objects = self._objects()
    nodes = {
      item["id"]: item.get("info", {}).get("props", {}).get("node.name")
      for item in objects if item.get("type", "").endswith(":Node")
    }
    playback_ids = {node_id for node_id, name in nodes.items() if name == "vss_playback"}
    for item in objects:
      if not item.get("type", "").endswith(":Link"):
        continue
      info = item.get("info", {})
      if info.get("output-node-id") in playback_ids:
        return nodes.get(info.get("input-node-id"))
    return None

  def _sink_input_links(self):
    objects = self._objects()
    sink_id = next((item["id"] for item in objects
                    if item.get("type", "").endswith(":Node")
                    and item.get("info", {}).get("props", {}).get("node.name") == "vss_7_1"), None)
    return len({item.get("info", {}).get("input-port-id") for item in objects
                if item.get("type", "").endswith(":Link")
                and item.get("info", {}).get("input-node-id") == sink_id})

  def _configure(self, output, first=False):
    args = ["configure", "--output", output]
    if first:
      args += ["--hrir", str(self.hrir), "--camilladsp", ENGINE,
               "--preamp-db", "0", "--chunksize", "128"]
    self._cli(*args)

  def _verify_audio(self, output):
    input_path = self.folder / "input.raw"
    self.capture_index += 1
    output_path = self.folder / f"capture_{self.capture_index}.raw"
    spacing = make_input(input_path)
    record = None
    play = None
    try:
      record = subprocess.Popen([
        "pw-record", "--raw", "--rate=48000", "--channels=2", "--channel-map=FL,FR",
        "--format=f32", "--target=" + output,
        '--properties={"stream.capture.sink":true,"stream.dont-remix":true}',
        str(output_path),
      ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
      time.sleep(0.2)
      if record.poll() is not None:
        _, detail = record.communicate()
        self.fail(f"pw-record exited {record.returncode}: {detail.strip()}")
      play = subprocess.Popen([
        "pw-play", "--raw", "--rate=48000", "--channels=8", "--channel-map=" + CHANNELS,
        "--format=f32", "--target=vss_7_1", str(input_path),
      ], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
      try:
        wait_for(self._sink_input_links, lambda count: count == 8,
                 "eight live input links", timeout=3)
      except AssertionError as error:
        play_code = play.poll()
        record_code = record.poll()
        play_detail = play.communicate()[1].strip() if play_code is not None else "still running"
        record_detail = record.communicate()[1].strip() if record_code is not None else "still running"
        raise AssertionError(
          f"{error}; pw-play={play_code}: {play_detail}; pw-record={record_code}: {record_detail}"
        ) from error
      _, play_detail = play.communicate(timeout=10)
      if play.returncode:
        self.fail(f"pw-play exited {play.returncode}: {play_detail.strip()}")
      if record.poll() is not None:
        _, detail = record.communicate()
        self.fail(f"pw-record exited early {record.returncode}: {detail.strip()}")
      record.terminate()
      try:
        _, detail = record.communicate(timeout=3)
      except subprocess.TimeoutExpired:
        self.fail("pw-record did not stop after SIGTERM")
      if record.returncode not in (-15, 0, 1) or detail.strip():
        self.fail(f"pw-record shutdown {record.returncode}: {detail.strip()}")
    finally:
      for process in (play, record):
        if process is None:
          continue
        if process.poll() is None:
          process.terminate()
          try:
            process.communicate(timeout=3)
          except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
        elif process.stderr:
          process.stderr.close()
    raw = output_path.read_bytes()
    samples = struct.unpack(f"<{len(raw) // 4}f", raw)
    frames = [(samples[index], samples[index + 1]) for index in range(0, len(samples), 2)]
    first = next((index for index, frame in enumerate(frames)
                  if max(abs(frame[0]), abs(frame[1])) >= 0.001), None)
    self.assertIsNotNone(first, "recording contains no processed signal")
    expected = [
      (0.11, 0.12), (0.21, 0.22), (0.31, 0.32), (0.62, 0.64),
      (0.41, 0.42), (0.51, 0.52), (0.61, 0.62), (0.71, 0.72),
    ]
    for channel, coefficient in enumerate(expected):
      center = first + spacing * channel
      window = frames[max(0, center - 32):center + spacing // 2]
      actual = tuple(sum(frame[ear] for frame in window) for ear in range(2))
      for ear in range(2):
        self.assertTrue(math.isclose(actual[ear], 0.05 * coefficient[ear], rel_tol=0.02,
                                     abs_tol=0.0001),
                        f"channel {channel} ear {ear}: {actual[ear]}")

  def test_real_routing_lifecycle(self):
    output_a = self._start_output(OUTPUT_A, 7101)
    devices = json.loads(self._cli("devices").stdout)
    self.assertEqual([item["id"] for item in devices if item["id"] == OUTPUT_A], [OUTPUT_A])

    self._configure(OUTPUT_A, first=True)
    self._cli("install")
    self.installed = True
    self._cli("start")
    wait_for(self._status, lambda status: status.get("healthy") and status.get("sink_ports") == 8,
             "initial routing")
    wait_for(self._playback_target, lambda target: target == OUTPUT_A, "first output link")

    old_pid = self._unit_pid(UNIT)
    run(["systemctl", "--user", "kill", "--signal=KILL", UNIT])
    dsp_pid = wait_for(lambda: self._unit_pid(UNIT), lambda pid: pid not in (0, old_pid),
                       "CamillaDSP service restart")
    wait_for(self._playback_target, lambda target: target == OUTPUT_A, "routing after restart")

    old_pid = self._unit_pid(ENDPOINT_UNIT)
    run(["systemctl", "--user", "kill", "--signal=KILL", ENDPOINT_UNIT])
    wait_for(lambda: self._unit_pid(ENDPOINT_UNIT), lambda pid: pid not in (0, old_pid),
             "endpoint service restart")
    self.assertEqual(self._unit_pid(UNIT), dsp_pid)
    wait_for(self._status, lambda status: status.get("healthy"), "routing after endpoint restart")

    output_b = self._start_output(OUTPUT_B, 7102)
    self._configure(OUTPUT_B)
    self._cli("start")
    wait_for(self._playback_target, lambda target: target == OUTPUT_B, "switched output link")
    self._verify_audio(OUTPUT_B)

    config_before = (self.state / "config.json").read_bytes()
    profile_before = (self.state / "profile.json").read_bytes()
    bad_hrir = self.folder / "bad_hrir.wav"
    bad_hrir.write_bytes(b"not a RIFF WAVE")
    failed = self._cli("configure", "--hrir", str(bad_hrir), check=False)
    self.assertNotEqual(failed.returncode, 0)
    self.assertEqual((self.state / "config.json").read_bytes(), config_before)
    self.assertEqual((self.state / "profile.json").read_bytes(), profile_before)
    self.assertEqual(self._playback_target(), OUTPUT_B)

    self._stop_output(output_b)
    wait_for(self._status, lambda status: not status.get("target_present"), "disconnected output")
    self.assertIsNone(self._playback_target())
    output_b = self._start_output(OUTPUT_B, 7102)
    wait_for(self._playback_target, lambda target: target == OUTPUT_B, "reconnected output")
    self._verify_audio(OUTPUT_B)

    self._cli("stop")
    wait_for(self._status, lambda status: not status.get("running"), "stopped services")
    self._cli("uninstall")
    self.installed = False
    unit_dir = Path.home() / ".config" / "systemd" / "user"
    self.assertFalse((unit_dir / UNIT).exists())
    self.assertFalse((unit_dir / ENDPOINT_UNIT).exists())
    self.assertFalse(CLIENT_RULE.exists())
    self._stop_output(output_a)

if __name__ == "__main__":
  unittest.main()
