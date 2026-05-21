#!/usr/bin/env python3
"""Simple migration stub used by CI/deploy pipeline.

This is intentionally minimal: real projects should integrate Alembic
or another migrations framework.
"""
import os
import logging

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")


def main():
    logging.info("Running DB migrations (stub).")
    # Placeholder: call real migrations here.
    # If ORACLE_* are set, you may run real migration steps.
    logging.info("No migrations to apply.")


if __name__ == "__main__":
    main()
