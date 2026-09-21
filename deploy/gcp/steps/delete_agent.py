#!/usr/bin/env python3
"""Deletes an Agent Runtime deployment. There is no gcloud surface for it."""
import sys

resource = sys.argv[1]
try:
    import vertexai
    from vertexai import agent_engines
except ImportError:
    sys.exit("  vertexai SDK not installed; delete the agent from the Cloud Console")

parts = resource.split("/")
project, location = parts[1], parts[3]
vertexai.init(project=project, location=location)
try:
    agent_engines.get(resource).delete(force=True)
    print(f"  deleted {resource}")
except Exception as exc:  # noqa: BLE001 - best effort during teardown
    print(f"  could not delete {resource}: {exc}")
