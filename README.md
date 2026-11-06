# EMISSARY iPhone Node (v1.0.0)

Turns an iPhone 13 into a subordinate EMISSARY research Worker that runs a small language model
**on the phone itself** (llama.cpp, pinned in `LLAMA_CPP_COMMIT`; default model Liquid AI LFM2-350M Q4_K_M, ~229 MB).

- Uses EMISSARY's existing Worker protocol (register → owner approves on the MSI → heartbeat → poll →
  start → complete). No new Supervisor routes, no new authority. The MSI stays in charge.
- Runs only `LOCAL_MODEL_RESEARCH` pieces assigned to this phone. No shell, no file access, no other tools.
- Works only while the app is open on screen (iOS rule). Keep it plugged in.
- Built free on GitHub's Mac machines; installed free with AltStore from Windows (7-day re-sign).

Status: written and reviewed, NOT yet compiled. The first GitHub build is the first compile check.
Nothing about speed or quality is claimed until it runs on the actual phone.

See `docs/SETUP_GUIDE.md`.
