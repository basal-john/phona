"""Packaging and asset checks. These catch the shipping mistakes, not the logic ones.

Every case here is a defect that reached a user or nearly did.
"""

import json
import pathlib
import plistlib
import re
import struct
import subprocess

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent
INFO = ROOT / "macapp/Resources/Info.plist"
SOUNDS = ROOT / "macapp/Resources/Sounds"
IMAGES = ROOT / "docs/images"


def png_first_pixel_alpha(path):
    """Read the top-left pixel's alpha without a third party imaging library."""
    out = subprocess.run(
        ["/opt/homebrew/bin/ffmpeg", "-v", "error", "-i", str(path),
         "-vf", "crop=1:1:0:0,format=rgba", "-f", "rawvideo", "-"],
        capture_output=True)
    if out.returncode != 0 or len(out.stdout) < 4:
        pytest.skip("ffmpeg unavailable")
    return out.stdout[3]


# --- the installer -----------------------------------------------------------------
# Regression: install.sh never copied audit.py, so a fresh install had no audit. It also
# wrote settings to the real data directory regardless of where it was installing.

def test_installer_copies_every_engine_module():
    script = (ROOT / "install.sh").read_text()
    for module in ("phonad.py", "client.py", "audit.py"):
        assert module in script, f"install.sh does not install {module}"


def test_installer_honours_the_data_directory_override():
    script = (ROOT / "install.sh").read_text()
    assert "PHONA_HOME" in script, "the install target must be overridable for testing"


def test_installer_never_hardcodes_the_data_directory():
    """Regression: a step hardcoded ~/.local/share/phona in sys.path and ignored the
    install target, so installing anywhere else failed with ModuleNotFoundError."""
    script = (ROOT / "install.sh").read_text()
    hardcoded = [
        line for line in script.splitlines()
        # Comments may name the default location, that is documentation not behaviour.
        if ".local/share/phona" in line
        and "PHONA_HOME" not in line
        and not line.lstrip().startswith("#")
    ]
    assert not hardcoded, f"hardcoded install path in {hardcoded}"


def test_engine_modules_honour_the_data_directory_override():
    for name in ("phonad.py", "client.py", "audit.py"):
        source = (ROOT / "engine" / name).read_text()
        assert "PHONA_HOME" in source, f"{name} hardcodes the data directory"


def test_update_script_exists_and_is_executable():
    script = ROOT / "update.sh"
    assert script.exists(), "there must be a documented way to receive fixes"
    assert script.stat().st_mode & 0o111, "update.sh must be executable"


# --- the app bundle ----------------------------------------------------------------
# Regression: only one cue was bundled, so pressing Option fell back to the macOS Tink.

def test_every_cue_is_bundled():
    assert SOUNDS.is_dir(), "no bundled sounds, cues would fall back to system alerts"
    shipped = {p.stem for p in SOUNDS.glob("*.aiff")}
    for cue in ("start", "done", "nothing"):
        assert cue in shipped, f"the {cue} cue is missing and would use a system alert"


def test_build_script_copies_the_sounds():
    build = (ROOT / "macapp/build.sh").read_text()
    assert "Resources/Sounds" in build, "build.sh does not copy the cues into the bundle"


def test_signature_is_pinned_to_the_identifier_not_the_hash():
    """Regression: an ad-hoc designated requirement is the cdhash, so every rebuild
    silently orphaned the Accessibility grant while System Settings still showed it on."""
    build = (ROOT / "macapp/build.sh").read_text()
    assert 'designated => identifier' in build


def test_bundle_declares_a_microphone_purpose():
    info = plistlib.loads(INFO.read_bytes())
    assert info.get("NSMicrophoneUsageDescription"), "macOS requires a stated purpose"
    assert info.get("LSUIElement") is True, "this is a menu bar app, not a Dock app"


def test_version_is_a_sane_semver():
    info = plistlib.loads(INFO.read_bytes())
    version = info["CFBundleShortVersionString"]
    assert re.fullmatch(r"\d+\.\d+\.\d+", version), f"unusable version {version}"


def test_bundle_version_matches_the_latest_git_tag():
    """Regression: the app reported 1.0.0 while the release tag said v1.1.0, which makes
    any update comparison wrong."""
    info = plistlib.loads(INFO.read_bytes())
    try:
        tag = subprocess.run(["git", "describe", "--tags", "--abbrev=0"],
                             cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    except subprocess.CalledProcessError:
        pytest.skip("no tags in this checkout")
    assert tag.lstrip("v") == info["CFBundleShortVersionString"], (
        f"tag {tag} disagrees with bundle {info['CFBundleShortVersionString']}")


# --- documentation assets ----------------------------------------------------------
# Regression: the onboarding screenshot had a transparent background, so GitHub's dark
# theme showed through and the dark text became unreadable.

@pytest.mark.parametrize("name", [
    "onboarding-fresh.png", "onboarding-ready.png",
    "hud-listening.png", "hud-working.png", "hud-done.png",
])
def test_readme_screenshots_are_opaque(name):
    path = IMAGES / name
    if not path.exists():
        pytest.skip(f"{name} not present")
    assert png_first_pixel_alpha(path) == 255, (
        f"{name} is transparent, so it is unreadable on a dark page")


def test_readme_documents_where_data_is_stored():
    readme = (ROOT / "README.md").read_text()
    assert "history.jsonl" in readme
    assert "plain text" in readme.lower(), "the plain text history must be disclosed"


def test_readme_documents_how_to_update():
    readme = (ROOT / "README.md").read_text()
    assert "update.sh" in readme


# --- configuration defaults --------------------------------------------------------

def test_defaults_carry_no_personal_vocabulary():
    """A public default list should not ship one person's employer and tooling."""
    source = (ROOT / "engine/phonad.py").read_text()
    match = re.search(r'"dictionary":\s*\[(.*?)\]', source, re.S)
    assert match, "no default dictionary found"
    entries = [e.strip().strip('"') for e in match.group(1).split(",") if e.strip()]
    assert entries == ["Phona"], f"unexpected default vocabulary {entries}"


def test_models_are_pinned_by_default():
    """The loaders resolve the hub on every load with no revision pinned, so without this
    a restart could silently swap the weights and change behaviour."""
    source = (ROOT / "engine/phonad.py").read_text()
    assert '"pin_models": True' in source
    # Pinning must work by handing the loader a resolved local path. Relying on
    # HF_HUB_OFFLINE does not work, because huggingface_hub freezes that flag into a
    # module constant when it is first imported, so setting it later is ignored.
    assert "def resolve_local_model" in source
    assert "def pinned_target" in source


def test_pinning_does_not_rely_on_the_offline_environment_flag():
    """Regression: the first attempt set HF_HUB_OFFLINE at runtime, which only worked by
    luck of import order, and made mlx_whisper refuse a snapshot missing a README."""
    source = (ROOT / "engine/phonad.py").read_text()
    code = [
        line for line in source.splitlines()
        if "HF_HUB_OFFLINE" in line and not line.lstrip().startswith("#")
        and '"""' not in line and "    - " not in line
    ]
    assert not code, f"pinning still depends on the offline flag: {code}"


def test_the_loader_is_given_the_resolved_target():
    """Both loaders must receive the pinned target rather than the raw repo id."""
    source = (ROOT / "engine/phonad.py").read_text()
    assert "load(self.llm_target)" in source
    assert '"path_or_hf_repo": self.stt_target' in source


def test_there_is_a_deliberate_way_to_update_models():
    client = (ROOT / "engine/client.py").read_text()
    assert "update-models" in client, "pinning without an update path traps users"


def test_initial_prompt_is_off_by_default():
    """It improves rare names but makes Whisper invent words during silence."""
    source = (ROOT / "engine/phonad.py").read_text()
    assert '"use_initial_prompt": False' in source
