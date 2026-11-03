import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:pocketstrike/features/agent/domain/agent_tool.dart';

/// Tools for Scene-by-Scene Video Mood Analysis and AI Voiceover Generation.
class VideoVoiceoverTools {
  const VideoVoiceoverTools._();

  static List<AgentTool> all() => [
        analyzeVideoScenes(),
        generateVideoVoiceover(),
      ];

  /// Tool 1: Analyzes video frames with Gemini Flash to detect scene-by-scene mood and create script.
  static AgentTool analyzeVideoScenes() => AgentTool(
        name: 'analyze_video_scenes',
        description:
            'Analyzes a video file scene-by-scene, detects emotional mood (suspense, comedy, action, emotional) for every scene interval, and generates a timed voiceover script.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'video_path': {
              'type': 'string',
              'description': 'Absolute path to the video file on device (e.g. in /storage/emulated/0/Download/...).',
            },
            'language': {
              'type': 'string',
              'description': 'Target language for the voiceover script (hi, ur, en). Default is "hi".',
            },
            'style_prompt': {
              'type': 'string',
              'description': 'Optional custom instruction for script tone (e.g. "Dramatic cinematic suspense", "Funny commentary", "Fast-paced raw roast").',
            },
            'gemini_api_key': {
              'type': 'string',
              'description': 'Optional Gemini API Key if not already configured in settings.',
            },
          },
          'required': ['video_path'],
        },
        risk: ToolRisk.safe,
        run: (args) async {
          final videoPath = args['video_path'] as String? ?? '';
          final lang = (args['language'] as String?)?.toLowerCase() ?? 'hi';
          final stylePrompt = args['style_prompt'] as String? ?? '';
          final apiKey = args['gemini_api_key'] as String? ?? Platform.environment['GEMINI_API_KEY'] ?? '';

          final file = File(videoPath);
          if (!await file.exists()) {
            return 'Error: Video file does not exist at path "$videoPath".';
          }

          if (apiKey.isEmpty) {
            return 'Error: Gemini API Key is required for video visual and mood understanding. Please provide gemini_api_key or set it in Settings -> Providers.';
          }

          try {
            // Create temp directory for extracted keyframes
            final tempDir = Directory('${file.parent.path}/.ps_keyframes_${DateTime.now().millisecondsSinceEpoch}');
            await tempDir.create(recursive: true);

            // 1. Extract 1 frame every 2 seconds via ffmpeg
            final ffmpegProcess = await Process.run('ffmpeg', [
              '-y',
              '-i', videoPath,
              '-vf', 'fps=0.5,scale=640:-1',
              '-q:v', '3',
              '${tempDir.path}/frame_%04d.jpg',
            ]);

            if (ffmpegProcess.exitCode != 0) {
              return 'FFmpeg frame extraction failed: ${ffmpegProcess.stderr}';
            }

            final frameFiles = tempDir
                .listSync()
                .whereType<File>()
                .where((f) => f.path.endsWith('.jpg'))
                .toList()
              ..sort((a, b) => a.path.compareTo(b.path));

            if (frameFiles.isEmpty) {
              return 'Error: No frames could be extracted from video.';
            }

            // Sample max 16 frames evenly spaced
            final maxFrames = 16;
            final step = (frameFiles.length / maxFrames).ceil().clamp(1, 9999);
            final sampled = <File>[];
            for (var i = 0; i < frameFiles.length; i += step) {
              if (sampled.length < maxFrames) sampled.add(frameFiles[i]);
            }

            // Build multimodal parts for Gemini API
            final parts = <Map<String, dynamic>>[];
            for (var i = 0; i < sampled.length; i++) {
              final sec = (i * step * 2.0).toStringAsFixed(1);
              final bytes = await sampled[i].readAsBytes();
              final b64 = base64Encode(bytes);
              parts.add({'text': '--- Frame at timestamp ${sec}s ---'});
              parts.add({
                'inline_data': {
                  'mime_type': 'image/jpeg',
                  'data': b64,
                }
              });
            }

            final systemPrompt = '''
You are a professional cinematic video voiceover director.
Analyze these chronological frames. Identify scene cuts, determine the emotional mood (e.g. suspense, tension, action, comedy, sad, dramatic, excited), and write an engaging voiceover script in $lang language for each scene.
Return ONLY valid JSON array with this structure:
[
  {
    "scene_id": 1,
    "start_second": 0.0,
    "end_second": 4.0,
    "detected_mood": "suspense",
    "scene_description": "short description of visual action",
    "script": "voiceover dialogue for this time window"
  }
]
${stylePrompt.isNotEmpty ? "User preference: $stylePrompt" : ""}
''';
            parts.add({'text': systemPrompt});

            final dio = Dio();
            final resp = await dio.post(
              'https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent?key=$apiKey',
              data: {
                'contents': [
                  {'parts': parts}
                ],
                'generationConfig': {
                  'temperature': 0.4,
                  'responseMimeType': 'application/json',
                }
              },
            );

            // Cleanup temp frames
            try {
              await tempDir.delete(recursive: true);
            } catch (_) {}

            final candidates = resp.data['candidates'] as List?;
            if (candidates == null || candidates.isEmpty) {
              return 'Gemini did not return any scene breakdown.';
            }

            final text = candidates[0]['content']['parts'][0]['text'] as String;
            return text;
          } catch (e) {
            return 'Error analyzing video scenes: $e';
          }
        },
      );

  /// Tool 2: Executes full end-to-end voiceover generation and FFmpeg merging.
  static AgentTool generateVideoVoiceover() => AgentTool(
        name: 'generate_video_voiceover',
        description:
            'Generates voiceover audio for each detected scene with emotional mood voice modulation (Edge-TTS), mixes it with video timeline using FFmpeg, and outputs the final video.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'video_path': {
              'type': 'string',
              'description': 'Path to original video.',
            },
            'gemini_api_key': {
              'type': 'string',
              'description': 'Gemini API key for vision analysis.',
            },
            'uncensored_api_key': {
              'type': 'string',
              'description': 'Optional Uncensored AI API key (OpenRouter / Local LLM) for unfiltered script rewriting.',
            },
            'language': {
              'type': 'string',
              'description': 'Voiceover language: hi (Hindi), ur (Urdu), en (English).',
            },
            'gender': {
              'type': 'string',
              'description': 'Voice gender: male or female.',
            },
            'prompt': {
              'type': 'string',
              'description': 'Special tone instruction (e.g. "Dark comedy", "Action thriller", "Roast commentary").',
            },
            'output_path': {
              'type': 'string',
              'description': 'Target output video file path.',
            },
          },
          'required': ['video_path'],
        },
        risk: ToolRisk.safe,
        run: (args) async {
          final videoPath = args['video_path'] as String? ?? '';
          final geminiKey = args['gemini_api_key'] as String? ?? Platform.environment['GEMINI_API_KEY'] ?? '';
          final uncensoredKey = args['uncensored_api_key'] as String? ?? '';
          final lang = args['language'] as String? ?? 'hi';
          final gender = args['gender'] as String? ?? 'male';
          final prompt = args['prompt'] as String? ?? '';
          
          final defaultOut = '${File(videoPath).parent.path}/voiceover_${DateTime.now().millisecondsSinceEpoch}.mp4';
          final outPath = args['output_path'] as String? ?? defaultOut;

          final scriptPath = '/data/user/0/com.termux/files/home/.gemini/antigravity-cli/scratch/video_voiceover/video_voiceover_pipeline.py';
          final scriptFile = File(scriptPath);
          if (!await scriptFile.exists()) {
            return 'Voiceover pipeline script not found at $scriptPath';
          }

          final cmdArgs = [
            scriptPath,
            '--video', videoPath,
            '--gemini-key', geminiKey,
            '--lang', lang,
            '--gender', gender,
            '--output', outPath,
          ];

          if (uncensoredKey.isNotEmpty) {
            cmdArgs.addAll(['--uncensored-key', uncensoredKey]);
          }
          if (prompt.isNotEmpty) {
            cmdArgs.addAll(['--prompt', prompt]);
          }

          final proc = await Process.run('python3', cmdArgs);
          if (proc.exitCode != 0) {
            return 'Voiceover generation failed:\n${proc.stderr}\n${proc.stdout}';
          }

          return 'Success! Voiceover video generated successfully.\nOutput saved at: $outPath\n\nLog:\n${proc.stdout}';
        },
      );
}
