"""Config load/save using only the standard library (TOML via ``tomllib`` / JSON).

* ``load_config`` accepts ``.toml`` or ``.json``.
* ``save_config`` writes ``.json`` directly, and ``.toml`` via a small
  dependency-free serializer that covers the nested dicts / scalar lists our
  training configs use.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict


def _default(obj: Any) -> Any:
    if hasattr(obj, "to_dict"):
        return obj.to_dict()
    if hasattr(obj, "__dict__"):
        return {k: v for k, v in vars(obj).items() if not k.startswith("_")}
    return str(obj)


def load_config(path: str | os.PathLike) -> Dict:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(path)
    if p.suffix == ".toml":
        import tomllib
        with open(p, "rb") as f:
            return tomllib.load(f)
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def save_config(config: Dict, path: str | os.PathLike) -> None:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    if p.suffix == ".toml":
        text = _dump_toml(config)
        with open(p, "w", encoding="utf-8") as f:
            f.write(text)
    else:
        with open(p, "w", encoding="utf-8") as f:
            json.dump(config, f, indent=2, default=_default)


# -- minimal TOML serializer ------------------------------------------------
def _toml_value(v: Any) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + v.replace("\\", "\\\\").replace('"', '\\"') + '"'
    if v is None:
        return "null"
    if isinstance(v, dict):
        return "{}"
    if isinstance(v, (list, tuple)):
        return "[" + ", ".join(_toml_value(x) for x in v) + "]"
    return '"' + str(v) + '"'


def _dump_toml(data: Dict, prefix: str = "") -> str:
    lines: list[str] = []
    scalars = []
    tables = []
    arrays_of_tables = []
    for k, v in data.items():
        if isinstance(v, dict) and v:
            tables.append((k, v))
        elif isinstance(v, list) and v and all(isinstance(x, dict) for x in v):
            arrays_of_tables.append((k, v))
        else:
            scalars.append((k, v))
    for k, v in scalars:
        lines.append(f"{k} = {_toml_value(v)}")
    for k, v in tables:
        full = f"{prefix}{k}"
        lines.append("")
        lines.append(f"[{full}]")
        lines.append(_dump_toml(v, full + "."))
    for k, items in arrays_of_tables:
        for item in items:
            lines.append("")
            lines.append(f"[[{prefix}{k}]]")
            lines.append(_dump_toml(item, f"{prefix}{k}."))
    return "\n".join(lines) + "\n"
