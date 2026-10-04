"""User-session audio routing and service setup for Linux and macOS."""

import ctypes
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess

CHANNELS = ("FL", "FR", "FC", "LFE", "RL", "RR", "SL", "SR")
SINK_NAME = "vss_7_1"
CAPTURE_NAME = "vss_capture"
BRIDGE_NAME = "vss_to_dsp"
PLAYBACK_NAME = "vss_playback"
LINUX_ENDPOINT_UNIT = "vss_endpoint.service"
LINUX_DSP_UNIT = "vss_dsp.service"
MAC_LABEL = "org.virtualsurroundsound.dsp"
LINUX_CLIENT_RULE = "vss_audio.conf"

def _system():
  system = platform.system()
  if system not in ("Linux", "Darwin"):
    raise RuntimeError(f"Unsupported platform: {system}")
  return system

def _run(args, check=True):
  try:
    result = subprocess.run(args, capture_output=True, text=True, check=False, timeout=30)
  except subprocess.TimeoutExpired as error:
    raise RuntimeError(f"Command timed out: {args[0]}") from error
  if check and result.returncode:
    detail = result.stderr.strip() or result.stdout.strip()
    raise RuntimeError(f"{' '.join(map(str, args))}: {detail}")
  return result

def _pipewire_objects():
  result = _run(["pw-dump"])
  return json.loads(result.stdout)

def _fourcc(value):
  return int.from_bytes(value.encode("ascii"), "big")

def _coreaudio_devices():
  if _system() != "Darwin":
    raise RuntimeError("CoreAudio enumeration requires macOS")
  audio = ctypes.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
  core = ctypes.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")

  class audio_property_address(ctypes.Structure):
    _fields_ = [("selector", ctypes.c_uint32), ("scope", ctypes.c_uint32), ("element", ctypes.c_uint32)]

  class audio_buffer(ctypes.Structure):
    _fields_ = [("number_channels", ctypes.c_uint32), ("data_bytes", ctypes.c_uint32), ("data", ctypes.c_void_p)]

  class audio_buffer_list(ctypes.Structure):
    _fields_ = [("number_buffers", ctypes.c_uint32), ("buffers", audio_buffer * 1)]

  audio.AudioObjectGetPropertyDataSize.argtypes = [
    ctypes.c_uint32, ctypes.POINTER(audio_property_address), ctypes.c_uint32,
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32),
  ]
  audio.AudioObjectGetPropertyData.argtypes = [
    ctypes.c_uint32, ctypes.POINTER(audio_property_address), ctypes.c_uint32,
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p,
  ]
  core.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
  core.CFStringGetCString.restype = ctypes.c_bool
  core.CFRelease.argtypes = [ctypes.c_void_p]

  def property_data(object_id, selector, scope="glob"):
    address = audio_property_address(_fourcc(selector), _fourcc(scope), 0)
    size = ctypes.c_uint32()
    code = audio.AudioObjectGetPropertyDataSize(
      object_id, ctypes.byref(address), 0, None, ctypes.byref(size),
    )
    if code:
      raise RuntimeError(f"CoreAudio property {selector} size error: {code}")
    value = ctypes.create_string_buffer(size.value)
    code = audio.AudioObjectGetPropertyData(
      object_id, ctypes.byref(address), 0, None, ctypes.byref(size), value,
    )
    if code:
      raise RuntimeError(f"CoreAudio property {selector} read error: {code}")
    return value, size.value

  raw_ids, size = property_data(1, "dev#")
  ids = (ctypes.c_uint32 * (size // 4)).from_buffer_copy(raw_ids)
  devices = []
  for device_id in ids:
    try:
      raw_name, _ = property_data(device_id, "lnam")
      name_ref = ctypes.c_void_p.from_buffer_copy(raw_name).value
      name_buffer = ctypes.create_string_buffer(2048)
      if not name_ref:
        continue
      converted = core.CFStringGetCString(name_ref, name_buffer, len(name_buffer), 0x08000100)
      core.CFRelease(name_ref)
      if not converted:
        continue
      channels = {}
      for direction, scope in (("input", "inpt"), ("output", "outp")):
        try:
          raw_list, size = property_data(device_id, "slay", scope)
        except RuntimeError:
          channels[direction] = 0
          continue
        if size < 4:
          channels[direction] = 0
          continue
        count = ctypes.c_uint32.from_buffer_copy(raw_list.raw[:4]).value
        if not count:
          channels[direction] = 0
          continue
        if size < audio_buffer_list.buffers.offset + count * ctypes.sizeof(audio_buffer):
          raise RuntimeError("CoreAudio channel buffer list truncated")
        address = ctypes.addressof(raw_list) + audio_buffer_list.buffers.offset
        buffers = (audio_buffer * count).from_address(address)
        channels[direction] = sum(buffer.number_channels for buffer in buffers)
      name = name_buffer.value.decode("utf-8")
      devices.append({
        "id": name, "name": name,
        "input_channels": channels["input"], "output_channels": channels["output"],
      })
    except RuntimeError:
      continue
  return devices

def list_outputs():
  """Return physical sink names suitable for the CamillaDSP playback device."""
  if _system() == "Darwin":
    return [
      {"id": device["id"], "name": device["name"], "channels": device["output_channels"]}
      for device in _coreaudio_devices()
      if device["output_channels"] >= 2 and not device["name"].startswith("BlackHole")
    ]
  devices = []
  for item in _pipewire_objects():
    if not item.get("type", "").endswith(":Node"):
      continue
    props = item.get("info", {}).get("props", {})
    if props.get("media.class") != "Audio/Sink" or props.get("node.name") == SINK_NAME:
      continue
    if str(props.get("node.virtual", "false")).lower() == "true":
      continue
    if "device.id" not in props:
      continue
    devices.append({
      "id": props["node.name"],
      "name": props.get("node.description", props["node.name"]),
      "channels": int(props.get("audio.channels", 2)),
    })
  return sorted(devices, key=lambda device: device["name"].casefold())

def list_inputs():
  if _system() != "Darwin":
    raise RuntimeError("Input enumeration is only needed on macOS")
  return [
    {"id": device["id"], "name": device["name"], "channels": device["input_channels"]}
    for device in _coreaudio_devices() if device["input_channels"]
  ]

def validate_devices(output_id, capture_id="BlackHole 16ch"):
  outputs = [d for d in list_outputs() if d["id"] == output_id]
  if len(outputs) != 1 or outputs[0]["channels"] < 2:
    raise ValueError(f"Stereo output missing or ambiguous: {output_id}")
  if _system() == "Darwin":
    inputs = [d for d in list_inputs() if d["id"] == capture_id]
    if len(inputs) != 1 or inputs[0]["channels"] < 16:
      raise ValueError(f"16-channel BlackHole input missing or ambiguous: {capture_id}")
    if capture_id == output_id or not capture_id.startswith("BlackHole 16ch"):
      raise ValueError("Capture must be BlackHole 16ch, output must be physical")

def check_prerequisites(camilladsp):
  """Return missing requirements; read-only, including PipeWire backend check."""
  missing = []
  required = ("pw-dump", "pw-loopback", "systemctl") if _system() == "Linux" else ("launchctl",)
  missing.extend(f"{tool} missing" for tool in required if shutil.which(tool) is None)
  try:
    help_text = _run([camilladsp, "--help"]).stdout
    if _system() == "Linux" and "PipeWire" not in help_text:
      missing.append("CamillaDSP lacks native PipeWire backend")
    if _system() == "Darwin" and "CoreAudio" not in help_text:
      missing.append("CamillaDSP lacks CoreAudio backend")
  except RuntimeError as error:
    missing.append(str(error))
  if _system() == "Linux" and "pw-dump missing" not in missing:
    try:
      _pipewire_objects()
    except (RuntimeError, ValueError):
      missing.append("PipeWire user server unavailable")
  return missing

def _systemd_arg(value):
  text = str(value)
  if "\n" in text or "\r" in text:
    raise ValueError("Systemd argument contains newline")
  return '"' + text.replace("\\", "\\\\").replace('"', '\\"').replace("%", "%%").replace("$", "$$") + '"'

def _linux_endpoint_unit():
  capture_props = json.dumps({
    "media.class": "Audio/Sink",
    "node.name": SINK_NAME,
    "node.description": "Virtual Surround 7.1",
    "audio.position": list(CHANNELS),
  })
  playback_props = json.dumps({
    "node.name": BRIDGE_NAME,
    "target.object": CAPTURE_NAME,
    "audio.position": list(CHANNELS),
    "stream.dont-remix": True,
    "node.passive": True,
    "node.dont-fallback": True,
    "node.dont-move": True,
    "node.linger": True,
  })
  args = (
    "pw-loopback", "--name", SINK_NAME, "--channels", "8",
    "--channel-map", "[ FL, FR, FC, LFE, RL, RR, SL, SR ]",
    "--capture-props", capture_props, "--playback-props", playback_props,
  )
  return "\n".join((
    "[Unit]",
    "Description=Virtual Surround 7.1 endpoint",
    "Wants=pipewire.service wireplumber.service",
    "After=pipewire.service wireplumber.service",
    "StartLimitIntervalSec=0",
    "",
    "[Service]",
    "Type=simple",
    "ExecStart=" + " ".join(_systemd_arg(arg) for arg in args),
    "Restart=always",
    "RestartSec=2",
    "",
    "[Install]",
    "WantedBy=default.target",
    "",
  ))

def _linux_dsp_unit(config_path, camilladsp):
  return "\n".join((
    "[Unit]",
    "Description=Virtual Surround CamillaDSP",
    f"Wants={LINUX_ENDPOINT_UNIT}",
    f"After={LINUX_ENDPOINT_UNIT}",
    "StartLimitIntervalSec=0",
    "",
    "[Service]",
    "Type=simple",
    "ExecStart=" + " ".join(_systemd_arg(arg) for arg in (camilladsp, config_path)),
    "Restart=always",
    "RestartPreventExitStatus=101",
    "RestartSec=2",
    "",
    "[Install]",
    "WantedBy=default.target",
    "",
  ))

def _mac_plist(config_path, camilladsp):
  import plistlib

  state_dir = Path.home() / "Library" / "Logs" / "virtual-surround-sound"
  state_dir.mkdir(parents=True, exist_ok=True)
  return plistlib.dumps({
    "Label": MAC_LABEL,
    "ProgramArguments": [
      str(camilladsp), "--logfile", str(state_dir / "camilladsp.log"),
      "--log_rotate_size", "1048576", "--log_keep_nbr", "3", str(config_path),
    ],
    "RunAtLoad": True,
    "KeepAlive": True,
    "ThrottleInterval": 10,
  })

def install_service(config_path, camilladsp):
  """Write per-user supervisor definitions without starting audio routing."""
  config = Path(config_path).expanduser().resolve()
  if not config.is_file():
    raise RuntimeError(f"CamillaDSP config missing: {config}")
  if _system() == "Linux":
    dsp = _linux_dsp_unit(config, camilladsp)
    unit_dir = Path.home() / ".config" / "systemd" / "user"
    unit_dir.mkdir(parents=True, exist_ok=True)
    (unit_dir / LINUX_ENDPOINT_UNIT).write_text(_linux_endpoint_unit(), encoding="utf-8")
    (unit_dir / LINUX_DSP_UNIT).write_text(dsp, encoding="utf-8")
    client_dir = Path.home() / ".config" / "pipewire" / "client.conf.d"
    client_dir.mkdir(parents=True, exist_ok=True)
    (client_dir / LINUX_CLIENT_RULE).write_text(
      'stream.rules = [\n'
      '  { matches = [ { node.name = "vss_playback" } ]\n'
      '    actions = { update-props = { node.dont-fallback = true'
      ' node.dont-move = true node.linger = true } } }\n]\n',
      encoding="utf-8",
    )
    _run(["systemctl", "--user", "daemon-reload"])
  else:
    agent_dir = Path.home() / "Library" / "LaunchAgents"
    agent_dir.mkdir(parents=True, exist_ok=True)
    plist = _mac_plist(config, camilladsp)
    loaded = _run(["launchctl", "print", _mac_target()], check=False).returncode == 0
    if loaded:
      _run(["launchctl", "bootout", _mac_target()])
    (agent_dir / f"{MAC_LABEL}.plist").write_bytes(plist)

def _mac_target():
  return f"gui/{os.getuid()}/{MAC_LABEL}"

def _mac_agent_path():
  return Path.home() / "Library" / "LaunchAgents" / f"{MAC_LABEL}.plist"

def start():
  if _system() == "Linux":
    _run(["systemctl", "--user", "enable", LINUX_DSP_UNIT])
    _run(["systemctl", "--user", "restart", LINUX_ENDPOINT_UNIT])
    _run(["systemctl", "--user", "restart", LINUX_DSP_UNIT])
  else:
    path = _mac_agent_path()
    if not path.is_file():
      raise RuntimeError(f"LaunchAgent missing: {path}")
    target = _mac_target()
    if _run(["launchctl", "print", target], check=False).returncode:
      _run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(path)])
    else:
      _run(["launchctl", "kickstart", "-k", target])

def stop():
  if _system() == "Linux":
    for unit in (LINUX_DSP_UNIT, LINUX_ENDPOINT_UNIT):
      state = _run([
        "systemctl", "--user", "show", "--property=LoadState", "--value", unit,
      ]).stdout.strip()
      if state != "not-found":
        _run(["systemctl", "--user", "stop", unit])
  else:
    target = _mac_target()
    if _run(["launchctl", "print", target], check=False).returncode:
      _run(["launchctl", "print", f"gui/{os.getuid()}"])
    else:
      _run(["launchctl", "bootout", target])

def uninstall_service():
  stop()
  if _system() == "Linux":
    unit_dir = Path.home() / ".config" / "systemd" / "user"
    unit_path = unit_dir / LINUX_DSP_UNIT
    if unit_path.is_file():
      _run(["systemctl", "--user", "disable", LINUX_DSP_UNIT])
    unit_path.unlink(missing_ok=True)
    (unit_dir / LINUX_ENDPOINT_UNIT).unlink(missing_ok=True)
    (Path.home() / ".config" / "pipewire" / "client.conf.d" / LINUX_CLIENT_RULE).unlink(missing_ok=True)
    _run(["systemctl", "--user", "daemon-reload"])
  else:
    _mac_agent_path().unlink(missing_ok=True)

def _linux_status():
  dsp_running = _run(["systemctl", "--user", "is-active", "--quiet", LINUX_DSP_UNIT], check=False).returncode == 0
  endpoint_running = _run([
    "systemctl", "--user", "is-active", "--quiet", LINUX_ENDPOINT_UNIT,
  ], check=False).returncode == 0
  result = {
    "running": dsp_running and endpoint_running,
    "healthy": False,
    "dsp_running": dsp_running,
    "endpoint_running": endpoint_running,
    "sink_present": False,
    "sink_channels": False,
    "sink_ports": 0,
    "capture_links": 0,
    "playback_links": 0,
    "target_present": False,
    "detail": "Audio graph unavailable",
  }
  try:
    objects = _pipewire_objects()
  except (RuntimeError, ValueError):
    return result
  nodes = {
    item["id"]: item.get("info", {}).get("props", {})
    for item in objects if item.get("type", "").endswith(":Node")
  }
  ids = {props.get("node.name"): node_id for node_id, props in nodes.items()}
  result["sink_present"] = nodes.get(ids.get(SINK_NAME), {}).get("media.class") == "Audio/Sink"
  sink_id = ids.get(SINK_NAME)
  sink_ports = [
    item for item in objects
    if item.get("type", "").endswith(":Port")
    and item.get("info", {}).get("props", {}).get("node.id") == sink_id
    and item.get("info", {}).get("props", {}).get("port.direction") == "in"
  ]
  result["sink_ports"] = len({item.get("info", {}).get("props", {}).get("port.id") for item in sink_ports})
  sink_ports.sort(key=lambda item: item.get("info", {}).get("props", {}).get("port.id", -1))
  result["sink_channels"] = [
    item.get("info", {}).get("props", {}).get("audio.channel") for item in sink_ports
  ] == list(CHANNELS)
  playback_id = ids.get(PLAYBACK_NAME)
  target_name = nodes.get(playback_id, {}).get("target.object")
  result["target_present"] = bool(target_name and target_name in ids)
  capture_id = ids.get(CAPTURE_NAME)
  bridge_id = ids.get(BRIDGE_NAME)
  capture_ports = set()
  playback_ports = set()
  for item in objects:
    if not item.get("type", "").endswith(":Link"):
      continue
    info = item.get("info", {})
    output_id = info.get("output-node-id")
    input_id = info.get("input-node-id")
    if output_id == bridge_id and input_id == capture_id:
      capture_ports.add((info.get("output-port-id"), info.get("input-port-id")))
    if output_id == playback_id and nodes.get(input_id, {}).get("node.name") == target_name:
      playback_ports.add((info.get("output-port-id"), info.get("input-port-id")))
  capture_sources = {output_port for output_port, _ in capture_ports}
  capture_targets = {input_port for _, input_port in capture_ports}
  playback_sources = {output_port for output_port, _ in playback_ports}
  playback_targets = {input_port for _, input_port in playback_ports}
  result["capture_links"] = len(capture_ports)
  result["playback_links"] = len(playback_ports)
  result["healthy"] = all((
    result["running"], result["sink_present"], result["sink_channels"],
    result["sink_ports"] == 8, result["capture_links"] == 8,
    len(capture_sources) == 8, len(capture_targets) == 8,
    result["target_present"], result["playback_links"] == 2,
    len(playback_sources) == 2, len(playback_targets) == 2,
  ))
  result["detail"] = "Graph nodes and links observed; audio samples unverified"
  return result

def status():
  """Report supervisor and graph observations, never claim sample-level proof."""
  if _system() == "Linux":
    return _linux_status()
  result = _run(["launchctl", "print", _mac_target()], check=False)
  active = result.returncode == 0 and "state = running" in result.stdout
  return {"running": active, "dsp_running": active, "detail": "LaunchAgent process observed; CoreAudio routing and audio samples unverified"}
