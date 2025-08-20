from ultralytics import YOLO
import cv2
import fastapi
import numpy as np
from scipy.spatial.distance import cdist
import os

app = fastapi.FastAPI()
model = YOLO("best.pt")  # Load your trained basketball model

class BasketballTracker:
    def __init__(self, max_distance=100, max_frames_missing=10):
        self.tracks = {}
        self.next_track_id = 0
        self.max_distance = max_distance
        self.max_frames_missing = max_frames_missing

    def update(self, detections, frame_timestamp):
        """
        Update tracks with new detections
        detections: list of [x1, y1, x2, y2, confidence] for each basketball
        frame_timestamp: timestamp of the current frame
        """
        if len(detections) == 0:
            # No detections, mark all tracks as missing
            for track_id in list(self.tracks.keys()):
                self.tracks[track_id]['frames_missing'] += 1
                if self.tracks[track_id]['frames_missing'] > self.max_frames_missing:
                    del self.tracks[track_id]
            return []

        detection_centers = np.array([[
            (det[0] + det[2]) / 2,  # center x
            (det[1] + det[3]) / 2   # center y
        ] for det in detections])

        # Get current track centers
        track_centers = []
        track_ids = []
        for track_id, track in self.tracks.items():
            track_centers.append(track['center'])
            track_ids.append(track_id)

        matched_tracks = []

        if len(track_centers) > 0:
            # Calculate distances between detections and existing tracks
            distances = cdist(detection_centers, np.array(track_centers))

            # Hungarian algorithm alternative: greedy matching
            used_detections = set()
            used_tracks = set()

            for _ in range(min(len(detections), len(track_ids))):
                min_distance = float('inf')
                best_det_idx = -1
                best_track_idx = -1

                for det_idx in range(len(detections)):
                    if det_idx in used_detections:
                        continue
                    for track_idx in range(len(track_ids)):
                        if track_idx in used_tracks:
                            continue
                        if distances[det_idx][track_idx] < min_distance and distances[det_idx][track_idx] < self.max_distance:
                            min_distance = distances[det_idx][track_idx]
                            best_det_idx = det_idx
                            best_track_idx = track_idx

                if best_det_idx != -1 and best_track_idx != -1:
                    used_detections.add(best_det_idx)
                    used_tracks.add(best_track_idx)

                    # Update existing track
                    track_id = track_ids[best_track_idx]
                    det = detections[best_det_idx]
                    self.tracks[track_id].update({
                        'center': detection_centers[best_det_idx].tolist(),
                        'bbox': det[:4],
                        'confidence': det[4],
                        'timestamp': frame_timestamp,
                        'frames_missing': 0
                    })
                    matched_tracks.append({
                        'track_id': track_id,
                        'bbox': det[:4],
                        'confidence': det[4],
                        'timestamp': frame_timestamp
                    })

            # Create new tracks for unmatched detections
            for det_idx in range(len(detections)):
                if det_idx not in used_detections:
                    det = detections[det_idx]
                    track_id = self.next_track_id
                    self.next_track_id += 1

                    self.tracks[track_id] = {
                        'center': detection_centers[det_idx].tolist(),
                        'bbox': det[:4],
                        'confidence': det[4],
                        'timestamp': frame_timestamp,
                        'frames_missing': 0
                    }
                    matched_tracks.append({
                        'track_id': track_id,
                        'bbox': det[:4],
                        'confidence': det[4],
                        'timestamp': frame_timestamp
                    })

            # Mark unmatched tracks as missing
            for track_idx in range(len(track_ids)):
                if track_idx not in used_tracks:
                    track_id = track_ids[track_idx]
                    self.tracks[track_id]['frames_missing'] += 1
                    if self.tracks[track_id]['frames_missing'] > self.max_frames_missing:
                        del self.tracks[track_id]

        else:
            # No existing tracks, create new ones for all detections
            for det_idx, det in enumerate(detections):
                track_id = self.next_track_id
                self.next_track_id += 1

                self.tracks[track_id] = {
                    'center': detection_centers[det_idx].tolist(),
                    'bbox': det[:4],
                    'confidence': det[4],
                    'timestamp': frame_timestamp,
                    'frames_missing': 0
                }
                matched_tracks.append({
                    'track_id': track_id,
                    'bbox': det[:4],
                    'confidence': det[4],
                    'timestamp': frame_timestamp
                })

        return matched_tracks

@app.post("/analyze")
async def analyze_video(file: fastapi.UploadFile):
    video_path = f"temp_{file.filename}"
    try:
        # Save uploaded file
        with open(video_path, "wb") as f:
            content = await file.read()
            f.write(content)

        # Verify file was saved correctly
        if not os.path.exists(video_path):
            return {"error": f"File {video_path} was not saved."}
        if os.path.getsize(video_path) == 0:
            return {"error": f"File {video_path} is empty."}

        # Open video
        cap = cv2.VideoCapture(video_path)
        if not cap.isOpened():
            return {"error": f"Could not open video file: {video_path}"}

        # Get video properties
        fps = cap.get(cv2.CAP_PROP_FPS)
        frame_count = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
        height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))

        # Initialize tracker
        tracker = BasketballTracker()

        all_detections = []
        frame_number = 0

        while True:
            ret, frame = cap.read()
            if not ret:
                break

            # Calculate timestamp for this frame
            timestamp = frame_number / fps if fps > 0 else frame_number * (1/30)  # fallback to 30fps

            # Run YOLO detection
            results = model(frame, verbose=False)

            # Extract basketball detections (assuming class 0 is basketball)
            detections = []
            if len(results) > 0 and results[0].boxes is not None:
                boxes = results[0].boxes
                for i in range(len(boxes)):
                    # Get bounding box coordinates
                    x1, y1, x2, y2 = boxes.xyxy[i].cpu().numpy()
                    confidence = boxes.conf[i].cpu().numpy()

                    # Filter by confidence threshold
                    if confidence > 0.5:  # Adjust threshold as needed
                        detections.append([float(x1), float(y1), float(x2), float(y2), float(confidence)])

            # Update tracker with detections
            tracked_objects = tracker.update(detections, timestamp)

            # Add frame info to results
            frame_data = {
                'frame_number': frame_number,
                'timestamp': timestamp,
                'detections': tracked_objects
            }
            all_detections.append(frame_data)

            frame_number += 1

        cap.release()

        # Clean up temp file
        if os.path.exists(video_path):
            os.remove(video_path)

        return {
            "video_info": {
                "fps": fps,
                "total_frames": frame_count,
                "duration": frame_count / fps if fps > 0 else 0,
                "width": width,
                "height": height
            },
            "tracking_results": all_detections
        }

    except Exception as e:
        # Clean up temp file in case of error
        if os.path.exists(video_path):
            os.remove(video_path)
        return {"error": f"Processing failed: {str(e)}"}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
