"""Tests for gasclaw.migration module."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from gasclaw.migration import (
    MigrationError,
    MigrationResult,
    _create_backup,
    _detect_gastown_installation,
    _migrate_environment_config,
    migrate,
    rollback,
)


class TestDetectGastownInstallation:
    """Tests for Gastown detection."""

    def test_detects_no_gastown(self, monkeypatch):
        """Returns not found when gt command missing."""
        def raise_not_found(*a, **kw):
            raise FileNotFoundError("gt not found")

        monkeypatch.setattr(subprocess, "run", raise_not_found)

        info = _detect_gastown_installation()
        assert info["found"] is False

    def test_detects_gastown_version(self, monkeypatch):
        """Detects Gastown version when available."""
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=b"gt version 1.0.0\n"),
        )

        info = _detect_gastown_installation()
        assert info["found"] is True
        assert "1.0.0" in info["version"]

    def test_detects_gastown_config(self, monkeypatch, tmp_path):
        """Detects Gastown config directory."""
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=b"gt version 1.0.0\n"),
        )

        # Create mock gastown directory
        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()
        (gt_root / "config.json").write_text("{}")

        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        info = _detect_gastown_installation()
        assert info["gt_path"] == str(gt_root)

    def test_detects_agents(self, monkeypatch, tmp_path):
        """Detects configured agents."""
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=b"gt version 1.0.0\n"),
        )

        gt_root = tmp_path / ".gastown"
        agents_dir = gt_root / "agents"
        agents_dir.mkdir(parents=True)
        (agents_dir / "mayor").mkdir()
        (agents_dir / "deacon").mkdir()

        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        info = _detect_gastown_installation()
        assert "mayor" in info["agents"]
        assert "deacon" in info["agents"]


class TestCreateBackup:
    """Tests for backup creation."""

    def test_creates_backup_directory(self, tmp_path):
        """Backup directory is created."""
        backup_dir = tmp_path / "backups"

        with patch("gasclaw.migration.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout="20240302_120000\n")
            backup_path = _create_backup(backup_dir)

        assert backup_path.exists()
        assert "gastown_backup_" in backup_path.name

    def test_backups_gastown_config(self, tmp_path, monkeypatch):
        """Gastown config is backed up."""
        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()
        (gt_root / "config.json").write_text('{"key": "value"}')

        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        backup_dir = tmp_path / "backups"

        with patch("gasclaw.migration.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout="20240302_120000\n")
            backup_path = _create_backup(backup_dir)

        backup_config = backup_path / "gastown" / "config.json"
        assert backup_config.exists()
        assert json.loads(backup_config.read_text()) == {"key": "value"}

    def test_handles_missing_gastown(self, tmp_path):
        """Handles case when Gastown not installed."""
        backup_dir = tmp_path / "backups"

        with patch("gasclaw.migration.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout="20240302_120000\n")
            # Should not raise even if .gastown doesn't exist
            backup_path = _create_backup(backup_dir)

        assert backup_path.exists()


class TestMigrateEnvironmentConfig:
    """Tests for config migration."""

    def test_extracts_kimi_keys(self, tmp_path, monkeypatch):
        """Extracts Kimi keys from config."""
        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()
        (gt_root / "config.json").write_text(json.dumps({
            "kimi_keys": ["sk-key1", "sk-key2"]
        }))

        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        config = _migrate_environment_config({"found": True})
        assert config["GASTOWN_KIMI_KEYS"] == "sk-key1:sk-key2"

    def test_extracts_project_dir(self, tmp_path, monkeypatch):
        """Extracts project directory from config."""
        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()
        (gt_root / "config.json").write_text(json.dumps({
            "project_dir": "/workspace/project"
        }))

        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        config = _migrate_environment_config({"found": True})
        assert config["PROJECT_DIR"] == "/workspace/project"

    def test_handles_missing_config(self, tmp_path, monkeypatch):
        """Returns empty dict when config missing."""
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        config = _migrate_environment_config({"found": True})
        assert config == {}

    def test_handles_invalid_json(self, tmp_path, monkeypatch):
        """Handles invalid JSON in config file."""
        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()
        (gt_root / "config.json").write_text("invalid json")

        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        config = _migrate_environment_config({"found": True})
        assert config == {}


class TestMigrate:
    """Tests for main migrate function."""

    def test_fails_when_no_gastown(self, monkeypatch):
        """Migration fails when Gastown not detected."""
        def raise_not_found(*a, **kw):
            raise FileNotFoundError("gt not found")

        monkeypatch.setattr(subprocess, "run", raise_not_found)

        result = migrate()
        assert result.success is False
        assert "No Gastown installation detected" in result.message

    def test_succeeds_with_force(self, monkeypatch, tmp_path):
        """Migration succeeds with force flag even without Gastown."""
        def raise_not_found(*a, **kw):
            raise FileNotFoundError("gt not found")

        monkeypatch.setattr(subprocess, "run", raise_not_found)
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        result = migrate(force=True)
        assert result.success is True

    def test_dry_run_shows_what_would_migrate(self, monkeypatch, tmp_path):
        """Dry run shows migration plan without making changes."""
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=b"gt version 1.0.0\n"),
        )
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()

        result = migrate(dry_run=True)
        assert result.success is True
        assert "DRY RUN" in result.message
        assert any("Gastown config" in item for item in result.migrated_items)

    def test_creates_backup(self, monkeypatch, tmp_path):
        """Migration creates backup."""
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=b"gt version 1.0.0\n"),
        )
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()
        (gt_root / "config.json").write_text("{}")

        result = migrate()
        assert result.success is True
        assert result.backup_path is not None
        assert result.backup_path.exists()

    def test_creates_migration_marker(self, monkeypatch, tmp_path):
        """Migration creates marker file."""
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=b"gt version 1.0.0\n"),
        )
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()

        result = migrate()
        assert result.success is True

        marker = tmp_path / ".gasclaw" / ".migrated_from_gastown"
        assert marker.exists()

    def test_migrates_configuration(self, monkeypatch, tmp_path):
        """Configuration is migrated to gasclaw."""
        monkeypatch.setattr(
            subprocess,
            "run",
            lambda *a, **kw: subprocess.CompletedProcess(a[0], 0, stdout=b"gt version 1.0.0\n"),
        )
        monkeypatch.setattr(Path, "home", lambda: tmp_path)

        gt_root = tmp_path / ".gastown"
        gt_root.mkdir()
        (gt_root / "config.json").write_text(json.dumps({
            "kimi_keys": ["sk-key1"],
            "project_dir": "/workspace/project"
        }))

        result = migrate()
        assert result.success is True

        env_file = tmp_path / ".gasclaw" / ".env"
        assert env_file.exists()
        content = env_file.read_text()
        assert "GASTOWN_KIMI_KEYS=" in content
        assert "PROJECT_DIR=" in content


class TestRollback:
    """Tests for rollback functionality."""

    def test_rollback_restores_config(self, tmp_path):
        """Rollback restores Gastown config."""
        # Create backup structure
        backup_path = tmp_path / "backup"
        gastown_backup = backup_path / "gastown"
        gastown_backup.mkdir(parents=True)
        (gastown_backup / "config.json").write_text('{"restored": true}')

        # Create current gasclaw directory
        gasclaw_dir = tmp_path / ".gasclaw"
        gasclaw_dir.mkdir()
        marker = gasclaw_dir / ".migrated_from_gastown"
        marker.write_text("{}")

        with patch("gasclaw.migration.Path.home", return_value=tmp_path):
            result = rollback(backup_path)

        assert result.success is True

        gt_root = tmp_path / ".gastown"
        assert (gt_root / "config.json").exists()
        assert json.loads((gt_root / "config.json").read_text()) == {"restored": True}

    def test_rollback_fails_when_backup_missing(self, tmp_path):
        """Rollback fails when backup not found."""
        backup_path = tmp_path / "nonexistent"

        result = rollback(backup_path)
        assert result.success is False
        assert "Backup not found" in result.message


class TestMigrationResult:
    """Tests for MigrationResult dataclass."""

    def test_summary_success(self):
        """Summary shows success status."""
        result = MigrationResult(
            success=True,
            message="Migration completed!",
            migrated_items=["Item 1", "Item 2"],
        )
        summary = result.summary()
        assert "SUCCESS" in summary
        assert "Migration completed!" in summary
        assert "Item 1" in summary
        assert "Item 2" in summary

    def test_summary_failure(self):
        """Summary shows failure status."""
        result = MigrationResult(
            success=False,
            message="Migration failed!",
        )
        summary = result.summary()
        assert "FAILED" in summary
        assert "Migration failed!" in summary

    def test_summary_with_warnings(self):
        """Summary includes warnings."""
        result = MigrationResult(
            success=True,
            message="Migration completed with warnings",
            warnings=["Warning 1", "Warning 2"],
        )
        summary = result.summary()
        assert "Warning 1" in summary
        assert "Warning 2" in summary

    def test_summary_with_backup(self):
        """Summary includes backup path."""
        backup_path = Path("/path/to/backup")
        result = MigrationResult(
            success=True,
            message="Migration completed!",
            backup_path=backup_path,
        )
        summary = result.summary()
        assert "/path/to/backup" in summary
