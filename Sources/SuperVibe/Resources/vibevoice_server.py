"""
Persistent VibeVoice server.
Reads WAV file paths from stdin (one per line),
transcribes, and writes JSON result to stdout.
Model is loaded once at startup.
"""
import sys
import json
import tempfile
import os
import multiprocessing.resource_tracker

# Suppress semaphore leak warnings from mlx_audio internals on shutdown
_original_warn = multiprocessing.resource_tracker.warnings.warn
def _filtered_warn(msg, *args, **kwargs):
    if "leaked semaphore" in str(msg):
        return
    _original_warn(msg, *args, **kwargs)
multiprocessing.resource_tracker.warnings.warn = _filtered_warn

def main():
    model_name = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/VibeVoice-ASR-4bit"

    sys.stderr.write(f"[vibevoice] Loading model {model_name}...\n")
    sys.stderr.flush()

    from mlx_audio.stt.generate import generate_transcription, load_model

    model = load_model(model_name)

    sys.stderr.write("[vibevoice] Model loaded. Ready.\n")
    sys.stderr.flush()

    # Signal ready
    sys.stdout.write("READY\n")
    sys.stdout.flush()

    for line in sys.stdin:
        audio_path = line.strip()
        if not audio_path:
            continue

        try:
            result = generate_transcription(
                model=model,
                audio=audio_path,
                prefill_step_size=4096,
                output_path=os.path.join(tempfile.gettempdir(), ".supervibe_discard"),
            )
            # result is an STTOutput object with .segments list
            if hasattr(result, 'segments') and result.segments:
                text = "".join(seg.get("text", "") for seg in result.segments)
            elif hasattr(result, 'text'):
                text = result.text
            else:
                text = str(result)

            sys.stdout.write(json.dumps({"ok": True, "text": text.strip()}) + "\n")
        except Exception as e:
            sys.stdout.write(json.dumps({"ok": False, "error": str(e)}) + "\n")

        sys.stdout.flush()

if __name__ == "__main__":
    main()
