from __future__ import annotations

import uvicorn

from service.app import app
from service.config import load_config


def main() -> None:
    config = load_config("service/config.json")
    uvicorn.run(app, host=config.host, port=config.port)


if __name__ == "__main__":
    main()
