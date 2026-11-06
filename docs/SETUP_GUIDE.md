# Setup guide - EMISSARY iPhone Node (free)

You need: a free GitHub account, your free Apple ID, the MSI, the iPhone 13 with Tailscale.
Never give your GitHub or Apple passwords to Claude or ChatGPT - type them only into GitHub / AltStore.

## 1. Put the project on GitHub (once)
1. github.com -> New repository -> name `emissary-iphone-node` -> **Public** (public = free Mac build
   minutes; it contains no secrets) -> Create.
2. On the MSI, in PowerShell:
   cd $env:USERPROFILE\Desktop\emissary-iphone-node
   git init; git add -A; git commit -m "EMISSARY iPhone Node v1.0.0"
   git branch -M main
   git remote add origin https://github.com/<YOUR-USERNAME>/emissary-iphone-node.git
   git push -u origin main
   (A GitHub sign-in window opens the first time - sign in there.)

## 2. Build the app (about 25 minutes the first time, then ~5)
GitHub -> your repo -> **Actions** -> "Build iPhone app" -> it starts by itself after the push
(or click **Run workflow**). When it shows a green tick, open it and download **EmissaryNode-ipa**.
Unzip it: you get `EmissaryNode.ipa`.
If it shows a red X, copy the error lines to Claude - the first build is the first compile.

## 3. Install AltStore on the MSI (once)
1. Install **iTunes** and **iCloud** from apple.com (NOT the Microsoft Store versions).
2. Download **AltServer for Windows** from altstore.io and install it. Run it as administrator.
3. iPhone: Settings -> Privacy & Security -> **Developer Mode** -> On (it restarts).
4. Plug the iPhone into the MSI by USB, tap "Trust". In iTunes, tick "Sync with this iPhone over Wi-Fi".
5. Click the AltServer icon in the Windows tray -> Install AltStore -> your iPhone -> sign in with
   your Apple ID (inside AltServer only).
6. iPhone: Settings -> General -> VPN & Device Management -> trust your Apple ID.

## 4. Install EMISSARY Node
AltServer tray icon -> **Sideload .ipa** -> your iPhone -> choose `EmissaryNode.ipa`.
The "EMISSARY Node" app appears on the iPhone.

## 5. First run on the iPhone
1. Open EMISSARY Node -> **Download model** (229 MB, on Wi-Fi).
2. Turn on **Airplane mode** -> tap **Test on this phone** -> the answer and speed appear under
   Activity. This proves the model runs on the phone itself. Turn Airplane mode off.
3. Turn **Tailscale** on -> **Register with the Supervisor**.
4. On the MSI: `python authorize_research_worker.py` and approve the new iPhone node for research
   (same as the other Workers). It then appears on Live Operations.
5. Back on the iPhone: **Start worker**. Leave the app open, plugged in.

## 6. Every 7 days
Free Apple signing expires after 7 days. With AltServer running on the MSI and the iPhone on the same
Wi-Fi, open AltStore on the iPhone -> My Apps -> **Refresh All**. (If it expires, just sideload again.)

## Limits (honest)
- Small model (350M): quick summaries and short answers; long research pieces are trimmed to fit
  (each result says `prompt_truncated_to_fit_device`). Treat its findings as leads.
- Works only while open on screen. The Supervisor marks it offline when heartbeats stop.
- Speed/heat/battery are unknown until measured on the phone (use "Test on this phone").
