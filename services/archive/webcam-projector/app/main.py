import argparse

from .config import load_settings
from .logging_utils import configure_logging
from .service import WebcamProjectorService


def main() -> None:
    parser = argparse.ArgumentParser(description="Webcam projector service")
    parser.add_argument("--config", default="config/dev.yaml", help="Path to YAML config")
    args = parser.parse_args()

    settings = load_settings(args.config)
    configure_logging(settings.runtime.log_level)

    service = WebcamProjectorService(settings)
    service.run()


if __name__ == "__main__":
    main()
