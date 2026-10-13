#!/bin/bash
cd "$(dirname "$0")"
export PYTHONPATH=src
python3 -m stt.server
