import 'dart:io';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

class CleanVideoPlayer extends StatefulWidget {
  final String videoPath;
  final Widget? overlay;
  final VoidCallback? onVideoReady;
  final Function(Duration)? onPositionChanged;

  const CleanVideoPlayer({
    super.key,
    required this.videoPath,
    this.overlay,
    this.onVideoReady,
    this.onPositionChanged,
  });

  @override
  State<CleanVideoPlayer> createState() => CleanVideoPlayerState();
}

class CleanVideoPlayerState extends State<CleanVideoPlayer> {
  VideoPlayerController? _controller;
  ChewieController? _chewieController;
  VoidCallback? _positionListener;
  bool _isInitialized = false;
  bool _disposed = false;
  double _aspectRatio = 16 / 9; // Default aspect ratio

  @override
  void initState() {
    super.initState();
    _initializeVideoPlayer();
  }

  void _initializeVideoPlayer() async {
    final controller = VideoPlayerController.file(File(widget.videoPath));
    _controller = controller;
    await controller.initialize();
    // The widget may have been disposed while initialize() was in flight.
    if (_disposed || !mounted) return;

    // Get actual video dimensions for aspect ratio BEFORE creating ChewieController
    if (controller.value.size != Size.zero) {
      _aspectRatio =
          controller.value.size.width / controller.value.size.height;
    }

    final chewie = ChewieController(
      videoPlayerController: controller,
      autoPlay: true,
      looping: true,
      aspectRatio: _aspectRatio,
    );
    _chewieController = chewie;

    setState(() {
      _isInitialized = true;
    });

    widget.onVideoReady?.call();

    // Listen to position changes (throttled to avoid performance issues)
    Duration? lastReportedPosition;
    _positionListener = () {
      if (_disposed || !mounted) return;
      final currentPos = controller.value.position;
      // Only report if position changed by at least 100ms
      if (lastReportedPosition == null ||
          (currentPos - lastReportedPosition!).inMilliseconds.abs() >= 100) {
        lastReportedPosition = currentPos;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_disposed || !mounted) return;
          widget.onPositionChanged?.call(currentPos);
        });
      }
    };
    controller.addListener(_positionListener!);
  }

  @override
  void dispose() {
    _disposed = true;
    if (_positionListener != null) {
      _controller?.removeListener(_positionListener!);
    }
    _chewieController?.dispose();
    _controller?.dispose();
    super.dispose();
  }

  /// Seek to specific position
  Future<void> seekTo(Duration position) async {
    if (!_isInitialized || _disposed) return;

    try {
      await _chewieController?.seekTo(position);
      // Force a frame update after seek
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Seek error: $e');
    }
  }

  /// Play the video
  Future<void> play() async {
    if (!_isInitialized || _disposed) return;

    try {
      await _chewieController?.play();
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Play error: $e');
    }
  }

  /// Pause the video
  Future<void> pause() async {
    if (!_isInitialized || _disposed) return;

    try {
      await _chewieController?.pause();
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      debugPrint('Pause error: $e');
    }
  }

  /// Get current position
  Duration get currentPosition {
    return _controller?.value.position ?? Duration.zero;
  }

  /// Get video duration
  Duration get duration {
    return _controller?.value.duration ?? Duration.zero;
  }

  /// Get video size
  Size get videoSize {
    return _controller?.value.size ?? Size.zero;
  }

  /// Check if video is playing
  bool get isPlaying {
    return _controller?.value.isPlaying ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final chewie = _chewieController;
    if (!_isInitialized || controller == null || chewie == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(color: Color(0xFF1565C0)),
        ),
      );
    }

    return Container(
      color: Colors.black,
      child: Center(
        child: AspectRatio(
          aspectRatio: _aspectRatio,
          child: ValueListenableBuilder(
            valueListenable: controller,
            builder: (context, VideoPlayerValue value, child) {
              return Stack(
                children: [
                  // Video player - will rebuild when controller value changes
                  Chewie(controller: chewie),

                  // Custom overlay (for trajectory, etc.)
                  if (widget.overlay != null)
                    Positioned.fill(child: widget.overlay!),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
