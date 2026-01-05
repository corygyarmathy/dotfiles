#!/usr/bin/env python3
"""
DDC/CI Brightness Daemon

Automatically adjusts external monitor brightness based on time of day,
with optional sunrise/sunset awareness and per-monitor offsets.
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from types import FrameType
from typing import Any

# Optional: sunrise/sunset calculation
try:
    from astral import LocationInfo
    from astral.sun import sun

    ASTRAL_AVAILABLE = True
except ImportError:
    ASTRAL_AVAILABLE = False

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
log = logging.getLogger(__name__)


@dataclass
class MonitorConfig:
    """Configuration for a registered monitor."""

    serial: str
    offset: int = 0
    enabled: bool = True


@dataclass
class PeriodConfig:
    """Configuration for a brightness period."""

    time: str
    brightness: int
    sun_relative: bool = False
    sun_event: str = "sunrise"
    sun_offset: int = 0


@dataclass
class LocationConfig:
    """Location configuration for sun calculations."""

    latitude: float | None = None
    longitude: float | None = None

    @property
    def is_valid(self) -> bool:
        return self.latitude is not None and self.longitude is not None


@dataclass
class DetectedMonitor:
    """A monitor detected via ddcutil."""

    display_num: str
    bus: str = ""
    model: str = ""
    serial: str = ""


@dataclass
class SunTimes:
    """Sun event times for a given day."""

    dawn: datetime
    sunrise: datetime
    sunset: datetime
    dusk: datetime


@dataclass
class DaemonState:
    """Current state of the brightness daemon."""

    timestamp: str
    base_brightness: int
    monitors: dict[str, int] = field(default_factory=dict)


def get_state_dir() -> Path:
    """Get the state directory for runtime data."""
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    state_dir = Path(runtime_dir) / "ddc-brightness"
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir


def get_override_file() -> Path:
    """Get the path to the manual override file."""
    return get_state_dir() / "manual_override"


def get_state_file() -> Path:
    """Get the path to the current state file."""
    return get_state_dir() / "current_state.json"


class BrightnessController:
    """Controls monitor brightness via DDC/CI."""

    def __init__(self, config_path: str) -> None:
        with open(config_path) as f:
            raw_config: dict[str, Any] = json.load(f)

        self.base_brightness: int = raw_config.get("baseBrightness", 50)
        self.transition_minutes: int = raw_config.get("transitionMinutes", 60)

        # Parse periods
        self.periods: dict[str, PeriodConfig] = {}
        for name, period_data in raw_config.get("periods", {}).items():
            self.periods[name] = PeriodConfig(
                time=period_data.get("time", "12:00"),
                brightness=period_data.get("brightness", self.base_brightness),
                sun_relative=period_data.get("sunRelative", False),
                sun_event=period_data.get("sunEvent", "sunrise"),
                sun_offset=period_data.get("sunOffset", 0),
            )

        # Parse monitors
        self.monitors: dict[str, MonitorConfig] = {}
        for name, mon_data in raw_config.get("monitors", {}).items():
            self.monitors[name] = MonitorConfig(
                serial=mon_data.get("serial", ""),
                offset=mon_data.get("offset", 0),
                enabled=mon_data.get("enabled", True),
            )

        # Parse location
        loc_data = raw_config.get("location", {})
        self.location = LocationConfig(
            latitude=loc_data.get("latitude"),
            longitude=loc_data.get("longitude"),
        )

        # Cache for detected monitors
        self._detected_monitors: list[DetectedMonitor] | None = None
        self._last_detection: float = 0

        log.info(
            f"Loaded config: base={self.base_brightness}, "
            + f"transition={self.transition_minutes}min"
        )
        log.info(f"Periods: {list(self.periods.keys())}")
        log.info(f"Registered monitors: {list(self.monitors.keys())}")

    def detect_monitors(self, force: bool = False) -> list[DetectedMonitor]:
        """Detect connected external monitors via ddcutil."""
        now = time.time()

        # Cache detection for 5 minutes
        if (
            not force
            and self._detected_monitors is not None
            and (now - self._last_detection) < 300
        ):
            return self._detected_monitors

        try:
            result = subprocess.run(
                ["ddcutil", "detect", "--brief"],
                capture_output=True,
                text=True,
                timeout=30,
            )

            monitors: list[DetectedMonitor] = []
            current_display: dict[str, str] = {}

            for line in result.stdout.splitlines():
                line = line.strip()
                if line.startswith("Display"):
                    if current_display:
                        monitors.append(
                            DetectedMonitor(
                                display_num=current_display.get("display_num", ""),
                                bus=current_display.get("bus", ""),
                                model=current_display.get("model", ""),
                                serial=current_display.get("serial", ""),
                            )
                        )
                    parts = line.split()
                    current_display = {
                        "display_num": parts[1] if len(parts) > 1 else ""
                    }
                elif line.startswith("I2C bus:"):
                    current_display["bus"] = line.split()[-1]
                elif line.startswith("Monitor:"):
                    # Brief format: "Monitor: MFG:MODEL:SERIAL"
                    monitor_info = line.split(":", 1)[1].strip()
                    monitor_parts = monitor_info.split(":")
                    if len(monitor_parts) >= 3:
                        current_display["model"] = monitor_parts[1]
                        current_display["serial"] = monitor_parts[2]
                    elif len(monitor_parts) == 2:
                        current_display["model"] = monitor_parts[1]
                elif line.startswith("Model:"):
                    current_display["model"] = line.split(":", 1)[1].strip()
                elif line.startswith("Serial number:"):
                    current_display["serial"] = line.split(":", 1)[1].strip()

            if current_display:
                monitors.append(
                    DetectedMonitor(
                        display_num=current_display.get("display_num", ""),
                        bus=current_display.get("bus", ""),
                        model=current_display.get("model", ""),
                        serial=current_display.get("serial", ""),
                    )
                )

            self._detected_monitors = monitors
            self._last_detection = now
            log.info(f"Detected {len(monitors)} external monitors")
            return monitors

        except subprocess.TimeoutExpired:
            log.error("ddcutil detect timed out")
            return self._detected_monitors or []
        except Exception as e:
            log.error(f"Error detecting monitors: {e}")
            return self._detected_monitors or []

    def get_monitor_offset(self, monitor: DetectedMonitor) -> int | None:
        """
        Get brightness offset for a specific monitor.

        Returns None if the monitor is disabled.
        """
        serial = monitor.serial

        for mon_config in self.monitors.values():
            if mon_config.serial == serial:
                if not mon_config.enabled:
                    return None  # Monitor disabled
                return mon_config.offset

        # Unknown monitor - use default (no offset)
        return 0

    def get_sun_times(self, date: datetime) -> SunTimes | None:
        """Get sunrise/sunset times for the given date."""
        if not ASTRAL_AVAILABLE or not self.location.is_valid:
            return None

        try:
            loc = LocationInfo(
                latitude=self.location.latitude,
                longitude=self.location.longitude,
            )
            s = sun(loc.observer, date=date.date())
            return SunTimes(
                dawn=s["dawn"].astimezone().replace(tzinfo=None),
                sunrise=s["sunrise"].astimezone().replace(tzinfo=None),
                sunset=s["sunset"].astimezone().replace(tzinfo=None),
                dusk=s["dusk"].astimezone().replace(tzinfo=None),
            )
        except Exception as e:
            log.warning(f"Failed to calculate sun times: {e}")
            return None

    def get_period_times(self, now: datetime) -> dict[str, datetime]:
        """Get the start times for each period, optionally adjusted for sun."""
        sun_times = self.get_sun_times(now)

        period_times: dict[str, datetime] = {}
        for name, period in self.periods.items():
            period_time: datetime | None = None

            # Check for sun-relative times
            if sun_times and period.sun_relative:
                sun_event_time: datetime | None = None
                if period.sun_event == "dawn":
                    sun_event_time = sun_times.dawn
                elif period.sun_event == "sunrise":
                    sun_event_time = sun_times.sunrise
                elif period.sun_event == "sunset":
                    sun_event_time = sun_times.sunset
                elif period.sun_event == "dusk":
                    sun_event_time = sun_times.dusk

                if sun_event_time is not None:
                    period_time = sun_event_time + timedelta(minutes=period.sun_offset)

            # Fall back to fixed time
            if period_time is None:
                hour, minute = map(int, period.time.split(":"))
                period_time = now.replace(
                    hour=hour, minute=minute, second=0, microsecond=0
                )

            period_times[name] = period_time

        return period_times

    def get_target_brightness(self, now: datetime) -> int:
        """Calculate the target brightness for the current time."""
        period_times = self.get_period_times(now)

        if not period_times:
            return self.base_brightness

        # Convert period times to a list and sort by time-of-day (hour:minute),
        # not by absolute datetime. This gives us the daily schedule order.
        def time_of_day(dt: datetime) -> tuple[int, int]:
            return (dt.hour, dt.minute)

        sorted_periods = sorted(period_times.items(), key=lambda x: time_of_day(x[1]))

        # Find which period we're currently in based on time of day
        now_time = (now.hour, now.minute)

        current_period: tuple[str, datetime] | None = None
        next_period: tuple[str, datetime] | None = None

        # Find the last period that started before or at current time
        for i, (name, start_time) in enumerate(sorted_periods):
            period_start = time_of_day(start_time)
            if now_time >= period_start:
                current_period = (name, start_time)
                if i + 1 < len(sorted_periods):
                    next_period = sorted_periods[i + 1]
                else:
                    # After last period - next is first period (tomorrow)
                    first_name, first_time = sorted_periods[0]
                    next_period = (first_name, first_time + timedelta(days=1))

        if current_period is None:
            # Before first period today - we're in yesterday's last period
            last_name, last_time = sorted_periods[-1]
            current_period = (last_name, last_time - timedelta(days=1))
            next_period = sorted_periods[0]

        assert next_period is not None

        current_name, _current_start = current_period
        next_name, next_start = next_period

        current_brightness = self.periods[current_name].brightness
        next_brightness = self.periods[next_name].brightness

        # Calculate transition - need to handle day boundary
        transition_duration = timedelta(minutes=self.transition_minutes)
        transition_start = next_start - transition_duration

        # For transition calculation, we need absolute times
        # If next_start is tomorrow, transition_start might be today
        if now >= transition_start:
            transition_progress = (now - transition_start).total_seconds() / (
                self.transition_minutes * 60
            )
            transition_progress = min(1.0, max(0.0, transition_progress))

            target = (
                current_brightness
                + (next_brightness - current_brightness) * transition_progress
            )
            return int(round(target))

        return current_brightness

    def set_brightness(self, display_num: str, brightness: int) -> bool:
        """Set brightness for a specific display."""
        brightness = max(0, min(100, brightness))

        try:
            result = subprocess.run(
                ["ddcutil", "setvcp", "10", str(brightness), "--display", display_num],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode != 0:
                log.warning(
                    f"Failed to set brightness for display {display_num}: "
                    + f"{result.stderr}"
                )
                return False
            return True
        except subprocess.TimeoutExpired:
            log.error(f"ddcutil setvcp timed out for display {display_num}")
            return False
        except Exception as e:
            log.error(f"Error setting brightness: {e}")
            return False

    def get_brightness(self, display_num: str) -> int | None:
        """Get current brightness for a specific display."""
        try:
            result = subprocess.run(
                ["ddcutil", "getvcp", "10", "--display", display_num, "--brief"],
                capture_output=True,
                text=True,
                timeout=10,
            )
            if result.returncode == 0:
                # Parse output like "VCP 10 C 50 100"
                parts = result.stdout.strip().split()
                if len(parts) >= 4:
                    return int(parts[3])
        except Exception as e:
            log.debug(f"Error getting brightness: {e}")
        return None

    def is_override_active(self) -> bool:
        """Check if manual override is currently active."""
        override_file = get_override_file()
        if not override_file.exists():
            return False

        try:
            override_time = float(override_file.read_text().strip())
            if time.time() - override_time < 3600:
                return True
            else:
                override_file.unlink()
                log.info("Manual override expired")
                return False
        except Exception:
            return False

    def update_all_monitors(self) -> dict[str, int]:
        """Update brightness for all connected monitors."""
        if self.is_override_active():
            log.debug("Manual override active, skipping update")
            return {}

        monitors = self.detect_monitors()
        now = datetime.now()
        target = self.get_target_brightness(now)

        results: dict[str, int] = {}
        for monitor in monitors:
            display_num = monitor.display_num
            if not display_num:
                continue

            offset = self.get_monitor_offset(monitor)
            if offset is None:
                log.debug(f"Monitor {display_num} is disabled, skipping")
                continue

            final_brightness = max(0, min(100, target + offset))

            if self.set_brightness(display_num, final_brightness):
                results[display_num] = final_brightness
                log.info(
                    f"Display {display_num}: set to {final_brightness}% "
                    + f"(base {target}% + offset {offset})"
                )

        # Save state
        state = DaemonState(
            timestamp=now.isoformat(),
            base_brightness=target,
            monitors=results,
        )
        _ = get_state_file().write_text(
            json.dumps(
                {
                    "timestamp": state.timestamp,
                    "base_brightness": state.base_brightness,
                    "monitors": state.monitors,
                },
                indent=2,
            )
        )

        return results

    def run_daemon(self, interval: int = 60) -> None:
        """Run the brightness daemon."""
        log.info(f"Starting brightness daemon (interval: {interval}s)")

        def handle_signal(signum: int, frame: FrameType | None) -> None:
            log.info("Received signal, exiting...")
            sys.exit(0)

        _ = signal.signal(signal.SIGTERM, handle_signal)
        _ = signal.signal(signal.SIGINT, handle_signal)

        while True:
            try:
                _ = self.update_all_monitors()
            except Exception as e:
                log.error(f"Error in update loop: {e}")
            time.sleep(interval)

    def print_status(self) -> None:
        """Print current status information."""
        monitors = self.detect_monitors()
        now = datetime.now()
        target = self.get_target_brightness(now)

        sun_times = self.get_sun_times(now)
        if sun_times:
            print(
                f"Sun times: sunrise={sun_times.sunrise.strftime('%H:%M')}, "
                + f"sunset={sun_times.sunset.strftime('%H:%M')}"
            )

        print(f"Current time: {now.strftime('%H:%M')}")
        print(f"Target brightness: {target}%")
        print(f"Detected monitors: {len(monitors)}")

        for m in monitors:
            offset = self.get_monitor_offset(m)
            current = self.get_brightness(m.display_num)
            print(
                f"  Display {m.display_num}: {m.model or 'Unknown'} ({m.serial or 'no serial'})"
            )
            target_with_offset = target + (offset if offset is not None else 0)
            print(
                f"    Current: {current}%, Target: {target_with_offset}%, Offset: {offset}"
            )


def main() -> None:
    """Main entry point for the daemon."""
    parser = argparse.ArgumentParser(description="DDC/CI Brightness Controller")
    _ = parser.add_argument("--config", required=True, help="Path to config file")
    _ = parser.add_argument("--daemon", action="store_true", help="Run as daemon")
    _ = parser.add_argument(
        "--interval", type=int, default=60, help="Update interval (seconds)"
    )
    _ = parser.add_argument("--once", action="store_true", help="Run once and exit")

    args = parser.parse_args()

    controller = BrightnessController(args.config)

    if args.daemon:
        controller.run_daemon(args.interval)
    elif args.once:
        _ = controller.update_all_monitors()
    else:
        controller.print_status()


if __name__ == "__main__":
    main()
