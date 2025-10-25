import 'package:shared_preferences/shared_preferences.dart';

import 'attendance_service.dart';
import 'embedding_service.dart';
import 'face_detector_service.dart';
import 'recognition_service.dart';
import 'sync_service.dart';
import 'secure_key_service.dart';
// <<< CAMBIO: Importar el nuevo AuthService >>>
import 'auth_service.dart';

class ServiceLocator {
  static SharedPreferences? _prefs;
  static FaceDetectorService? _faceDetectorService;
  static EmbeddingService? _embeddingService;
  static RecognitionService? _recognitionService;
  static AttendanceService? _attendanceService;
  static SyncService? _syncService;
  static SecureKeyService? _secureKeyService;
  static String? _dbKey;
  // <<< CAMBIO: Añadir la instancia de AuthService >>>
  static AuthService? _authService;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();

    _secureKeyService ??= SecureKeyService();
    _dbKey = await _secureKeyService!.getOrCreateEncryptionKey();

    _faceDetectorService ??= FaceDetectorService();
    _embeddingService ??= EmbeddingService();

    // <<< CAMBIO: Inicializar AuthService (es rápido, no necesita await) >>>
    _authService ??= AuthService();

    _recognitionService ??= RecognitionService(_prefs!, _dbKey!);
    await _recognitionService!.init();

    _attendanceService ??= AttendanceService(_prefs!);
    await _attendanceService!.init();

    _syncService ??= SyncService();
    await _syncService!.init();

    // Carga del modelo TFLite (sin cambios)
    if (!(_embeddingService?.isLoaded ?? false)) {
      final String? path = _prefs!.getString('custom_model_path');
      if (path != null && path.isNotEmpty) {
        await _embeddingService!.loadModelFromFile(path);
      }
    }
    if (!(_embeddingService?.isLoaded ?? false)) {
      await _embeddingService!.loadModelFromAsset('assets/models/mobilefacenet_112x112_128d.tflite');
    }
    if (!(_embeddingService?.isLoaded ?? false)) {
      await _embeddingService!.loadModelFromAsset('assets/models/mobilefacenet.tflite');
    }
    if (!(_embeddingService?.isLoaded ?? false)) {
        print("ServiceLocator: ERROR CRÍTICO: El modelo TFLite no pudo ser cargado. Error: ${_embeddingService?.lastError}");
    }
  }

  static Future<void> setCustomModelPath(String? path) async {
    if (path == null || path.isEmpty) {
      await _prefs!.remove('custom_model_path');
      return;
    }
    await _prefs!.setString('custom_model_path', path);
  }

  static SharedPreferences get prefs => _prefs!;
  static FaceDetectorService get faceDetector => _faceDetectorService!;
  static EmbeddingService get embedder => _embeddingService!;
  static RecognitionService get recognition => _recognitionService!;
  static AttendanceService get attendance => _attendanceService!;
  static SyncService get sync => _syncService!;
  static String get dbKey => _dbKey!;
  // <<< CAMBIO: Getter para acceder a AuthService >>>
  static AuthService get auth => _authService!;
}