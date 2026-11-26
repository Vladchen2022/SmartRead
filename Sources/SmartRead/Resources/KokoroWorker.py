import json
import os
import sys
import wave
from io import BytesIO
from pathlib import Path

import numpy as np
import onnxruntime as ort
from kokoro_onnx import Kokoro


def send(data):
    output = sys.stdout.buffer
    output.write(f"{len(data)}\n".encode())
    output.write(data)
    output.flush()


def boost_speech(samples):
    # Double the level, then gently limit only the loudest peaks.
    gained = samples * 2.0
    amplitude = np.abs(gained)
    knee = 0.80
    headroom = 0.18
    peaks = amplitude > knee
    limited = knee + headroom * np.tanh((amplitude[peaks] - knee) / headroom)
    gained[peaks] = np.copysign(limited, gained[peaks])
    return gained


def run():
    root = Path(sys.argv[1])
    options = ort.SessionOptions()
    options.intra_op_num_threads = min(4, os.cpu_count() or 1)
    options.add_session_config_entry("session.intra_op.allow_spinning", "0")
    session = ort.InferenceSession(
        str(root / "kokoro-v1.0.int8.onnx"), options, providers=["CPUExecutionProvider"]
    )
    model = Kokoro.from_session(session, str(root / "voices-v1.0.bin"))
    send(b"ready")

    for line in sys.stdin.buffer:
        try:
            request = json.loads(line)
            voice = request["voice"]
            lang = "en-gb" if voice.startswith("b") else "en-us"
            samples, sample_rate = model.create(request["text"], voice=voice, speed=request["speed"], lang=lang)
            data = BytesIO()
            with wave.open(data, "wb") as output:
                output.setparams((1, 2, sample_rate, 0, "NONE", "not compressed"))
                output.writeframes((boost_speech(samples) * 32767).astype("<i2").tobytes())
            send(data.getvalue())
        except Exception as error:
            send(f"error:{error}".encode())


if __name__ == "__main__":
    try:
        run()
    except Exception as error:
        send(f"error:{error}".encode())
