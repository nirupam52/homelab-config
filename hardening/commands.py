"""Small, shell-free subprocess adapter used by hardening entry points."""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass
from typing import Sequence


class CommandError(RuntimeError):
    """A required host query or mutation failed."""


@dataclass(frozen=True)
class Result:
    returncode: int
    output: str


class Runner:
    """Run argv lists with deterministic locale and combined command output."""

    def __init__(self) -> None:
        self.env = os.environ.copy()
        self.env["LC_ALL"] = "C"

    def run(self, argv: Sequence[str]) -> Result:
        completed = subprocess.run(
            list(argv),
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            check=False,
        )
        return Result(completed.returncode, completed.stdout)

    def require(self, command: str) -> None:
        if shutil.which(command) is None:
            raise CommandError(f"required command not found: {command}")

    def check(self, argv: Sequence[str], description: str) -> str:
        result = self.run(argv)
        if result.returncode != 0:
            detail = result.output.strip()
            raise CommandError(f"{description}: {detail or 'command failed'}")
        return result.output
