import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hooplab/pages/camera.dart';
import 'package:hooplab/pages/viewer.dart' as viewer;
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

  // Constants for consistent styling
  static const double _buttonHeight = 180.0;
  static const double _buttonSpacing = 24.0;
  static const double _borderRadius = 16.0;
  static const double _iconSize = 48.0;

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

  // Handle gallery selection with proper error handling
  Future<void> _handleGalleryPress() async {
    if (_isLoading) return;

    _setLoading(true);

    try {
      final result = await ImagePicker().pickVideo(source: ImageSource.gallery);

      if (result != null && result.path != null && mounted) {
        final videoPath = result.path;

        // Navigate to trimmer first
        final TrimDurationSpan? trimResult = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => VideoTrimmer(originalVideoPath: videoPath),
          ),
        );

        if (trimResult != null && mounted) {
          // Generate trimmed video
          final trimmedPath = await _generateTrimmedVideo(
            videoPath,
            trimResult,
          );

          if (trimmedPath != null && mounted) {
            // Navigate to viewer with trimmed video
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => viewer.ViewerPage(videoPath: trimmedPath),
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
    TrimDurationSpan trimSpan,
  ) async {
    try {
      if (!mounted) return null;

      // Show loading dialog
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => const AlertDialog(
          content: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('Trimming video...'),
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
                      color: colorScheme.onSurface.withOpacity(0.8),
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
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
                          _buildTip('🎯', 'Keep hoop fully visible in frame'),
                          const SizedBox(height: 6),
                          _buildTip(
                            '📏',
                            'Best results when hoop is almost parallel to camera',
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

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
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
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
                      widget.color.withOpacity(0.1),
                      widget.color.withOpacity(0.05),
                    ]
                  : [
                      theme.colorScheme.onSurface.withOpacity(0.05),
                      theme.colorScheme.onSurface.withOpacity(0.02),
                    ],
            ),
            borderRadius: BorderRadius.circular(16.0),
            border: Border.all(
              color: isEnabled
                  ? widget.color.withOpacity(0.3)
                  : theme.colorScheme.onSurface.withOpacity(0.1),
              width: 2,
            ),
            boxShadow: isEnabled
                ? [
                    BoxShadow(
                      color: widget.color.withOpacity(0.1),
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
                      ? widget.color.withOpacity(0.1)
                      : theme.colorScheme.onSurface.withOpacity(0.05),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  widget.icon,
                  size: 48.0,
                  color: isEnabled
                      ? widget.color
                      : theme.colorScheme.onSurface.withOpacity(0.3),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                widget.title,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: isEnabled
                      ? theme.colorScheme.onSurface
                      : theme.colorScheme.onSurface.withOpacity(0.3),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: isEnabled
                      ? theme.colorScheme.onSurface.withOpacity(0.7)
                      : theme.colorScheme.onSurface.withOpacity(0.3),
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
  const VideoTrimmer({Key? key, required this.originalVideoPath})
    : super(key: key);

  @override
  _VideoTrimmerState createState() => _VideoTrimmerState();
}

class _VideoTrimmerState extends State<VideoTrimmer> {
  VideoPlayerController? _videoController;
  ProVideoController? _proVideoController;
  VideoMetadata? _videoMetadata;
  List<ImageProvider>? _thumbnails;
  bool _isInitializing = true;
  bool _isSeeking = false;
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
    _videoController?.dispose();
    super.dispose();
  }

  Future<void> _initializeVideo() async {
    try {
      // Get video metadata
      final video = EditorVideo.file(widget.originalVideoPath);
      _videoMetadata = await ProVideoEditor.instance.getMetadata(video);

      // Initialize video player
      _videoController = VideoPlayerController.file(
        File(widget.originalVideoPath),
      );
      await _videoController!.initialize();
      await _videoController!.setLooping(false);
      await _videoController!.setVolume(0);

      // Generate thumbnails
      await _generateThumbnails(video);

      // Create ProVideoController
      _proVideoController = ProVideoController(
        videoPlayer: _buildVideoPlayer(),
        initialResolution: _videoMetadata!.resolution,
        videoDuration: _videoMetadata!.duration,
        fileSize: _videoMetadata!.fileSize,
        thumbnails: _thumbnails,
      );

      _videoController!.addListener(_onVideoPositionChange);

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
    await Future.wait(_thumbnails!.map((item) => precacheImage(item, context)));
  }

  void _onVideoPositionChange() {
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
    _durationSpan = span;

    if (_isSeeking) {
      _tempDurationSpan = span;
      return;
    }
    _isSeeking = true;

    _proVideoController?.pause();
    _proVideoController?.setPlayTime(_durationSpan!.start);

    await _videoController?.pause();
    await _videoController?.seekTo(span.start);

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
