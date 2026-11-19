"""Read-only temperature/fan telemetry via `sensors -j` (lm-sensors)."""

from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass

# No real case or CPU fan exceeds this, so anything above it is a register
# that does not hold a fan speed rather than a fan. It is a backstop, not a
# validity check: the wrong driver on this board produced 768 "rpm" that
# sailed under it (see read_cpu_fan_rpm).
MAX_PLAUSIBLE_RPM = 10_000

# The board's Super I/O is an NCT6799D (chip ID 0xd806), which the in-tree
# nct6775 driver exposes as `nct6799-isa-0290`. The prefix covers that
# driver's whole family and deliberately excludes `nct6687`.
CPU_FAN_CHIP_PREFIX = "nct67"
# nct6775 has no header names to offer, only channel numbers. Channel 2 is
# the CPU_FAN header on ASUS boards.
CPU_FAN_LABEL = "fan2"


@dataclass
class FanReading:
    chip: str
    label: str
    rpm: float


@dataclass
class TempReading:
    chip: str
    label: str
    celsius: float


def snapshot() -> dict:
    """One `sensors -j` read, to be shared by several readings.

    Each reader below shells out on its own when called bare, which is the
    right default — a stale temperature is worse than a cheap one, and there is
    no hidden cache to reason about. But `micachy-ctl status` answers all three
    at once, so calling them bare spawned `sensors` three times per invocation,
    and the bar widget polls `status` every two seconds while its panel is open.
    Passing one snapshot through makes that a single spawn.

    A parameter rather than a module-level cache on purpose: the caller that
    wants a shared read says so, and nothing else silently starts serving data
    from some earlier moment.
    """
    return _read_sensors_json()


def _read_sensors_json() -> dict:
    """Every reading `sensors` can produce, or `{}` if it cannot produce any.

    Failing soft rather than raising, because lm-sensors is genuinely optional
    here: temperatures are a nice-to-have next to the lighting, and a machine
    without the package installed is a supported configuration rather than a
    broken one. Every caller already treats a missing reading as `None`, so an
    empty dict flows through to "—" in the panel and `null` in `micachy-ctl
    status --json` with nothing further to do.

    Raising instead is not a theoretical difference. This is read on every
    poll from the bar widget, so an uncaught FileNotFoundError is a crash loop
    on exactly the machines least able to diagnose it — and the widget runs
    inside the user's shell process.

    All three failure modes are real: no `sensors` binary at all
    (FileNotFoundError), a non-zero exit from a partial or misconfigured
    lm-sensors setup (CalledProcessError), and output that is not JSON
    (JSONDecodeError, which subclasses ValueError).
    """
    try:
        out = subprocess.run(
            ["sensors", "-j"], capture_output=True, text=True, check=True
        ).stdout
        return json.loads(out)
    except (OSError, subprocess.CalledProcessError, ValueError):
        return {}


def read_fans(data: dict | None = None) -> list[FanReading]:
    readings = []
    for chip, entries in (data if data is not None else _read_sensors_json()).items():
        for label, values in entries.items():
            if not isinstance(values, dict):
                continue
            for key, val in values.items():
                if key.endswith("_input") and "fan" in key and val <= MAX_PLAUSIBLE_RPM:
                    readings.append(FanReading(chip=chip, label=label, rpm=val))
    return readings


def read_temps(data: dict | None = None) -> list[TempReading]:
    readings = []
    for chip, entries in (data if data is not None else _read_sensors_json()).items():
        for label, values in entries.items():
            if not isinstance(values, dict):
                continue
            for key, val in values.items():
                if key.endswith("_input") and "temp" in key:
                    readings.append(TempReading(chip=chip, label=label, celsius=val))
    return readings


def read_cpu_temp(data: dict | None = None) -> float | None:
    """CPU package temperature from k10temp's Tctl.

    Deliberately not the Super I/O's CPUTIN: that is a motherboard thermistor
    near the socket and lags well behind the die, while k10temp reads the
    CPU's own sensor.
    """
    for t in read_temps(data):
        if t.chip.startswith("k10temp") and t.label == "Tctl":
            return t.celsius
    return None


def read_gpu_temp(data: dict | None = None) -> float | None:
    """Discrete GPU edge temperature.

    Two amdgpu chips are present (discrete card and the CPU's integrated
    graphics); the discrete one is distinguished by exposing a fan.
    """
    readings = data if data is not None else _read_sensors_json()
    for chip, entries in readings.items():
        if not chip.startswith("amdgpu"):
            continue
        if not any(k.startswith("fan") for k in entries):
            continue  # integrated GPU — no fan
        edge = entries.get("edge", {})
        for key, val in edge.items():
            if key.endswith("_input"):
                return val
    return None


def read_cpu_fan_rpm(data: dict | None = None) -> float | None:
    """The cooler's fan speed, for the panel's RPM readout.

    Read from the in-tree nct6775 driver's `fan2`, the CPU_FAN header.

    Until 0.6.0 this read "CPU Fan" from the out-of-tree nct6687d driver
    loaded with force=1, and that number was never a fan speed. The chip is
    an NCT6799D, not an NCT6687D; forced onto it, nct6687 read the wrong
    registers and returned constants — 768 (0x0300) for "CPU Fan" and 255
    (0x00FF) for "Pump Fan", unchanged from idle to full load, beside
    temperatures of 3.5 °C and an EC firmware version of 255.255. Checked
    2026-11-18: under nct6775 the same header reads ~450 rpm idle and ~1720
    under an all-core load, tracking its PWM. So nct6687 is not a fallback
    here; a chip by that name is ignored.

    The discrete GPU's fan1 (amdgpu-pci-0300) is the card's own fan — it
    idles at 0 under fan-stop and must never be reported here.

    None means no reading: either the chip is absent (see
    cpu_fan_chip_present) or the fan is stopped.
    """
    for f in read_fans(data):
        if (f.chip.startswith(CPU_FAN_CHIP_PREFIX) and f.label == CPU_FAN_LABEL
                and f.rpm > 0):
            return f.rpm
    return None


def cpu_fan_chip_present(data: dict | None = None) -> bool:
    """Whether the Super I/O chip that carries the CPU fan is exposed at all.

    The chip has no PCI modalias, so nct6775 is never autoloaded: it appears
    only once something loads the module. That makes this the difference
    between a fan that is stopped and a fan that nothing is reading.
    `read_cpu_fan_rpm` cannot tell them apart — it returns None for both,
    because a loaded chip reporting 0 rpm and an absent chip are the same one
    line of output. They are not the same problem, and the fix is only
    obvious once you know which one you have.
    """
    readings = data if data is not None else _read_sensors_json()
    return any(chip.startswith(CPU_FAN_CHIP_PREFIX) for chip in readings)


def read_cpu_load() -> int:
    """Whole-CPU utilisation percentage, sampled over a short interval."""
    def _busy_total() -> tuple[int, int]:
        with open("/proc/stat") as f:
            parts = [int(x) for x in f.readline().split()[1:]]
        idle = parts[3] + parts[4]  # idle + iowait
        return sum(parts) - idle, sum(parts)

    busy1, total1 = _busy_total()
    time.sleep(0.2)
    busy2, total2 = _busy_total()
    delta_total = total2 - total1
    if delta_total <= 0:
        return 0
    return max(0, min(100, round((busy2 - busy1) * 100 / delta_total)))
