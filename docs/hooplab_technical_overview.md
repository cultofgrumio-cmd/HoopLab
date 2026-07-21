---
title: "HoopLab — Technical Overview"
subtitle: "Computer Vision Basketball Shot Analysis · GameGala Demo"
date: "April 2026"
author: "Austin A."
geometry: "margin=1in"
fontsize: 11pt
linestretch: 1.3
colorlinks: true
linkcolor: "blue"
urlcolor: "blue"
toccolor: "black"
header-includes:
  - \usepackage{fancyhdr}
  - \pagestyle{fancy}
  - \fancyhead[L]{HoopLab}
  - \fancyhead[R]{Technical Overview}
  - \fancyfoot[C]{\thepage}
---

\newpage
\tableofcontents
\newpage

# 1. What Is HoopLab?

HoopLab is a mobile application (iOS + Android) that uses on-device computer vision to analyze basketball shots in real time. A player records a shooting session — or uploads an existing video — and the app automatically:

- Detects every basketball shot in the footage
- Tracks the ball frame-by-frame across its entire arc
- Identifies which hoop the ball was aimed at (even when multiple hoops appear on screen)
- Determines whether the shot was a **MAKE** or **MISS** using both geometric rim-crossing analysis and the model's direct `made` detection label
- Scores shooting form across arc quality, release angle, proximity accuracy, and trajectory consistency

The result is a timestamped shot-by-shot breakdown with percentage accuracy scores and actionable form feedback — without any backend or cloud dependency at runtime.

**Recording setup — one prescribed angle.** HoopLab supports a single camera position: the player stands where the **half-court line meets a sideline** and aims the phone across the court at the rim. Standardising on this one diagonal corner angle (rather than offering a "backboard" vs "court/sideways" choice) lets the detection pipeline run a single tuned configuration, and lets the UI *guide* the user to the correct spot instead of asking them to pick a mode. The in-app camera, the live-workout view, and the method picker all surface a top-down court diagram (`widgets/recording_angle_guide.dart`) marking exactly where to stand.

---

# 2. Architecture

## 2.1 Platform Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3 (Dart) |
| Object Detection | YOLO11n (TFLite FP16, on-device) via `ultralytics_yolo` |
| Pose Detection | Google ML Kit Pose Detection |
| Video Processing | FFmpeg (`ffmpeg_kit_flutter_new`) |
| Video Playback | `video_player` + custom Chewie fork |

The app is entirely self-contained at runtime. No server calls are made during analysis — every inference runs on the device.

## 2.2 Project Layout

```
lib/
├── main.dart                    # App entry point, Material theme
├── pages/
│   ├── method_selector.dart     # Landing screen + gallery import & trimmer
│   ├── camera.dart              # In-app camera recording
│   ├── viewer.dart              # Core analysis page + results UI
│   ├── session_history.dart     # Saved sessions + aggregate stats
│   ├── shot_log.dart            # Per-shot breakdown for one session
│   └── settings.dart            # Theme selection
├── models/
│   ├── clip.dart                # Clip, FrameData, Detection, BoundingBox, Shot + DetectionLabel
│   └── session.dart             # Session, SavedShot (persisted to JSON)
├── services/
│   ├── session_storage.dart     # Session persistence (documents dir)
│   └── theme_storage.dart       # Theme-mode persistence
├── widgets/
│   ├── trajectory_overlay.dart  # CustomPaint: ball trajectory + pose skeleton
│   └── clean_video_player.dart  # Video player wrapper (Chewie)
└── utils/
    ├── trajectory_prediction.dart  # Shot math: rim crossing, made detection, arc prediction
    ├── shot_quality_evaluator.dart # Form scoring (arc, angle, distance, consistency)
    └── shooting_pose_detector.dart # ML Kit pose → shooting-motion confidence
```

## 2.3 Primary Data Flow

```
User picks video
      │
      ▼
FFmpeg extracts frames to temp directory
      │
      ▼
YOLO inference on each frame  ──►  FrameData { detections[] }
      │                                │
      │  (per frame)                   │  labels: ball, made, person, rim, shoot
      ▼                                ▼
Shooting motion =            Stored in Clip.frames[]
  ML Kit pose  ∪  YOLO "shoot" class
      │
      ▼
Shot Segmentation  (ShotDetector.detect — one detector, one tuned config)
  ├── ball-approach-to-rim   (primary, corner-angle tuned)
  ├── pose / "shoot" motion  (rescues ambiguous approaches)
  └── motion-window fallback (when no rim is detected)
      │
      ▼
Per-shot Analysis
  ├── _findTargetHoop()         (direction-of-travel hoop selection)
  ├── calculateShotAccuracyFromRimCrossing()
  ├── checkMadeDetection()
  └── ShotQualityEvaluator.evaluateShotQuality()
      │
      ▼
Shot { accuracy, prediction, hoopPosition, frames }
      │
      ▼
TrajectoryOverlay + TimeLine rendered on top of video playback
```

---

# 3. Data Models

## 3.1 `Clip`

The top-level container for a single video analysis session.

```dart
class Clip {
  String id, name, videoPath;
  List<FrameData> frames;  // one entry per analyzed frame
  List<Shot>  shots;       // detected shots (populated after segmentation)
}
```

## 3.2 `FrameData`

Represents one video frame after inference.

```dart
class FrameData {
  int    frameNumber;
  double timestamp;            // seconds
  List<Detection> detections;  // all objects detected in this frame
  bool   isShootingMotion;     // ML Kit: someone in shooting pose?
  double shootingConfidence;   // 0.0 – 1.0
  List<Pose>? poses;           // raw ML Kit landmark data
}
```

## 3.3 `Detection`

A single YOLO bounding box.

```dart
class Detection {
  int    trackId;
  BoundingBox bbox;    // x1, y1, x2, y2 in pixel coordinates
  double confidence;
  String label;        // "ball", "hoop", "rim", "basket", "made", ...
}
```

## 3.4 `Shot`

The result of segmenting and analyzing one shooting attempt.

```dart
class Shot {
  int    id;
  List<FrameData> frames;
  double  startTime, endTime;
  String? prediction;    // "MAKE • <form feedback>" or "MISS • ..."
  double? accuracy;      // 0–100 %
  double? formScore;     // shooting-form quality, 0–100 (independent of make/miss)
  String? feedback;      // human-readable form feedback
  Offset? hoopPosition;  // target hoop center (pixel coords)
  bool get isMake;       // prediction starts with "MAKE"
}
```

Both segmentation paths score shots through a single shared helper
(`viewer.dart → _scoreShot`), so make/miss determination and form scoring are
identical regardless of which segmenter ran. `formScore` and `feedback` are
persisted on `SavedShot` and shown in the viewer and session shot log.

---

# 4. Analysis Pipeline

## 4.1 Frame Extraction

`viewer.dart → extractVideoFrames()`

FFmpeg extracts every frame from the video into a temporary directory at the device's native resolution. Frames are deleted immediately after analysis completes (`_framesDir.deleteSync(recursive: true)`) to avoid filling device storage.

## 4.2 YOLO Inference

`viewer.dart → analyzeVideoFrames()`

Each frame image is fed to the on-device YOLO model (`best_float16.tflite`). The model returns bounding boxes with labels. Its class set is:

| Class id | Label | Meaning |
|---|---|---|
| 0 | `ball` | Basketball |
| 1 | `made` | Ball detected inside / passing through the hoop |
| 2 | `person` | A player (used to lock onto the shooter) |
| 3 | `rim` | Basketball hoop / rim |
| 4 | `shoot` | Shooting motion in progress |

Detection results are stored as `FrameData` entries in `Clip.frames`. Label
matching goes through the `DetectionLabel` extension in `clip.dart`
(`isBall`, `isRim`, `isMade`, `isPerson`, `isShoot`), which accepts both the
string class name and the numeric class id so the app is robust to whichever
form the `ultralytics_yolo` plugin returns (legacy `hoop`/`basket` aliases also
map to `isRim`). The `made` label is produced directly by the model when it
observes the ball clearly inside the hoop — this is later used as a
high-confidence MAKE signal.

## 4.3 Pose Detection

`ShootingPoseDetector` runs Google ML Kit pose detection on a padded crop
around the locked shooter. It examines body landmark positions (wrists,
elbows, shoulders) to determine whether a person is in a **shooting motion**.

Key heuristics used:
- Dominant wrist is above the shoulder (arm raised)
- Elbow is above shoulder height
- Shooting-arm elbow angle is in the 90°–160° range

**Two-signal shooting detection.** The pose result is fused with the model's
own `shoot` class (`viewer.dart → analyzeVideoFrames`): a frame is marked as
shooting motion when *either* ML Kit pose fires *or* a `shoot` detection is
present with sufficient confidence, and `shootingConfidence` is the max of the
two. Because the `shoot` box comes out of the same YOLO pass, this is
essentially free and makes shot segmentation fire even when the skeleton
is unclear. Fusion is strictly additive — it can only add shooting frames,
never remove them.

---

# 5. Shot Segmentation

A single detector (`ShotDetector.detect`, in `utils/shot_detector.dart`) runs one configuration, tuned for the prescribed corner recording angle. Instead of relying on a rigid geometric region (which only worked front-on) or a hard pose gate (which failed when the shooter was occluded), it segments on the **ball's approach to a rim** — a robust signal for the diagonal corner view, where the ball passes *through* the rim plane rather than dropping straight onto it.

## 5.1 Primary signal — ball approach to rim

1. **Rim clustering.** Rim detections across all frames are grouped by proximity into stable rim candidates (running-averaged centre + bbox), so a spurious background rim doesn't derail detection.
2. **Approach runs.** For each rim, the ball's per-frame distance to the rim centre is normalised by rim width. A contiguous run where that distance stays below `approachFactor × rimWidth` (≈2.4, kept slightly loose because the corner angle sends the ball through the rim plane at an angle) is "the ball at the rim". Short ball-tracking gaps are tolerated.
3. **Shot qualification.** A run only counts as a shot if the ball actually *travelled in* — it was at least `farFactor × rimWidth` away during the lead-up (so a ball merely loitering under the rim is ignored) **or** there is shooting motion nearby.
4. **Window.** The span is expanded by a lead (~1 s, to capture the release) and a trail (~0.75 s, to capture the arc + landing). Overlapping/very-close windows are merged (ball rattling the rim = one shot).

**Minimum shot**: 8 frames and ≥3 ball detections. Deliberately permissive — downstream make/miss scoring sorts out the rest, rather than dropping real shots.

## 5.2 Rescue signals and fallback (fail-proof)

- **Pose / `shoot` motion** rescues an approach the ball geometry is unsure about (e.g. the ball was lost mid-arc). It is a *booster*, never a hard gate, so clips with no visible shooter still segment.
- **Motion-window fallback**: if no rim was ever detected (or geometry found nothing while there is clear shooting motion), the detector falls back to segmenting contiguous shooting-motion runs, so it never silently returns nothing. These shots are surfaced but left unscored (no rim to score against).

The behaviour is covered by unit tests (`test/shot_detector_test.dart`): a clear arc, a near-horizontal pass through the rim, dribbling (no shot), ball loitering at the rim (no shot), two separated shots, a dropped-ball gap mid-arc, and both no-rim fallbacks.

---

# 6. Multi-Hoop Target Selection

This is one of the most technically interesting problems HoopLab solves. Many gym recordings contain **multiple hoops** in the same frame — a foreground target hoop and one or more background hoops. Selecting the wrong hoop produces a false MISS even when the ball goes cleanly through the target.

## 6.1 `_findTargetHoop()` — Four-Tier Algorithm

After collecting all hoop detections across the shot's frames, unique hoops are grouped by proximity (detections within 50 px of each other are treated as the same hoop). If only one unique hoop is found, it is used directly. With multiple candidates, the following tiers run in order until one produces a confident result:

### Tier 1 — Rim Crossing (most reliable)

`calculateShotAccuracyFromRimCrossing()` is run against each candidate hoop. If exactly one hoop shows a **confirmed** rim crossing (confidence: `high` or `medium`), that hoop is selected. A proximity-only estimate (no confirmed crossing) does not trigger an early return — the algorithm falls through to Tier 2.

*Best for*: shots where the ball's Y-coordinate clearly crosses the rim plane.

### Tier 2 — Direction of Travel (primary corner-angle fix)

The ball always moves **toward** the target hoop. The algorithm computes the ball's overall direction vector (first detected position → last detected position), then for each hoop candidate computes the dot product:

```
alignment = (travelDx, travelDy) · (hoopCenter - lastBallPos)
```

The hoop with the highest positive alignment is selected. A negative alignment means the hoop is **behind** the ball's direction of travel — that hoop is skipped.

*Best for*: the diagonal corner angle, where a background hoop sits away from the target hoop across the frame.

### Tier 3 — Endpoint Proximity

If the ball didn't move meaningfully (tiny magnitude travel vector), fall back to which hoop the ball's **final 30% of detections** are closest to on average.

### Tier 4 — All-Frame Minimum Proximity

Last resort: which hoop had the single smallest distance to any ball detection across all frames.

## 6.2 Overlay Hoop Ring (`trajectory_overlay.dart`)

The red ring drawn on the video during playback uses the same direction-of-travel logic (implemented independently in `_getTargetHoopDetection()`). This ensures the visual indicator and the MAKE/MISS calculation always agree on which hoop is the target.

---

# 7. Shot Accuracy — Make/Miss Determination

The final MAKE/MISS decision and accuracy percentage are computed from two independent signals that are combined in priority order.

## 7.1 `checkMadeDetection()` — Primary Signal

Scans the shot's frames for any detection labeled `"made"` within **200 px** of the target hoop center. When found, returns:

```
accuracy = 95%
confidence = ShotConfidence.high
reason = "made label detected by model"
```

This is direct visual evidence — the model saw the ball inside the hoop. It is prioritized over all geometric methods, which is especially important from the corner angle where the Y-axis crossing test is geometrically unreliable.

## 7.2 `calculateShotAccuracyFromRimCrossing()` — Fallback Signal

When no `made` label fires, a geometric rim-crossing test runs:

1. Trajectory points are interpolated (midpoints inserted) to increase resolution.
2. Scanning backward from the trajectory end, find the last point **above** the rim plane and the first point **below** it.
3. Linear interpolate between the two crossing points to find the exact X coordinate at rim height.
4. Compare this X against the rim center and width:

```
accuracy = (1 - |crossingX - rimCenterX| / rimRadius) × 100
```

This produces `ShotConfidence.high` when a complete arc (ascent + descent) is observed, `ShotConfidence.medium` for partial arcs, and falls back to proximity estimation when no crossing is found at all.

## 7.3 Final Result

```dart
final madeResult = TrajectoryPredictor.checkMadeDetection(frames, targetHoop);
final finalResult = madeResult ?? rimCrossingResult;
shot.accuracy = finalResult.accuracy;
shot.prediction = finalResult.accuracy > 50.0 ? "MAKE" : "MISS";
```

The 50% threshold means a shot must cross within one rim-radius of center to count as made — consistent with the physical margin of the actual rim.

## 7.4 Multi-Hoop Consistency in Rim Crossing

When `calculateShotAccuracyFromRimCrossing()` runs with `frames` provided, it dynamically updates the active hoop position from per-frame detections. In multi-hoop scenes, `_getHoopFromFrame()` uses the `initialHoopPosition` as an anchor — it always returns the hoop detection **closest to the originally selected target**, preventing camera movement or frame-to-frame ordering from drifting to the background hoop mid-calculation.

---

# 7B. Release Prediction (`shot_predictor.dart`)

Separately from the actual outcome, HoopLab predicts whether each shot will go in **at the moment of release** — so it can tell the shooter "that's going in / that's short" before the ball reaches the rim.

`ShotPredictor.predictFromRelease()` uses **only the launch portion** of the trajectory (release → apex), so it never peeks at the outcome:

1. **Isolate the launch.** Find the arc's apex (highest point) and walk back to where the ball began rising — that release→apex segment is the launch.
2. **Fit a projectile model.** Least-squares fit of `x = a·t + b` (constant horizontal velocity) and `y = a·t² + b·t + c` (gravity) to the launch points.
3. **Project and measure.** Extrapolate the parabola forward and find the closest approach of the projected path to the rim centre. `predictedAccuracy = (1 − minDist / rimRadius) × 100`; **predicted make** when that exceeds 50%.
4. **Confidence** scales with the number of launch points, the fit residual (RMSE), and whether the fitted arc actually curves back down.

The result (`predictedMake`, `predictedAccuracy`) is stored on the shot, persisted in the saved session, and surfaced three ways: an **"At release: GOING IN / OFF TARGET"** badge on the result card and video overlay, a **Pred: IN/OUT ✓/✗** chip in the shot log, and a session-level **"prediction N/M correct"** stat. This lets a shooter see when a good release rimmed out (or a bad release got lucky). Covered by `test/shot_predictor_test.dart`.

---

# 8. Shot Form Scoring

`ShotQualityEvaluator.evaluateShotQuality()` scores the shooting form independently of the MAKE/MISS result. Four components sum to 100 points:

| Component | Max Points | What it measures |
|---|---|---|
| Arc Quality | 30 | Peak height ratio (1.2×–1.8× vertical hoop distance is ideal); peak position in middle third of arc |
| Release Angle | 25 | Initial trajectory angle (45°–55° is optimal for basketball) |
| Distance to Target | 25 | Closest approach of ball to hoop center |
| Trajectory Consistency | 20 | Average direction-change per step (smooth arcs score higher) |

The combined score drives the form feedback string appended to the prediction: `"MAKE • Good shot form"` or `"MISS • Arc too flat or inconsistent"`.

---

# 9. Trajectory Visualization

`TrajectoryPainter` (in `trajectory_overlay.dart`) is a `CustomPainter` rendered on top of the video player. It repaints on every video position change.

**Drawn elements:**

| Element | Visual |
|---|---|
| Ball trajectory | Orange solid line through all detected positions up to current time |
| Ball bounding box | Yellow rectangle at current frame |
| Ball position dot | Blue circle with white highlight |
| Target hoop ring | Red circle at target hoop center, radius = detected hoop width / 2 |
| Predicted arc (make) | Green dashed line to hoop |
| Corrected arc (miss) | Green dashed ideal arc from release point to hoop center |
| Shot feedback text | White text with blue background near hoop |

**Hoop ring selection**: `_getTargetHoopDetection()` computes the ball's direction of travel across all frames, then for each hoop candidate in the current frame takes the dot product against the travel vector. The hoop with the highest positive alignment is highlighted — this is consistent with the direction-of-travel Tier 2 logic in `_findTargetHoop()`.

**Trajectory cleaning**: Before rendering, raw detections are filtered to `confidence >= 0.5` and outliers removed by a speed check (`distance / timeDelta < 2000 px/s`, `distance < 200 px`). This suppresses stray detections without smoothing the legitimate arc.

---

# 10. Dependencies

| Package | Purpose |
|---|---|
| `ultralytics_yolo 0.1.36` | On-device YOLO11n inference via TFLite |
| `google_mlkit_pose_detection ^0.13.0` | Body pose landmark detection |
| `ffmpeg_kit_flutter_new ^3.2.0` | Frame extraction from video files |
| `video_player ^2.10.0` | Video playback |
| `chewie` (custom fork) | Video player UI controls |
| `pro_video_editor ^0.3.0` | Video trimming before analysis |
| `camera ^0.11.3` | In-app camera recording |
| `image_picker ^1.2.0` | Gallery video selection |
| `path_provider ^2.1.5` | Temp directory for extracted frames |
| `wakelock_plus ^1.4.0` | Prevent screen sleep during analysis |

---

# 11. ML Model

**File**: `assets/best_float16.tflite`  
**Architecture**: YOLO11n (FP16 quantized for mobile)  
**Input size**: 640×640  
**Classes**: `0=ball`, `1=made`, `2=person`, `3=rim`, `4=shoot`

The model runs entirely on-device using the Neural Engine (iOS) or GPU delegate (Android). No network access is required during inference. The FP16 quantization halves memory bandwidth vs. FP32 with minimal accuracy loss on detection tasks.

---

# 12. Key Design Decisions

**No cloud dependency at runtime.** All inference is on-device. This keeps latency low, protects user video privacy, and removes the need for any server infrastructure.

**Two-signal MAKE/MISS.** The `made` label and rim-crossing geometry are complementary: the model label fires on clear makes; direction-of-travel hoop selection + rim crossing handles ambiguous cases; the model label takes priority from the corner angle where Y-axis geometry is unreliable.

**Direction-of-travel hoop selection.** The ball always moves toward the target hoop. Even when YOLO loses the ball mid-arc (common when it passes behind a player or the net), the overall travel direction computed from first → last detected positions reliably points to the correct hoop. This works at any camera angle.

**Four-tier hoop selection with graceful degradation.** Rim crossing → direction of travel → endpoint proximity → all-frame minimum. Each tier only activates if the previous tier was inconclusive. This means the most geometrically certain method wins, but the algorithm never silently fails.

**One prescribed recording angle.** Rather than asking the user to classify their footage as "backboard" or "court/sideways," HoopLab prescribes a single position (half-court/sideline corner, aimed at the rim) and guides the user to it with an on-screen court diagram. The detector then runs one configuration tuned for that angle — no mode toggle to get wrong.

**Ball-approach shot segmentation, single-config and fail-proof.** The detector segments on the ball travelling from far into a rim's vicinity — robust for the corner angle, where the ball crosses the rim plane at a diagonal. Pose / `shoot` motion only *rescues* ambiguous approaches rather than gating them, and a motion-window fallback runs when no rim is detected, so the detector never silently returns nothing when a shot clearly happened. A ball loitering under the rim (which never approached from distance) is correctly rejected.

**Visual/algorithmic consistency.** The hoop ring drawn on the video overlay uses the same direction-of-travel logic as the MAKE/MISS calculation. The user always sees the red ring on the same hoop that determined the score.

---

# 13. Known Limitations

- **Ball tracking gaps**: YOLO occasionally loses the ball at peak arc height or when it passes behind a player. The app handles this gracefully (direction-of-travel doesn't require continuous tracking), but very sparse trajectories fall back to proximity estimation.

- **Corner-angle rim crossing**: The Y-axis rim crossing test is geometrically cleanest for front-facing camera angles. From the prescribed corner angle the ball crosses the rim plane diagonally and may not produce a clean Y-axis crossing. This is why `made` detection is prioritized and direction-of-travel is Tier 2 in hoop selection.

- **Single-shot sessions**: The legacy segmentation works best for isolated shot attempts. Dense sequences (e.g., rapid-fire practice) may over-merge or under-segment shots.

- **Pose detection accuracy**: ML Kit pose confidence varies with partial occlusion or non-standard shooting mechanics. The 0.6 confidence threshold is a balance between sensitivity and false positives.

---

*HoopLab — v1.0.2 · Built with Flutter · Powered by YOLO11n + Google ML Kit*
