import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

// Permission Handling Section
const micChannel = MethodChannel('com.yourdomain.speech/microphone');

Future<bool> checkMicPermission() async {
  try {
    return await micChannel.invokeMethod('checkMicrophonePermission') ?? false;
  } on PlatformException {
    return await Permission.microphone.status.isGranted;
  }
}
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
    await Permission.microphone.request();

  runApp(const SomaliSpeechApp());
}

class SomaliSpeechApp extends StatelessWidget {
  const SomaliSpeechApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Somali Speech-to-Text',
      theme: ThemeData(
        primarySwatch: Colors.indigo,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      debugShowCheckedModeBanner: false,
      home: const HomePage(),
    );
  }
}

enum TabOption { upload, realtime }

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  TabOption _currentTab = TabOption.upload;
  String backendUrl = 'http://172.20.10.3:5000'; // Update this
  FlutterSoundRecorder recorder = FlutterSoundRecorder();
  bool isRecording = false;
  bool isUploading = false;
  String? uploadResult;
  String? liveTranscription;
  String? recordedFilePath;
  IO.Socket? socket;
  bool isConnected = false;
  StreamSubscription? _recorderSubscription;

  @override
  void initState() {
    super.initState();
    _initRecorder();
    _initSocket();

  }

  Future<void> _initRecorder() async {
    try {
      await recorder.openRecorder();
      await recorder.setSubscriptionDuration(const Duration(milliseconds: 100));
    } catch (e) {
      _showError("Recorder initialization failed: ${e.toString()}");
    }
  }

  void _initSocket() {
    socket = IO.io(
      backendUrl,
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .enableReconnection()
          .build(),
    );

    socket!.onConnect((_) {
      setState(() => isConnected = true);
      _showMessage("Connected to server");
    });

    socket!.onDisconnect((_) => setState(() => isConnected = false));
    socket!.onError((data) => _showError("Connection error: $data"));
    
    socket!.on('transcription', (data) {
      setState(() => liveTranscription = data['text']);
    });
    
    socket!.on('recording_started', (_) {
      _showMessage("Recording started on server");
    });
    
    socket!.on('recording_stopped', (_) {
      _showMessage("Recording stopped on server");
    });
    
    socket!.on('error', (data) {
      _showError("Server error: ${data['message']}");
    });
    
    socket!.connect();
  }

  Future<bool> _checkOrRequestPermission() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;
    
    final result = await Permission.microphone.request();
    if (result.isGranted) return true;
    
    if (result.isPermanentlyDenied) {
      await showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Microphone Permission Required"),
          content: const Text(
              "Please enable microphone permission in app settings"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
            TextButton(
              onPressed: () {
                openAppSettings();
                Navigator.pop(context);
              },
              child: const Text("Open Settings"),
            ),
          ],
        ),
      );
    }
    return false;
  }

  Future<void> pickAndUpload() async {
    if (isUploading) return;
    setState(() => isUploading = true);

    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowedExtensions: ['wav', 'mp3', 'ogg', 'flac'],
      );

      if (result != null && result.files.single.path != null) {
        File file = File(result.files.single.path!);
        var uri = Uri.parse("$backendUrl/upload");
        var request = http.MultipartRequest('POST', uri);
        request.files.add(await http.MultipartFile.fromPath('file', file.path));

        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (_) => const Center(child: CircularProgressIndicator()),
        );

        var response = await request.send();
        Navigator.pop(context);

        if (response.statusCode == 200) {
          final body = await response.stream.bytesToString();
          final jsonResponse = json.decode(body);
          setState(() => uploadResult = jsonResponse['transcription']);
        } else {
          _showError("Upload failed: ${response.statusCode}");
        }
      }
    } catch (e) {
      _showError("Upload error: ${e.toString()}");
    } finally {
      setState(() => isUploading = false);
    }
  }

  Future<void> startRecording() async {
    if (!isConnected) {
      _showError("Not connected to server");
      return;
    }

    final hasPermission = await _checkOrRequestPermission();
    if (!hasPermission) return;

    try {
      Directory tempDir = await getTemporaryDirectory();
      recordedFilePath = '${tempDir.path}/recording_${DateTime.now().millisecondsSinceEpoch}.wav';

      if (!recorder.isStopped) {
        await recorder.stopRecorder();
      }

      await recorder.startRecorder(
        toFile: recordedFilePath,
        codec: Codec.pcm16WAV,
        sampleRate: 16000,
        numChannels: 1,
      );

      socket!.emit('start_recording');

      _recorderSubscription = recorder.onProgress!.listen((_) {
        if (recorder.isRecording && recordedFilePath != null) {
          File(recordedFilePath!).readAsBytes().then((bytes) {
            final base64Audio = base64Encode(bytes);
            socket!.emit('audio_data', {'audio': base64Audio});
          });
        }
      });

      setState(() {
        isRecording = true;
        liveTranscription = "Listening...";
      });
    } catch (e) {
      _showError("Recording failed: ${e.toString()}");
    }
  }

  Future<void> stopRecording() async {
    try {
      await recorder.stopRecorder();
      _recorderSubscription?.cancel();
      
      socket!.emit('stop_recording');

      var response = await http.post(
        Uri.parse("$backendUrl/save-recording"),
        body: {"sid": socket!.id},
      );

      if (response.statusCode == 200) {
        final jsonResp = json.decode(response.body);
        setState(() => liveTranscription = jsonResp['transcription']);
      } else {
        _showError("Failed to save recording");
      }
    } catch (e) {
      _showError("Error stopping recording: ${e.toString()}");
    } finally {
      setState(() => isRecording = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  void _showError(String error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error),
        backgroundColor: Colors.red,
      ),
    );
  }

  @override
  void dispose() {
    _recorderSubscription?.cancel();
    recorder.closeRecorder();
    socket?.disconnect();
    super.dispose();
  }

  Widget uploadTab() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ElevatedButton(
            onPressed: isUploading ? null : pickAndUpload,
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              minimumSize: const Size(200, 50),
            ),
            child: isUploading
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 3),
                  )
                : const Text(
                    "Upload Audio File",
                    style: TextStyle(fontSize: 16),
                  ),
          ),
          const SizedBox(height: 32),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Transcription:",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                uploadResult != null
                    ? Text(uploadResult!, style: const TextStyle(fontSize: 16))
                    : const Text(
                        "No result yet",
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget realtimeTab() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton(
                onPressed: isRecording ? null : startRecording,
                style: ElevatedButton.styleFrom(
                  backgroundColor: isRecording ? Colors.grey : Colors.indigo,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  minimumSize: const Size(150, 50),
                ),
                child: const Text("Start", style: TextStyle(fontSize: 16)),
              ),
              const SizedBox(width: 20),
              ElevatedButton(
                onPressed: isRecording ? stopRecording : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: !isRecording ? Colors.grey : Colors.red,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                  minimumSize: const Size(150, 50),
                ),
                child: const Text("Stop", style: TextStyle(fontSize: 16)),
              ),
            ],
          ),
          const SizedBox(height: 32),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Live Transcription:",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                liveTranscription != null
                    ? Text(liveTranscription!, style: const TextStyle(fontSize: 16))
                    : const Text(
                        "No result yet",
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.circle,
                color: isConnected ? Colors.green : Colors.red,
                size: 12,
              ),
              const SizedBox(width: 8),
              Text(
                isConnected ? "Connected" : "Disconnected",
                style: TextStyle(
                  color: isConnected ? Colors.green : Colors.red,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Somali Speech-to-Text"),
        centerTitle: true,
      ),
      body: _currentTab == TabOption.upload ? uploadTab() : realtimeTab(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentTab.index,
        onTap: (i) => setState(() => _currentTab = TabOption.values[i]),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.upload_file),
            label: "Upload",
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.mic),
            label: "Real-time",
          ),
        ],
      ),
    );
  }
}