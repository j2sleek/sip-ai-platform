# Quick Start

## Starting Services

### Python Services
Each Python service needs PYTHONPATH=src:
```bash
cd services/stt && PYTHONPATH=src python3 -m stt.server
cd services/llm && PYTHONPATH=src python3 -m llm.server
cd services/tts && PYTHONPATH=src python3 -m tts.server
cd services/vad && PYTHONPATH=src python3 -m vad.server
```

Or use the run.sh scripts:
```bash
for s in stt llm tts vad; do cd services/$s && ./run.sh & done
```

### Node Services
```bash
# HOST/PORT are the canonical listener variables; CALL_BACKEND=simulated|ari
HOST=127.0.0.1 PORT=4001 CALL_BACKEND=simulated node apps/control_api/dist/server.js
```

### All at once
```bash
bash services/start_all.sh
```
