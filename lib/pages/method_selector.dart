import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooplab/models/recording_mode.dart';
import 'package:hooplab/pages/camera.dart';
import 'package:hooplab/pages/live_workout.dart';
import 'package:hooplab/pages/session_history.dart';
import 'package:hooplab/pages/settings.dart';
import 'package:hooplab/pages/viewer.dart' as viewer;
import 'package:hooplab/services/recording_mode_storage.dart';
import 'package:hooplab/widgets/recording_angle_guide.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:pro_video_editor/pro_video_editor.dart';
import 'package:video_player/video_player.dart';

class MethodSelector extends StatefulWidget {
  const MethodSelector({super.key});

  @override
  State<MethodSelector> createState() => _MethodSelectorState();
}

class _MethodSelectorState extends State<MethodSelector>
    with SingleTickerProviderStateMixin {
  bool _isLoading = false;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  // Spacing between the two method buttons.
  static const double _buttonSpacing = 24.0;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );

    // Start entrance animation
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  // Prevent multiple simultaneous operations
  Future<void> _handleCameraPress() async {
    if (_isLoading) return;

    _setLoading(true);

    try {
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const CameraPage()),
      );
    } finally {
      _setLoading(false);
    }
  }

  Future<void> _handleLivePress() async {
    if (_isLoading) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const LiveWorkoutPage()),
    );
  }

  // Handle gallery selection with proper error handling
  Future<void> _handleGalleryPress() async {
    if (_isLoading) return;

    _setLoading(true);

    try {
      final result = await ImagePicker().pickVideo(source: ImageSource.gallery);

      if (result != null && mounted) {
        final videoPath = result.path;

        // Navigate to trimmer first
        final TrimDurationSpan? trimResult = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VideoTrimmer(originalVideoPath: videoPath),
          ),
        );

        if (trimResult != null && mounted) {
          String? finalPath;

          if (trimResult.duration.inSeconds <= 15) {
            // Short clip: render intermediate then open a second trimmer zoomed in
            final intermediatePath = await _generateTrimmedVideo(
              videoPath,
              trimResult,
              dialogText: 'Preparing fine trim...',
            );

            if (intermediatePath != null && mounted) {
              final TrimDurationSpan? refinedResult = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      VideoTrimmer(originalVideoPath: intermediatePath),
                ),
              );

              if (refinedResult != null && mounted) {
                finalPath = await _generateTrimmedVideo(
                  intermediatePath,
                  refinedResult,
                );
              }
            }
          } else {
            finalPath = await _generateTrimmedVideo(videoPath, trimResult);
          }

          if (finalPath != null && mounted) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => viewer.ViewerPage(videoPath: finalPath),
              ),
            );
          }
        }
      }
    } catch (e) {
      // Handle errors gracefully
      if (mounted) {
        _showErrorSnackBar('$e');
      }
    } finally {
      if (mounted) {
        _setLoading(false);
      }
    }
  }

  Future<String?> _generateTrimmedVideo(
    String videoPath,
    TrimDurationSpan trimSpan, {
    String dialogText = 'Trimming video...',
  }) async {
    try {
      if (!mounted) return null;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 16),
              Text(dialogText),
            ],
          ),
        ),
      );

      final video = EditorVideo.file(videoPath);
      final directory = await getTemporaryDirectory();
      final now = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${directory.path}/trimmed_video_$now.mp4';

      final exportModel = RenderVideoModel(
        id: now.toString(),
        video: video,
        outputFormat: VideoOutputFormat.mp4,
        enableAudio: true,
        startTime: trimSpan.start,
        endTime: trimSpan.end,
      );

      final trimmedPath = await ProVideoEditor.instance.renderVideoToFile(
        outputPath,
        exportModel,
      );

      if (mounted) {
        Navigator.pop(context); // Close loading dialog
      }

      return trimmedPath;
    } catch (e) {
      if (mounted) {
        Navigator.pop(context); // Close loading dialog
        _showErrorSnackBar('Failed to trim video: $e');
      }
      return null;
    }
  }

  void _setLoading(bool loading) {
    if (mounted) {
      setState(() {
        _isLoading = loading;
      });
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: colorScheme.surface,
      appBar: AppBar(
        title: const Text(
          'Choose Method',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        foregroundColor: colorScheme.onSurface,
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Session History',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SessionHistoryPage(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsPage()),
              );
            },
          ),
        ],
      ),
      body: FadeTransition(
        opacity: _fadeAnimation,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'Select how you want to add your video',
                    style: theme.textTheme.headlineSmall?.copyWith(
                      color: colorScheme.onSurface.withValues(alpha: 0.8),
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  // Where to record from — the single supported camera angle.
                  Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.videocam_outlined,
                                color: colorScheme.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Where to Record From',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          const RecordingAngleGuide(),
                          const SizedBox(height: 12),
                          _buildModeBanner(context),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Recording Tips Card
                  Card(
                    elevation: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                Icons.lightbulb_outline,
                                color: colorScheme.primary,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'Tips for Best Results',
                                style: theme.textTheme.titleMedium?.copyWith(
                                  color: colorScheme.primary,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildTip('📹', 'Use at least 4 seconds of footage'),
                          const SizedBox(height: 6),
                          _buildTip(
                            '🏀',
                            'Capture full shot: release → peak → rim',
                          ),
                          const SizedBox(height: 6),
                          _buildTip(
                            '💡',
                            'Good lighting - avoid shadows on ball',
                          ),
                          const SizedBox(height: 6),
                          _buildTip('🎯', 'Keep the rim fully visible in frame'),
                          const SizedBox(height: 6),
                          _buildTip(
                            '📐',
                            'Film from the half-court / sideline corner, '
                                'phone aimed across the court at the rim',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Headline: real-time live workout mode.
                  _MethodButton(
                    title: 'Live Workout',
                    subtitle: 'Real-time shots + spoken feedback',
                    icon: Icons.sports_basketball_rounded,
                    onPressed: _isLoading ? null : _handleLivePress,
                    color: Colors.deepOrange,
                    isLoading: _isLoading,
                  ),
                  const SizedBox(height: _buttonSpacing),

                  // Responsive layout
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final isWide = constraints.maxWidth > 600;

                      if (isWide) {
                        return Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            Expanded(child: _buildCameraButton(theme)),
                            const SizedBox(width: _buttonSpacing),
                            Expanded(child: _buildGalleryButton(theme)),
                          ],
                        );
                      } else {
                        return Column(
                          children: [
                            _buildCameraButton(theme),
                            const SizedBox(height: _buttonSpacing),
                            _buildGalleryButton(theme),
                          ],
                        );
                      }
                    },
                  ),

                  if (_isLoading) ...[
                    const SizedBox(height: 32),
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      'Please wait...',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Shows the active camera rig (tripod vs on-the-ground) with its setup tip,
  /// tappable to change it. Analysis is tuned to whichever is selected here.
  Widget _buildModeBanner(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ValueListenableBuilder<RecordingMode>(
      valueListenable: recordingModeNotifier,
      builder: (context, mode, _) {
        return InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsPage()),
          ),
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: scheme.primary.withValues(alpha: 0.2)),
            ),
            child: Row(
              children: [
                Icon(Icons.tune, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurface.withValues(alpha: 0.75),
                        height: 1.3,
                      ),
                      children: [
                        TextSpan(
                          text: '${mode.label} · ',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: scheme.primary,
                          ),
                        ),
                        TextSpan(text: mode.setupTip),
                      ],
                    ),
                  ),
                ),
                Icon(Icons.chevron_right,
                    size: 18,
                    color: scheme.onSurface.withValues(alpha: 0.4)),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTip(String emoji, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(width: 8),
        Expanded(
          child: Text(text, style: const TextStyle(fontSize: 13, height: 1.3)),
        ),
      ],
    );
  }

  Widget _buildCameraButton(ThemeData theme) {
    return _MethodButton(
      title: 'Camera',
      subtitle: 'Record a new video',
      icon: Icons.camera_alt_rounded,
      onPressed: _isLoading ? null : _handleCameraPress,
      color: theme.colorScheme.primary,
      isLoading: _isLoading,
    );
  }

  Widget _buildGalleryButton(ThemeData theme) {
    return _MethodButton(
      title: 'Gallery',
      subtitle: 'Choose from library',
      icon: Icons.photo_library_rounded,
      onPressed: _isLoading ? null : _handleGalleryPress,
      color: theme.colorScheme.secondary,
      isLoading: _isLoading,
    );
  }
}

// Extracted custom widget for better reusability and organization
class _MethodButton extends StatefulWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onPressed;
  final Color color;
  final bool isLoading;

  const _MethodButton({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onPressed,
    required this.color,
    this.isLoading = false,
  });

  @override
  State<_MethodButton> createState() => _MethodButtonState();
}

class _MethodButtonState extends State<_MethodButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _scaleController = AnimationController(
      duration: const Duration(milliseconds: 150),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _scaleController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _scaleController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEnabled = widget.onPressed != null && !widget.isLoading;

    return ScaleTransition(
      scale: _scaleAnimation,
      child: GestureDetector(
        onTapDown: isEnabled ? (_) => _scaleController.forward() : null,
        onTapUp: isEnabled ? (_) => _scaleController.reverse() : null,
        onTapCancel: () => _scaleController.reverse(),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 180.0,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: isEnabled
                  ? [
                      widget.color.withValues(alpha: 0.1),
                      widget.color.withValues(alpha: 0.05),
                    ]
                  : [
                      theme.colorScheme.onSurface.withValues(alpha: 0.05),
                      theme.colorScheme.onSurface.withValues(alpha: 0.02),
                    ],
            ),
            borderRadius: BorderRadius.circular(16.0),
            border: Border.all(
              color: isEnabled
                  ? widget.color.withValues(alpha: 0.3)
                  : theme.colorScheme.onSurface.withValues(alpha: 0.1),
              width: 2,
            ),
            boxShadow: isEnabled
                ? [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isEnabled
                      ? widget.color.withValues(alpha: 0.1)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.icon,
                  size: 48.0,
                  color: isEnabled
                      ? widget.color
                      : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isEnabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isEnabled
                      ? theme.colorScheme.onSurface.withValues(alpha: 0.7)
                      : theme.colorScheme.onSurface.withValues(alpha: 0.3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class VideoTrimmer extends StatefulWidget {
  final String originalVideoPath;
  const VideoTrimmer({super.key, required this.originalVideoPath});

  @override
  State<VideoTrimmer> createState() => _VideoTrimmerState();
}

class _VideoTrimmerState extends State<VideoTrimmer> {
  VideoPlayerController? _videoController;
  ProVideoController? _proVideoController;
  VideoMetadata? _videoMetadata;
  List<ImageProvider>? _thumbnails;
  bool _isInitializing = true;
  bool _isSeeking = false;
  bool _disposed = false;
  TrimDurationSpan? _durationSpan;
  TrimDurationSpan? _tempDurationSpan;

  final int _thumbnailCount = 7;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  @override
  void dispose() {
    _disposed = true;
    // Remove the listener BEFORE disposing so a teardown-time notification
    // can't invoke _onVideoPositionChange on a disposed controller.
    _videoController?.removeListener(_onVideoPositionChange);
    _videoController?.dispose();
    _videoController = null;
    super.dispose();
  }

  Future<void> _initializeVideo() async {
    try {
      // Get video metadata
      final video = EditorVideo.file(widget.originalVideoPath);
      _videoMetadata = await ProVideoEditor.instance.getMetadata(video);
      if (_disposed) return;

      // Initialize video player
      final controller = VideoPlayerController.file(
        File(widget.originalVideoPath),
      );
      _videoController = controller;
      await controller.initialize();
      // If the screen was popped during any await above, dispose() has already
      // torn down _videoController — bail out instead of touching it again.
      if (_disposed) return;
      await controller.setLooping(false);
      await controller.setVolume(0);

      // Generate thumbnails
      await _generateThumbnails(video);
      if (_disposed) return;

      // Create ProVideoController
      _proVideoController = ProVideoController(
        videoPlayer: _buildVideoPlayer(),
        initialResolution: _videoMetadata!.resolution,
        videoDuration: _videoMetadata!.duration,
        fileSize: _videoMetadata!.fileSize,
        thumbnails: _thumbnails,
      );

      controller.addListener(_onVideoPositionChange);

      if (mounted) {
        setState(() {
          _isInitializing = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to load video: $e'),
            backgroundColor: Colors.red,
          ),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _generateThumbnails(EditorVideo video) async {
    final imageWidth =
        MediaQuery.of(context).size.width /
        _thumbnailCount *
        MediaQuery.of(context).devicePixelRatio;

    final duration = _videoMetadata!.duration;
    final segmentDuration = duration.inMilliseconds / _thumbnailCount;

    final thumbnailList = await ProVideoEditor.instance.getThumbnails(
      ThumbnailConfigs(
        video: video,
        outputSize: Size.square(imageWidth),
        boxFit: ThumbnailBoxFit.cover,
        timestamps: List.generate(_thumbnailCount, (i) {
          final midpointMs = (i + 0.5) * segmentDuration;
          return Duration(milliseconds: midpointMs.round());
        }),
        outputFormat: ThumbnailFormat.jpeg,
      ),
    );

    _thumbnails = thumbnailList.map(MemoryImage.new).toList();

    // Precache thumbnails
    if (!mounted) return;
    await Future.wait(_thumbnails!.map((item) => precacheImage(item, context)));
  }

  void _onVideoPositionChange() {
    // The listener can fire during teardown; never touch a disposed controller.
    if (_disposed || _videoController == null || _videoMetadata == null) return;
    final duration = _videoController!.value.position;
    _proVideoController?.setPlayTime(duration);

    if (_durationSpan != null && duration >= _durationSpan!.end) {
      _seekToPosition(_durationSpan!);
    } else if (duration >= _videoMetadata!.duration) {
      _seekToPosition(
        TrimDurationSpan(start: Duration.zero, end: _videoMetadata!.duration),
      );
    }
  }

  Future<void> _seekToPosition(TrimDurationSpan span) async {
    if (_disposed) return;
    _durationSpan = span;

    if (_isSeeking) {
      _tempDurationSpan = span;
      return;
    }
    _isSeeking = true;

    _proVideoController?.pause();
    _proVideoController?.setPlayTime(_durationSpan!.start);

    await _videoController?.pause();
    // Re-check after every await: the screen may have been popped mid-seek,
    // which disposes and nulls _videoController. This was the crash path.
    if (_disposed) {
      _isSeeking = false;
      return;
    }
    await _videoController?.seekTo(span.start);
    if (_disposed) {
      _isSeeking = false;
      return;
    }

    _isSeeking = false;

    if (_tempDurationSpan != null) {
      TrimDurationSpan nextSeek = _tempDurationSpan!;
      _tempDurationSpan = null;
      await _seekToPosition(nextSeek);
    }
  }

  Future<void> _saveTrimmedVideo() async {
    if (_durationSpan == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please set trim points')));
      return;
    }

    // Return the trim span to the calling page
    Navigator.pop(context, _durationSpan);
  }

  Widget _buildVideoPlayer() {
    return Center(
      child: AspectRatio(
        aspectRatio: _videoController!.value.size.aspectRatio,
        child: VideoPlayer(_videoController!),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializing) {
      return Scaffold(
        appBar: AppBar(title: const Text('Trim Video')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Trim Video'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check_circle),
            onPressed: _saveTrimmedVideo,
            tooltip: 'Save',
          ),
        ],
      ),
      body: ProImageEditor.video(
        _proVideoController!,
        callbacks: ProImageEditorCallbacks(
          videoEditorCallbacks: VideoEditorCallbacks(
            onPause: _videoController!.pause,
            onPlay: _videoController!.play,
            onMuteToggle: (isMuted) {
              _videoController!.setVolume(isMuted ? 0 : 100);
            },
            onTrimSpanUpdate: (durationSpan) {
              if (_videoController!.value.isPlaying) {
                _proVideoController?.pause();
              }
            },
            onTrimSpanEnd: _seekToPosition,
          ),
        ),
        configs: ProImageEditorConfigs(
          videoEditor: VideoEditorConfigs(
            initialMuted: true,
            initialPlay: false,
            isAudioSupported: true,
            minTrimDuration: const Duration(seconds: 1),
            playTimeSmoothingDuration: const Duration(milliseconds: 600),
          ),
        ),
      ),
    );
  }
}
