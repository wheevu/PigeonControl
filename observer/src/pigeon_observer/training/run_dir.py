"""Immutable run directories.

A run dir refuses to overwrite existing output. Work happens in a staging
directory and is only renamed into place on successful setup/training, so a
crashed or aborted run never leaves a half-written output behind.
"""
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path
from typing import Any, Dict


class RunDir:
    def __init__(self, output_dir: str | os.PathLike) -> None:
        self.output = Path(output_dir)
        if self.output.exists():
            raise FileExistsError(
                f"Refusing to overwrite existing output dir: {self.output}"
            )
        self.staging = self.output.with_name(f"{self.output.name}.staging-{os.getpid()}")
        if self.staging.exists():
            shutil.rmtree(self.staging)
        self.staging.mkdir(parents=True)

    # -- writers (all land in staging) -------------------------------------
    def write_json(self, name: str, obj: Any) -> Path:
        path = self.staging / name
        with open(path, "w", encoding="utf-8") as f:
            json.dump(obj, f, indent=2, default=str)
        return path

    def write_bytes(self, name: str, data: bytes) -> Path:
        path = self.staging / name
        with open(path, "wb") as f:
            f.write(data)
        return path

    def ensure_dir(self, name: str) -> Path:
        d = self.staging / name
        d.mkdir(parents=True, exist_ok=True)
        return d

    # -- lifecycle ---------------------------------------------------------
    def commit(self) -> None:
        if self.output.exists():
            raise FileExistsError(f"Output appeared concurrently: {self.output}")
        os.rename(self.staging, self.output)

    def abort(self) -> None:
        if self.staging.exists():
            shutil.rmtree(self.staging)

    def __enter__(self) -> "RunDir":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        if exc_type is None:
            try:
                self.commit()
            except Exception:
                self.abort()
                raise
        else:
            self.abort()
        return False


def prepare_run_dir(output_dir: str | os.PathLike) -> RunDir:
    """Create a staging run dir, refusing existing output. Raises on conflict."""
    return RunDir(output_dir)
