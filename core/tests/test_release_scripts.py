from __future__ import annotations

import json
import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def make_executable(path: Path, body: str) -> None:
    path.write_text(body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)


class ReleaseScriptTests(unittest.TestCase):
    def test_bridge_runner_uses_explicit_core_path(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            db_path = Path(temp_dir) / "history.sqlite3"
            result = subprocess.run(
                [
                    "python3",
                    str(ROOT / "shell/Sources/AppleLocalOrganizerApp/Resources/bridge_runner.py"),
                    '{"type":"ListRecentResults","payload":{}}',
                ],
                check=True,
                capture_output=True,
                text=True,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_CORE": str(ROOT / "core/src"),
                    "APPLE_LOCAL_AI_HISTORY_DB": str(db_path),
                },
            )
            payload = json.loads(result.stdout)
            self.assertTrue(payload["ok"])

    def test_build_app_dry_run_creates_bundle_structure(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            runtime = temp_root / "runtime"
            (runtime / "bin").mkdir(parents=True)
            (runtime / "lib").mkdir(parents=True)
            make_executable(runtime / "bin/python3", "#!/bin/zsh\nexit 0\n")
            (runtime / "lib/libpython3.12.dylib").write_text("stub", encoding="utf-8")
            swift_binary = temp_root / "AppleLocalOrganizerApp"
            make_executable(swift_binary, "#!/bin/zsh\nexit 0\n")
            build_dir = temp_root / "build"

            subprocess.run(
                [
                    "zsh",
                    str(ROOT / "release/build_app.sh"),
                    "--dry-run",
                    "--skip-swift-build",
                    "--skip-fixtures",
                ],
                check=True,
                cwd=ROOT,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_VENDOR_PYTHON": str(runtime),
                    "APPLE_LOCAL_AI_SWIFT_BINARY": str(swift_binary),
                    "APPLE_LOCAL_AI_RELEASE_BUILD_DIR": str(build_dir),
                },
            )

            app_dir = build_dir / "DropSort.app"
            self.assertTrue((app_dir / "Contents/MacOS/AppleLocalOrganizerApp").exists())
            self.assertTrue((app_dir / "Contents/Resources/python-runtime/bin/python3").exists())
            self.assertTrue((app_dir / "Contents/Resources/python/ailocaltools").exists())
            manifest = json.loads((build_dir / "build-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(manifest["app_path"], str(app_dir))

    def test_sign_and_package_dry_run_write_manifests(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            runtime = temp_root / "runtime"
            (runtime / "bin").mkdir(parents=True)
            (runtime / "lib").mkdir(parents=True)
            make_executable(runtime / "bin/python3", "#!/bin/zsh\nexit 0\n")
            (runtime / "lib/libpython3.12.dylib").write_text("stub", encoding="utf-8")
            swift_binary = temp_root / "AppleLocalOrganizerApp"
            make_executable(swift_binary, "#!/bin/zsh\nexit 0\n")
            build_dir = temp_root / "build"

            subprocess.run(
                [
                    "zsh",
                    str(ROOT / "release/build_app.sh"),
                    "--dry-run",
                    "--skip-swift-build",
                    "--skip-fixtures",
                ],
                check=True,
                cwd=ROOT,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_VENDOR_PYTHON": str(runtime),
                    "APPLE_LOCAL_AI_SWIFT_BINARY": str(swift_binary),
                    "APPLE_LOCAL_AI_RELEASE_BUILD_DIR": str(build_dir),
                },
            )

            app_dir = build_dir / "DropSort.app"
            subprocess.run(
                ["zsh", str(ROOT / "release/sign_app.sh"), "--dry-run", "--app", str(app_dir)],
                check=True,
                cwd=ROOT,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_RELEASE_BUILD_DIR": str(build_dir),
                    "DEVELOPER_ID_APP": "Developer ID Application: Example",
                },
            )
            subprocess.run(
                ["zsh", str(ROOT / "release/package_dmg.sh"), "--dry-run", "--app", str(app_dir)],
                check=True,
                cwd=ROOT,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_RELEASE_BUILD_DIR": str(build_dir),
                },
            )

            sign_manifest = json.loads((build_dir / "sign-manifest.json").read_text(encoding="utf-8"))
            dmg_manifest = json.loads((build_dir / "dmg-manifest.json").read_text(encoding="utf-8"))
            self.assertIn(str(app_dir / "Contents/Resources/python-runtime/bin/python3"), sign_manifest["nested"])
            self.assertEqual(dmg_manifest["app_path"], str(app_dir))

    def test_sign_dry_run_accepts_hash_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            runtime = temp_root / "runtime"
            (runtime / "bin").mkdir(parents=True)
            (runtime / "lib").mkdir(parents=True)
            make_executable(runtime / "bin/python3", "#!/bin/zsh\nexit 0\n")
            (runtime / "lib/libpython3.12.dylib").write_text("stub", encoding="utf-8")
            swift_binary = temp_root / "AppleLocalOrganizerApp"
            make_executable(swift_binary, "#!/bin/zsh\nexit 0\n")
            build_dir = temp_root / "build"

            subprocess.run(
                [
                    "zsh",
                    str(ROOT / "release/build_app.sh"),
                    "--dry-run",
                    "--skip-swift-build",
                    "--skip-fixtures",
                ],
                check=True,
                cwd=ROOT,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_VENDOR_PYTHON": str(runtime),
                    "APPLE_LOCAL_AI_SWIFT_BINARY": str(swift_binary),
                    "APPLE_LOCAL_AI_RELEASE_BUILD_DIR": str(build_dir),
                },
            )

            app_dir = build_dir / "DropSort.app"
            subprocess.run(
                ["zsh", str(ROOT / "release/sign_app.sh"), "--dry-run", "--app", str(app_dir)],
                check=True,
                cwd=ROOT,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_RELEASE_BUILD_DIR": str(build_dir),
                    "DEVELOPER_ID_APP_HASH": "0123456789ABCDEF0123456789ABCDEF01234567",
                },
            )

            sign_manifest = json.loads((build_dir / "sign-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(sign_manifest["identity_mode"], "hash")
            self.assertEqual(sign_manifest["identity"], "sha1:0123456789AB...")

    def test_notarize_dry_run_writes_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            build_dir = temp_root / "build"
            build_dir.mkdir()
            artifact = build_dir / "DropSort.dmg"
            artifact.write_text("stub", encoding="utf-8")

            subprocess.run(
                [
                    "zsh",
                    str(ROOT / "release/notarize_app.sh"),
                    "--dry-run",
                    "--artifact",
                    str(artifact),
                ],
                check=True,
                cwd=ROOT,
                env={
                    **os.environ,
                    "APPLE_LOCAL_AI_RELEASE_BUILD_DIR": str(build_dir),
                    "NOTARY_PROFILE": "local-notary-profile",
                    "TEAM_ID": "TEAM123456",
                },
            )

            notary_manifest = json.loads((build_dir / "notary-manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(notary_manifest["artifact_path"], str(artifact))
            self.assertEqual(notary_manifest["profile"], "local-notary-profile")
            self.assertEqual(notary_manifest["team_id"], "TEAM123456")
            self.assertEqual(notary_manifest["status"], "dry-run")

    def test_prepare_github_release_writes_notes_and_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            app_dir = temp_root / "DropSort.app"
            (app_dir / "Contents/MacOS").mkdir(parents=True)
            make_executable(app_dir / "Contents/MacOS/AppleLocalOrganizerApp", "#!/bin/zsh\nexit 0\n")
            dmg_path = temp_root / "DropSort.dmg"
            dmg_path.write_text("stub dmg", encoding="utf-8")
            output_dir = temp_root / "github-release"

            subprocess.run(
                [
                    "zsh",
                    str(ROOT / "release/prepare_github_release.sh"),
                    "--dry-run",
                    "--app",
                    str(app_dir),
                    "--dmg",
                    str(dmg_path),
                    "--output-dir",
                    str(output_dir),
                    "--tag",
                    "preview-test",
                ],
                check=True,
                cwd=ROOT,
            )

            notes_path = output_dir / "GITHUB_RELEASE_NOTES.md"
            manifest_path = output_dir / "github-release-manifest.json"
            self.assertTrue(notes_path.exists())
            self.assertTrue(manifest_path.exists())

            notes = notes_path.read_text(encoding="utf-8")
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertIn("preview-test", notes)
            self.assertEqual(manifest["tag"], "preview-test")
            self.assertEqual(manifest["dmg_path"], str(dmg_path))
