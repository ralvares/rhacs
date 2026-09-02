# OpenClaw v1 dependency view

This folder is the clean developer-workstation view for the scan-only v1 candidate. `package.json` pins the real affected `openclaw@2026.2.13` package used by the v1 image. That release falls inside the affected range for the Critical GHSA-j7p2-qcwm-94v4 supply-chain redirection issue, fixed in `2026.3.22`. `requirements.txt` remains a separate Python dependency-analysis example; it is not part of the OpenClaw image.

The v1 image is built and scanned but never started or deployed.
