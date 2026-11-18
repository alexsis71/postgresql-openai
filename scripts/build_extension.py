"""Build the control and versioned SQL files for CREATE EXTENSION."""

import argparse
import re
import shutil
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
EXTENSION = "postgresql_openai"


def build(output_dir: Path) -> None:
    control = ROOT / "extension" / f"{EXTENSION}.control"
    version, = re.findall(
        r"^default_version = '([^']+)'$", control.read_text(encoding="ascii"), re.M
    )
    installer = (ROOT / "sql" / "install_catalog.sql").read_text(encoding="utf-8")
    _, shared = installer.split("-- BEGIN SHARED INSTALL SQL\n")
    shared, _ = shared.split("-- END SHARED INSTALL SQL\n")
    before_migration, legacy = shared.split("-- BEGIN LEGACY MIGRATION\n")
    _, after_migration = legacy.split("-- END LEGACY MIGRATION\n")
    shared = (before_migration + after_migration).replace("ai_http.", "@extschema:http@.")
    config_dump = (ROOT / "extension" / "config_dump.sql").read_text(encoding="utf-8")

    output_dir.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(control, output_dir / control.name)
    (output_dir / f"{EXTENSION}--{version}.sql").write_text(
        f'\\echo Use "CREATE EXTENSION {EXTENSION}" to load this file. \\quit\n'
        "SET LOCAL search_path = pg_catalog, pg_temp;\n\n"
        f"{shared}\n{config_dump}",
        encoding="utf-8",
        newline="\n",
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output_dir", type=Path)
    build(parser.parse_args().output_dir)
