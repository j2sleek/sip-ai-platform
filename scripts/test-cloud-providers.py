#!/usr/bin/env python3
"""Quick sanity check for cloud providers (stdlib only)."""
import json
import os
import sys
import urllib.request
import urllib.error
import base64
import io


def test_llm():
    provider = os.environ.get("LLM_PROVIDER", "mock").lower()
    if provider == "mock":
        print("LLM: mock (skip cloud test)")
        return True
    # For now, just check env vars exist
    if provider == "openrouter" and not os.environ.get("OPENROUTER_API_KEY"):
        print("LLM openrouter: missing OPENROUTER_API_KEY")
        return False
    if provider == "groq" and not os.environ.get("GROQ_API_KEY"):
        print("LLM groq: missing GROQ_API_KEY")
        return False
    if provider in ("gemini", "google") and not (os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY")):
        print("LLM gemini: missing GEMINI_API_KEY/GOOGLE_API_KEY")
        return False
    print(f"LLM {provider}: env looks ok")
    return True


def main():
    print("Testing cloud provider config...")
    ok = test_llm()
    if ok:
        print("Done.")
        sys.exit(0)
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
