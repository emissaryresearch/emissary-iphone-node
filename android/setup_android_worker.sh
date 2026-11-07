#!/data/data/com.termux/files/usr/bin/bash
# EMISSARY Android Worker - one-time setup inside Termux (Samsung or any Android phone).
# Needs: Termux (from F-Droid or GitHub, NOT the old Play Store one) and the Tailscale app switched on.
# Optional: EMISSARY_MODEL=qwen2.5:0.5b (force a model), EMISSARY_NODE_NAME=samsung-node.
set -e
cd "$(dirname "$0")"
export DEBIAN_FRONTEND=noninteractive
APT_OPTS='-y -o Dpkg::Options::=--force-confnew -o Dpkg::Options::=--force-confdef'

echo "== 1/5 Installing Python and Ollama (local AI runtime) - a few minutes"
apt-get update -y >/dev/null 2>&1 || pkg update -y
apt-get $APT_OPTS upgrade >/dev/null 2>&1 || true
apt-get $APT_OPTS install python ollama termux-api 2>/dev/null || apt-get $APT_OPTS install python ollama

mkdir -p ~/EMISSARY_Worker
cp emissary_worker_client.py android_enroll.py ~/EMISSARY_Worker/

echo "== 2/5 Starting the local AI runtime"
termux-wake-lock 2>/dev/null || true
export OLLAMA_HOST=127.0.0.1:11434
pgrep -x ollama >/dev/null || (nohup ollama serve > ~/EMISSARY_Worker/ollama.log 2>&1 &)
for i in $(seq 1 20); do curl -s http://127.0.0.1:11434/api/tags >/dev/null 2>&1 && break; sleep 2; done

# Pick the smartest model this phone can actually run: try qwen2.5:1.5b on phones with about
# 4 GB or more, test it, and fall back to qwen2.5:0.5b if the phone runs out of memory.
RAM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
try_model() {
  echo "   downloading $1 (one time)..."
  ollama pull "$1" || return 1
  echo "   test run of $1 (up to 3 minutes)..."
  timeout 180 ollama run "$1" "Reply with the single word: ready" 2>/dev/null | grep -qi "ready"
}
echo "== 3/5 Choosing the AI model (this phone: about $((RAM_MB / 1024)) GB of memory)"
if [ -n "$EMISSARY_MODEL" ]; then
  MODEL="$EMISSARY_MODEL"; ollama pull "$MODEL"
elif [ "$RAM_MB" -ge 3400 ] && try_model qwen2.5:1.5b; then
  MODEL="qwen2.5:1.5b"
else
  echo "   using the smaller model so it fits this phone"
  MODEL="qwen2.5:0.5b"; try_model "$MODEL" || echo "   [!] test run did not answer - the Worker will retry on its own"
fi
echo "   model: $MODEL"

cat > ~/EMISSARY_Worker/start.sh <<EOS
#!/data/data/com.termux/files/usr/bin/bash
# Starts the local model server and the EMISSARY Worker. Keep Termux open and the phone plugged in.
termux-wake-lock 2>/dev/null || true
export OLLAMA_HOST=127.0.0.1:11434 OLLAMA_KEEP_ALIVE=10m OLLAMA_MAX_LOADED_MODELS=1 OLLAMA_NUM_PARALLEL=1
pgrep -x ollama >/dev/null || (nohup ollama serve > ~/EMISSARY_Worker/ollama.log 2>&1 &)
sleep 4
export EMISSARY_ENABLE_LOCAL_MODEL_RESEARCH=1 EMISSARY_LOCAL_MODEL=$MODEL EMISSARY_OLLAMA_URL=http://127.0.0.1:11434
export EMISSARY_LOCAL_MODEL_NUM_CTX=8192
cd ~/EMISSARY_Worker && exec python emissary_worker_client.py
EOS
chmod +x ~/EMISSARY_Worker/start.sh

echo "== 4/5 Registering with EMISSARY (Tailscale must be ON)"
python ~/EMISSARY_Worker/android_enroll.py

echo "== 5/5 Done."
echo ""
echo "   On the MSI approve it:   python authorize_research_worker.py   (y for this phone, N for Claude Code)"
echo "   Then here, any time:     ~/EMISSARY_Worker/start.sh   (keep Termux open, phone plugged in)"
