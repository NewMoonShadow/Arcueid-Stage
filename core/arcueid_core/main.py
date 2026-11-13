from __future__ import annotations

import argparse
import asyncio
import os

import uvicorn

from arcueid_core.config import load_settings
from arcueid_core.service import create_app


def main() -> None:
    parser = argparse.ArgumentParser(description="Arcueid Stage local core")
    parser.add_argument("--parent-pid", type=int, default=0)
    parser.add_argument("--data-dir", default="")
    args = parser.parse_args()
    if args.parent_pid:
        os.environ["ARCUEID_PARENT_PID"] = str(args.parent_pid)
    if args.data_dir:
        os.environ["ARCUEID_STAGE_DATA_DIR"] = args.data_dir
    settings = load_settings()
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port)


if __name__ == "__main__":
    main()
