# OpenClaw v2 release candidate

This is the maintained candidate prepared before the presentation.

- Opening runtime: `openclaw@2026.2.13` from `versions/v1`
- Approved candidate: `openclaw@2026.8.2` from this directory

The setup stages two PipelineRuns. The v1 run is rejected. The v2 run builds,
scans, signs, and passes the RHACS gates, but deliberately skips promotion.
During the presentation, `make promote-v2` submits that already-approved,
immutable v2 digest to OpenShift and RHACS admission control.
