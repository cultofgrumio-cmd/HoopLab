from ultralytics import YOLO
import cv2
import fastapi

app = fastapi.FastAPI()
model = YOLO("")

@app.post("/analyze")
async def analyze_video(file: fastapi.UploadFile):
    video_path = f"temp_{file.filename}"
    with open(video_path, "wb") as f:
        f.write(await file.read())

    cap = cv2.VideoCapture(video_path)
    if not cap.isOpened():
        return {"error": "Could not open video file"}

    results = []
    while True:
        ret, frame = cap.read()
        if not ret:
            break

        result = model(frame)
        results.append(result)

    cap.release()
    return {"results": [r.pandas().xyxy[0].to_dict(orient="records") for r in results]}