"""Checks on the Plasma applet that loading it cannot make.

Like the Quickshell panel, the applet is QML and cannot be unit tested from
here. Everything below is a fact that spans files and whose absence is
silent: the applet would still load, still draw, and be wrong.
"""

from __future__ import annotations

import json
import re
import sys
import tomllib
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "src"))

from micachy.effects import EFFECTS  # noqa: E402

PACKAGE = REPO / "plasma" / "package"
MAIN = (PACKAGE / "contents" / "ui" / "main.qml").read_text()
INSTALLER = (REPO / "cachyos" / "install-applet").read_text()


def _string_list(name: str) -> list[str]:
    match = re.search(rf"readonly property var {name}: \[(.*?)\]", MAIN, re.S)
    assert match, f"the applet no longer declares `{name}` as a literal list"
    return re.findall(r'"([^"]*)"', match.group(1))


def test_effect_cells_are_the_backends_effects_in_its_order() -> None:
    """The cells pass these names to `micachy-ctl effect`, and the number
    keys index into them. A name the backend dropped is a cell that errors
    on click; a different order is a `3` that picks the wrong effect."""
    assert _string_list("effects") == list(EFFECTS)


def test_the_applet_and_the_package_agree_on_identity_and_version() -> None:
    """The installer names the package by id to decide between install and
    upgrade, so an id that drifts from metadata.json installs a second copy
    every run."""
    plugin = json.loads((PACKAGE / "metadata.json").read_text())["KPlugin"]
    project = tomllib.loads((REPO / "pyproject.toml").read_text())["project"]

    assert plugin["Version"] == project["version"]
    assert f'id="{plugin["Id"]}"' in INSTALLER


def test_the_checked_in_backend_path_is_empty() -> None:
    """A path committed here would be one developer's home directory in
    everyone's applet. The installer writes it into the installed copy."""
    backend = (PACKAGE / "contents" / "ui" / "backend.js").read_text()
    assert re.search(r'^var dir = ""$', backend, re.M)
    assert "backend.js" in INSTALLER


def test_linked_issues_commands_without_a_zone() -> None:
    """Same contract as the Quickshell panel: an empty block key omits
    `--zone`, so a linked click writes every zone's stored state."""
    fn = re.search(r"function zoneArgs\(block\)\s*\{(.*?)\n    \}", MAIN, re.S)
    assert fn, "zoneArgs is gone — nothing decides whether --zone is passed"
    assert re.search(r'block\.key\s*!==\s*""', fn.group(1))
    assert "[]" in fn.group(1)


def test_speed_is_set_absolutely_rather_than_stepped() -> None:
    assert re.search(r'"speed",\s*"set",\s*String\(index \+ 1\)', MAIN)


def test_every_argument_reaches_the_shell_quoted() -> None:
    """The `executable` engine runs one string through a shell. Zone names
    come from the user's config and `#ffffff` starts a comment, so an
    unquoted argument is at best a colour that silently never arrives."""
    fn = re.search(r"function ctl\(args\)\s*\{(.*?)\n    \}", MAIN, re.S)
    assert fn, "ctl() is gone — commands are being assembled somewhere else"
    assert "args.map(quote)" in fn.group(1)
    assert "quote(backendDir" in fn.group(1)


def test_the_applet_does_not_supervise_the_daemons() -> None:
    """On Plasma the daemons are systemd user units. An applet that also
    spawned micachy-lightd would race systemd for the pidfile."""
    assert "/micachy-lightd" not in MAIN
    assert "lightCommand" not in MAIN
