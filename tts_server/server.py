"""
TTS Server — FastAPI wrapper for text-to-speech synthesis.

This microservice provides a simple HTTP API for converting Chinese text to speech.
It's designed to wrap Qwen3-TTS or any other TTS engine. For now, it uses a simple
approach: it tries to import and use a local TTS model, falling back to edge-tts
(Microsoft's free TTS service) if no local model is available.

Endpoints:
  GET  /health  — Health check
  POST /tts     — Synthesize speech from text, returns base64-encoded WAV audio
"""

import base64
import io
import logging
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

logger = logging.getLogger("tts_server")

app = FastAPI(title="TTS Server", version="1.0.0")


class TTSRequest(BaseModel):
    """Request body for the /tts endpoint."""
    text: str


class TTSResponse(BaseModel):
    """Response body from the /tts endpoint."""
    audio_base64: str


# Try to import edge-tts for a lightweight, no-GPU-required TTS solution.
# edge-tts uses Microsoft's Edge browser TTS service (free, no API key needed).
try:
    import edge_tts
    import asyncio
    HAS_EDGE_TTS = True
    logger.info("edge-tts available — using Microsoft Edge TTS")
except ImportError:
    HAS_EDGE_TTS = False
    logger.warning("edge-tts not installed — TTS will return errors. Install with: pip install edge-tts")


async def synthesize_edge_tts(text: str) -> bytes:
    """Synthesize speech using edge-tts (Microsoft Edge's TTS service).

    Uses zh-CN-XiaoxiaoNeural voice which is a natural-sounding female
    Mandarin Chinese voice.
    """
    communicate = edge_tts.Communicate(text, voice="zh-CN-XiaoxiaoNeural")
    audio_buffer = io.BytesIO()
    async for chunk in communicate.stream():
        if chunk["type"] == "audio":
            audio_buffer.write(chunk["data"])
    return audio_buffer.getvalue()


@app.get("/health")
async def health():
    """Health check endpoint."""
    return {
        "status": "ok",
        "tts_engine": "edge-tts" if HAS_EDGE_TTS else "none",
    }


@app.post("/tts", response_model=TTSResponse)
async def tts(req: TTSRequest):
    """Synthesize speech from Chinese text.

    Returns base64-encoded audio (MP3 format from edge-tts).
    """
    if not req.text.strip():
        raise HTTPException(status_code=400, detail="Text cannot be empty")

    if not HAS_EDGE_TTS:
        raise HTTPException(
            status_code=503,
            detail="No TTS engine available. Install edge-tts: pip install edge-tts",
        )

    try:
        audio_bytes = await synthesize_edge_tts(req.text)
        audio_b64 = base64.b64encode(audio_bytes).decode("utf-8")
        return TTSResponse(audio_base64=audio_b64)
    except Exception as e:
        logger.exception("TTS synthesis failed")
        raise HTTPException(status_code=500, detail=f"TTS synthesis failed: {str(e)}")


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8766)
