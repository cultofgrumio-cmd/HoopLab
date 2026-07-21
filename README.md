# HoopLab

On-device basketball shot analysis. Record or import a video and HoopLab
automatically detects each shot, tracks the ball through its arc, decides
**MAKE** or **MISS**, and scores your shooting form — all on the phone, with
no server or network required.

## How it works

Everything runs locally on the device:

1. **Trim** the clip (gallery imports pass through a trimmer first).
2. **Extract frames** with FFmpeg at the video's native frame rate.
3. **Detect** the ball, rim, players, and shot events on every frame with an
   on-device YOLO model (`assets/best_float16.tflite`).
4. **Detect shooting motion** by fusing two signals: Google ML Kit pose
   detection on the shooter and the model's own `shoot` class.
5. **Segment shots**, pick the target hoop, and score each shot from the
   `made` label / rim-crossing geometry plus a shooting-form evaluation.
6. **Review**: a trajectory overlay is drawn over playback, and sessions can be
   saved to a local history with make/miss stats.

See [`docs/hooplab_technical_overview.md`](docs/hooplab_technical_overview.md)
for the full pipeline and algorithm details.

## Running it

No backend, no configuration. From the project root:

```bash
flutter pub get
flutter run
```

Then choose a mode:

- **Live Workout** — point the camera at the hoop and every shot is scored in
  real time (makes / misses / streak / total) with optional spoken feedback you
  can toggle (make-or-miss call, shots-in-a-row, total).
- **Camera** / **Gallery** — record or import a clip, trim it, and tap
  **Analyze Shot** for the full frame-by-frame breakdown.

Make/miss is decided from several independent signals (the model's `made`
label, the ball's centre passing through the rim opening, a net-occlusion
"swish", and rim-crossing geometry) so clean makes register even from the
diagonal corner angle where a single geometric test fails.

### Where to record from

HoopLab expects **one** camera position: stand where the **half-court line
meets a sideline** and aim the phone across the court at the rim. The camera,
live-workout, and method screens all show a court diagram marking the spot, so
there's no camera-angle mode to choose — just line up with the guide.

### Recording tips (for best accuracy)

- Use at least ~4 seconds of footage covering release → peak → rim.
- Keep the rim fully in frame the whole time.
- Good, even lighting with no heavy shadows on the ball.

## Project layout

```
lib/
├── main.dart                       # App entry point + Material theme
├── models/
│   ├── clip.dart                   # Clip, FrameData, Detection, BoundingBox, Shot + label helpers
│   └── session.dart                # Saved sessions and shots (persisted to JSON)
├── pages/
│   ├── method_selector.dart        # Landing screen, gallery import + trimmer
│   ├── camera.dart                 # In-app recording
│   ├── live_workout.dart           # Real-time live workout mode (YOLOView + audio)
│   ├── viewer.dart                 # Analysis pipeline + results UI
│   ├── session_history.dart        # Saved sessions + aggregate stats
│   ├── shot_log.dart               # Per-shot breakdown for a session
│   └── settings.dart               # Theme selection
├── services/
│   ├── session_storage.dart        # Session persistence (documents dir)
│   ├── theme_storage.dart          # Theme-mode persistence
│   └── audio_feedback.dart         # TTS + spoken-feedback preferences
├── utils/
│   ├── shot_detector.dart          # Robust ball-approach shot segmentation
│   ├── make_detector.dart          # Multi-method make/miss determination
│   ├── shot_predictor.dart         # At-release make/miss prediction
│   ├── live_shot_tracker.dart      # Streaming shot/make detector (live mode)
│   ├── trajectory_prediction.dart  # Rim-crossing, made detection, arc prediction
│   ├── shot_quality_evaluator.dart # Shooting-form scoring
│   └── shooting_pose_detector.dart # ML Kit pose → shooting-motion confidence
└── widgets/
    ├── clean_video_player.dart     # Video player wrapper (Chewie)
    └── trajectory_overlay.dart     # Trajectory + pose-skeleton painters
```

## Model

`assets/best_float16.tflite` — YOLO11n (FP16), classes:
`0=ball, 1=made, 2=person, 3=rim, 4=shoot`. Runs on the device's Neural
Engine / GPU delegate.

## Tests

```bash
flutter test
```

Covers the scoring math (rim crossing, made detection), shot-form evaluation,
label matching, and session persistence.
