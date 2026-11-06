#!/data/data/com.termux/files/usr/bin/bash
# EMISSARY Android Worker - one-time setup inside Termux (Samsung or any Android phone).
# Needs: Termux (from F-Droid or GitHub, NOT the old Play Store one) and the Tailscale app switched on.
set -e
cd "$(dirname "$0")"
echo "== 1/4 Installing Python and Ollama (local AI runtime) =="
pkg update -y && pkg install -y python ollama termux-api 2>/dev/null || pkg install -y python ollama
RAM_GB=$(awk '/MemTotal/{printf "%d", $2/1048576}' /proc/meminfo)
if [ "$RAM_GB" -ge 5 ]; then MODEL="qwen2.5:1.5b"; else MODEL="qwen2.5:0.5b"; fi
echo "This phone has about ${RAM_GB} GB RAM -> research model $MODEL"
mkdir -p ~/EMISSARY_Worker
cp emissary_worker_client.py android_enroll.py ~/EMISSARY_Worker/
cat > ~/EMISSARY_Worker/start.sh <<EOS
#!/data/data/com.termux/files/usr/bin/bash
# Starts the local model server and the EMISSARY Worker. Keeps the phone awake while it runs.
termux-wake-lock 2>/dev/null || true
export OLLAMA_HOST=127.0.0.1:11434 OLLAMA_KEEP_ALIVE=5m OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1
pgrep -x ollama >/dev/null || (nohup ollama serve > ~/EMISSARY_Worker/ollama.log 2>&1 &)
sleep 4
export EMISSARY_ENABLE_LOCAL_MODEL_RESEARCH=1 EMISSARY_LOCAL_MODEL=$MODEL EMISSARY_OLLAMA_URL=http://127.0.0.1:11434
cd ~/EMISSARY_Worker && exec python emissary_worker_client.py
EOS
chmod +x ~/EMISSARY_Worker/start.sh
echo "== 2/4 Starting Ollama and downloading $MODEL (one time) =="
(OLLAMA_HOST=127.0.0.1:11434 nohup ollama serve > ~/EMISSARY_Worker/ollama.log 2>&1 &) ; sleep 5
ollama pull "$MODEL"
echo "== 3/4 Registering with EMISSARY (Tailscale must be ON) =="
python ~/EMISSARY_Worker/android_enroll.py
echo "== 4/4 Done =="
echo "On the MSI: python authorize_research_worker.py  (approve samsung-node)"
echo "Then here, any time:  ~/EMISSARY_Worker/start.sh   (keep Termux open, phone plugged in)"
