import io
import logging
import os
import tempfile
import hashlib
from functools import lru_cache
from typing import List
from PIL import Image

from fastapi import FastAPI, File, UploadFile, Request
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import cv2
import numpy as np
import torch
from transformers import AutoProcessor, LlavaForConditionalGeneration
import uvicorn
import uvloop

app = FastAPI()

# Add CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Load LLaVA model and processor
logger.info("Loading LLaVA model...")
try:
    processor = AutoProcessor.from_pretrained("llava-hf/llava-1.5-13b-hf")
    model = LlavaForConditionalGeneration.from_pretrained("llava-hf/llava-1.5-13b-hf", torch_dtype=torch.float16)
    device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
    model.to(device)
    model.eval()
    logger.info(f"LLaVA model loaded successfully on {device}")
except Exception as e:
    logger.error(f"Failed to load LLaVA model: {str(e)}")
    raise Exception("Model loading failed")

def preprocess_image(image: Image.Image) -> Image.Image:
    """Resize image to LLaVA's expected input size."""
    image = image.resize((336, 336), Image.Resampling.LANCZOS)  # LLaVA uses 336x336
    return image

# Image hash function for caching
def hash_image(image_data: bytes) -> str:
    return hashlib.md5(image_data).hexdigest()

# Cache recent image descriptions
@lru_cache(maxsize=100)
def get_cached_description(image_hash: str) -> str:
    # This will be filled by the LRU cache
    return None

def process_image_data(image_data: bytes) -> str:
    """Process an image frame with LLaVA for a detailed description."""
    try:
        if not image_data:
            raise ValueError("Image data is empty")

        # Check cache based on image hash
        image_hash = hash_image(image_data)
        cached_result = get_cached_description(image_hash)
        if cached_result:
            logger.info("Using cached description")
            return cached_result

        logger.info(f"Processing image, size: {len(image_data)} bytes")
        image = Image.open(io.BytesIO(image_data)).convert("RGB")
        image = preprocess_image(image)

        # Improved prompt for more concise, relevant descriptions
        prompt = """
        Describe what you see in this image in a single, concise paragraph. 
        Focus on the most important objects, people, actions, and environment.
        Be specific and accurate rather than general. Limit to 2-3 sentences.
        """
        
        conversation = [{"role": "user", "content": [{"type": "text", "text": prompt}, {"type": "image"}]}]
        inputs = processor.apply_chat_template(conversation, add_generation_prompt=True)
        inputs = processor(text=inputs, images=image, return_tensors="pt").to(device, torch.float16)

        # Generate description with optimized parameters
        with torch.no_grad():
            output_ids = model.generate(
                **inputs,
                max_new_tokens=150,  # Reduced for shorter descriptions
                do_sample=False,
                temperature=0.7
            )
        description = processor.decode(output_ids[0], skip_special_tokens=True)
        description = description.replace(prompt, "").strip()
        logger.info(f"Generated description: {description}")
        
        # Store in cache
        get_cached_description.cache_parameters()[image_hash] = description
        
        return description

    except Exception as e:
        logger.error(f"Error processing image: {str(e)}")
        return f"Error: Failed to process image - {str(e)}"

def extract_frames_from_video(video_data: bytes, frame_interval: int = 30) -> List[bytes]:
    """Extract frames from a video for processing."""
    try:
        with tempfile.NamedTemporaryFile(delete=False, suffix=".mov") as temp_file:
            temp_file.write(video_data)
            temp_file_path = temp_file.name

        video = cv2.VideoCapture(temp_file_path)
        if not video.isOpened():
            raise Exception("Failed to open video file")

        frames = []
        frame_count = 0
        while True:
            ret, frame = video.read()
            if not ret:
                break
            if frame_count % frame_interval == 0:
                logger.info(f"Extracting frame {frame_count}")
                frame_rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                _, buffer = cv2.imencode(".jpg", frame_rgb)
                frames.append(buffer.tobytes())
            frame_count += 1

        video.release()
        logger.info(f"Extracted {len(frames)} frames")
        return frames

    except Exception as e:
        logger.error(f"Error extracting frames: {str(e)}")
        raise Exception(f"Failed to extract frames: {str(e)}")
    finally:
        if 'temp_file_path' in locals():
            try:
                os.unlink(temp_file_path)
                logger.info(f"Deleted temp file: {temp_file_path}")
            except Exception as e:
                logger.error(f"Failed to delete temp file: {str(e)}")

@app.get("/")
async def root():
    return {"message": "Welcome to LiveFeedAI Server"}

@app.post("/process-image")
async def process_image(file: UploadFile = File(...)):
    """Endpoint for processing live feed images."""
    try:
        logger.info(f"Received file: {file.filename}, type: {file.content_type}")
        image_data = await file.read()
        if not image_data:
            return JSONResponse(status_code=400, content={"error": "Empty file received"})

        supported_formats = ["image/jpeg", "image/png"]
        if file.content_type not in supported_formats:
            return JSONResponse(status_code=400, content={"error": f"Unsupported file type: {file.content_type}"})

        description = process_image_data(image_data)
        return {"recognized_text": description}

    except Exception as e:
        logger.error(f"Error in process-image: {str(e)}")
        return JSONResponse(status_code=500, content={"error": str(e)})

@app.post("/process-video")
async def process_video(file: UploadFile = File(...)):
    """Endpoint for video processing (optional)."""
    try:
        video_data = await file.read()
        if not video_data:
            return JSONResponse(status_code=400, content={"error": "Empty file received"})

        is_video = file.content_type.startswith("video/") or file.filename.lower().endswith(('.mp4', '.mov', '.avi'))
        if not is_video:
            return JSONResponse(status_code=400, content={"error": f"Invalid file type: {file.content_type}"})

        frames = extract_frames_from_video(video_data)
        if not frames:
            return JSONResponse(status_code=400, content={"error": "No frames extracted"})

        descriptions = []
        for i, frame_data in enumerate(frames):
            description = process_image_data(frame_data)
            descriptions.append({
                "frame": i,
                "timestamp": i * 1.0,  # Simplified timestamp
                "description": description
            })
        return {"descriptions": descriptions}

    except Exception as e:
        logger.error(f"Error in process-video: {str(e)}")
        return JSONResponse(status_code=500, content={"error": str(e)})

@app.post("/speech")
async def process_speech(query: dict):
    """Basic speech endpoint."""
    try:
        user_query = query.get("query", "")
        if not user_query:
            return JSONResponse(status_code=400, content={"error": "No query provided"})
        response = f"Received your query: {user_query}"
        return {"response": response}
    except Exception as e:
        logger.error(f"Error in speech: {str(e)}")
        return JSONResponse(status_code=500, content={"error": str(e)})

if __name__ == "__main__":
    config = uvicorn.Config(
        app=app,
        host="0.0.0.0",
        port=8000,
        workers=2,  # Adjust based on your hardware
        loop="uvloop",
        http="httptools",
        limit_concurrency=20,
        backlog=128
    )
    server = uvicorn.Server(config)
    server.run()
