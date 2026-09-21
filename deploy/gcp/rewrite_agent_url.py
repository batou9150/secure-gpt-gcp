#!/usr/bin/env python3
"""Points the gateway config's A2A agent at the Cloud Run auth sidecar.

Locally the agent is a neighbouring container; on Google Cloud it lives on
Agent Runtime behind the sidecar on localhost:8081.
"""
import re
import sys

src = open(sys.argv[1]).read()
out, n = re.subn(r'url:\s*"http://adk-agent:8080[^"]*"', 'url: "http://localhost:8081"', src)
if n == 0 and "agents:" in src:
    sys.exit("rewrite_agent_url: found an agents: block but no adk-agent url to rewrite")
sys.stdout.write(out)
