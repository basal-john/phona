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

def test_installer_copies_every_engine_module():
    """install.sh once shipped without audit.py, so a fresh install had no audit."""
    script = (ROOT / "install.sh").read_text()
    for module in ("phonad.py", "client.py", "audit.py"):
        assert module in script, f"install.sh does not install {module}"


def test_installer_honours_the_data_directory_override():
    script = (ROOT / "install.sh").read_text()
    assert "PHONA_HOME" in script, "the install target must be overridable for testing"


def test_installer_never_hardcodes_the_data_directory():
    """A step once hardcoded ~/.local/share/phona in sys.path and ignored the install
    target, so installing anywhere else failed with ModuleNotFoundError.

    Comment lines are skipped, since naming the default location is documentation rather
    than behaviour.
    """
    script = (ROOT / "install.sh").read_text()
    hardcoded = [
        line for line in script.splitlines()
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


def test_update_script_leaves_no_second_copy_of_the_app():
    """The staged build copy used to stay in macapp/build after being installed, so Spotlight
    and Launchpad offered two Phonas with the same identifier and no way to tell them apart.
    """
    script = (ROOT / "update.sh").read_text()
    assert "rm -rf macapp/build/Phona.app" in script, \
        "update.sh must remove the staged copy once it is installed"


# --- the app bundle ----------------------------------------------------------------

def test_every_cue_is_bundled():
    """Only one cue was bundled once, so pressing Option fell back to the macOS Tink."""
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


def test_the_readme_icon_is_generated_rather_than_hand_placed():
    """The header image was copied out of the iconset by hand, so redrawing the mark left
    the README showing the previous one."""
    source = (ROOT / "macapp/make_icon.py").read_text()
    assert "docs" in source and "icon.png" in source, (
        "make_icon.py does not write the README header, so the two can drift apart")


def test_the_menu_bar_carries_the_app_mark():
    """The menu bar used the `waveform` system symbol, which is the generic audio glyph and
    matched neither the app icon nor anything specific to Phona."""
    source = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    assert "menuBarMark()" in source
    assert 'systemSymbolName: "waveform"' not in source


def test_a_take_that_captured_nothing_is_reported_as_a_dead_microphone():
    """A wedged capture layer produced a 4 kB wav with no frames in it, and the user was
    shown the same quiet nothing-heard as an empty room. It went unrecognised for an hour."""
    source = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    body = swift_function(source, "private func deliver")
    assert "recorder.capturedAnyAudio" in body, \
        "deliver must check whether any audio arrived before blaming the speaker"
    assert body.index("take.seconds >= minSeconds") < body.index("capturedAnyAudio"), \
        ("the length check must come first. The first buffer lands around 450 ms after the "
         "device opens, so a short Option tap has captured nothing through no fault of the "
         "microphone, and asking first called every tap a dead microphone")

    recorder = (ROOT / "macapp/Sources/PhonaApp/Recorder.swift").read_text()
    assert "receivedAnyAudio" in recorder
    assert "var capturedAnyAudio" in recorder


def test_a_failure_leaves_a_mark_that_outlives_the_capsule():
    """A failure showed a warning glyph for 0.8 s with the reason only in a tooltip, so a
    dozen consecutive ffmpeg failures read as ordinary empty dictations."""
    source = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    assert "private func fail(" in source
    assert "private func clearFailureMark()" in source

    hud = (ROOT / "macapp/Sources/PhonaApp/HUD.swift").read_text()
    linger = swift_function(hud, "func finish(")
    assert "case .failed: linger = 2.5" in linger, \
        "a failure must outstay every other outcome"


def test_a_trimmed_result_is_never_shown_as_a_clean_one():
    """Salvaging a looping transcript pastes text that reads as finished while being
    shorter than what was said, so it needs its own outcome, not `done`."""
    hud = (ROOT / "macapp/Sources/PhonaApp/HUD.swift").read_text()
    assert "case trimmed" in hud
    assert 'case .trimmed: return "scissors"' in hud

    source = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    assert "result.trimmedWords > 0" in source
    assert "hud.finish(.trimmed)" in source

    client = (ROOT / "macapp/Sources/PhonaApp/DaemonClient.swift").read_text()
    assert 'reply["trimmed"]' in client, "the trim count must survive the daemon reply"


def test_abandoned_takes_are_swept_up():
    """Finished takes are deleted, failed ones were not, so an hour of a dead microphone
    left a pile of 4 kB wavs that nothing would ever collect."""
    source = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    assert "private func sweepAbandonedTakes()" in source
    assert "sweepAbandonedTakes()" in swift_function(source, "func applicationDidFinishLaunching")


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
    a restart could silently swap the weights and change behaviour.

    It must work by handing the loader a resolved local path. Relying on HF_HUB_OFFLINE does
    not, because huggingface_hub freezes that flag into a module constant when it is first
    imported, so setting it later is ignored.
    """
    source = (ROOT / "engine/phonad.py").read_text()
    assert '"pin_models": True' in source
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


def test_the_clipboard_is_only_restored_when_a_target_is_confirmed():
    """Regression: pasting is unverifiable, so a dictation delivered with nothing focused
    vanished twice over. The keystroke went nowhere and the restore then overwrote the
    text, while the user got a success chime."""
    source = (ROOT / "macapp/Sources/PhonaApp/Paster.swift").read_text()
    assert "FocusProbe.current()" in source, "the paste path does not check for a target"
    assert "target == .editable" in source, (
        "the clipboard is restored without confirming the paste could land")
    assert "leftOnClipboard" in source, "there is no path that keeps unplaceable text"


def test_no_editable_target_means_no_keystroke():
    """Firing Cmd+V into Finder means paste a file, which is not what was asked for."""
    source = (ROOT / "macapp/Sources/PhonaApp/Paster.swift").read_text()
    assert "if target == .notEditable" in source


def swift_function(source, signature):
    """The body of a Swift function declared at one level of indentation."""
    start = source.index(signature)
    return source[start:source.index("\n    }", start)]


@pytest.mark.parametrize("signature", [
    "private func endDictation",
    "private func abortDictation",
    "func applicationWillTerminate",
])
def test_every_path_out_of_a_dictation_unmutes(signature):
    """A mute that outlives the dictation leaves the Mac silent with nothing on screen to
    explain it, and the user has nothing to undo because they never muted anything."""
    source = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    assert "OutputMute.release()" in swift_function(source, signature), (
        f"{signature} can leave the output muted")


def test_muting_waits_for_the_first_audio_buffer():
    """Muting when Option goes down swallows the start cue, which is the only confirmation
    that something is listening before the waveform starts moving. The device takes a few
    hundred milliseconds to deliver a buffer, and nothing recorded before that exists."""
    source = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    assert "OutputMute.engage()" in swift_function(source, "private func startLevelTimer")
    assert "OutputMute.engage()" not in swift_function(source, "private func beginDictation")


def test_an_interrupted_dictation_cannot_leave_the_mac_muted():
    """Being killed between the mute and the restore is the one failure the user cannot
    connect to Phona, so what was taken away is recorded and put back at the next launch."""
    app = (ROOT / "macapp/Sources/PhonaApp/main.swift").read_text()
    mute = (ROOT / "macapp/Sources/PhonaApp/OutputMute.swift").read_text()
    assert "OutputMute.recoverFromInterruptedDictation()" in app
    assert "UserDefaults.standard.set" in mute, "nothing survives the process to restore from"


def test_muting_falls_back_when_a_device_has_no_mute_control():
    """Bluetooth and aggregate devices commonly expose only a volume, and setting a property
    a device does not have fails silently, which would look like the feature doing nothing."""
    source = (ROOT / "macapp/Sources/PhonaApp/OutputMute.swift").read_text()
    assert "kAudioDevicePropertyMute" in source
    assert "kAudioDevicePropertyVolumeScalar" in source
    assert "kAudioDevicePropertyPreferredChannelsForStereo" in source
    assert "AudioObjectIsPropertySettable" in source, (
        "a control is used without asking the device whether it can be set")


def test_the_hud_distinguishes_placed_from_copied():
    """A checkmark would claim the text was inserted when it is only on the clipboard."""
    hud = (ROOT / "macapp/Sources/PhonaApp/HUD.swift").read_text()
    assert "case clipboard" in hud
    assert "doc.on.clipboard" in hud, "the clipboard state reuses the success glyph"


def test_initial_prompt_is_off_by_default():
    """It improves rare names but makes Whisper invent words during silence."""
    source = (ROOT / "engine/phonad.py").read_text()
    assert '"use_initial_prompt": False' in source
