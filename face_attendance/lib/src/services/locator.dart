import 'package:shared_preferences/shared_preferences.dart';

import 'attendance_service.dart';
import 'embedding_service.dart';
import 'face_detector_service.dart';
import 'recognition_service.dart';
import 'sync_service.dart';
import 'secure_key_service.dart'; // <<< AÑADIDO: Servicio de clave segura >>>

class ServiceLocator {
  static SharedPreferences? _prefs;
  static FaceDetectorService? _faceDetectorService;
  static EmbeddingService? _embeddingService;
  static RecognitionService? _recognitionService;
  static AttendanceService? _attendanceService;
  static SyncService? _syncService;
  
  // <<< AÑADIDO: Gestión de la clave de cifrado >>>
  static SecureKeyService? _secureKeyService;
  static String? _dbKey;

  static Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    
    // 1. OBTENER CLAVE DE CIFRADO PRIMERO (Usando Secure Storage)
    _secureKeyService ??= SecureKeyService();
    _dbKey = await _secureKeyService!.getOrCreateEncryptionKey();

    _faceDetectorService ??= FaceDetectorService();
    _embeddingService ??= EmbeddingService();

    // 2. Inicializar BD cifrada (RecognitionService)
    // Se inicializa primero y se le pasa la clave para abrir la BD cifrada
    _recognitionService ??= RecognitionService(_prefs!, _dbKey!);
    await _recognitionService!.init();

    // 3. Inicializar Sync y Attendance (que usan la BD)
    _attendanceService ??= AttendanceService(_prefs!);
    await _attendanceService!.init(); 

    _syncService ??= SyncService();
    await _syncService!.init();
    
    // 4. Carga del modelo TFLite (Lógica original, mejorando la robustez)
    // Aseguramos que la carga del modelo TFLite vaya al final, después de las llamadas nativas de BD.
    if (!(_embeddingService?.isLoaded ?? false)) {
      final String? path = _prefs!.getString('custom_model_path');
      if (path != null && path.isNotEmpty) {
        // Intenta cargar modelo custom guardado por el usuario
        await _embeddingService!.loadModelFromFile(path);
      }
    }
    
    // Si aún no está cargado, intenta los assets (priorizando el 128d)
    if (!(_embeddingService?.isLoaded ?? false)) {
      await _embeddingService!.loadModelFromAsset('assets/models/mobilefacenet_112x112_128d.tflite');
    }

    // Fallback al modelo anterior (si existiera)
    if (!(_embeddingService?.isLoaded ?? false)) {
      await _embeddingService!.loadModelFromAsset('assets/models/mobilefacenet.tflite');
    }
    
    // Si después de todo, el modelo falla la carga, imprime el error final.
    if (!(_embeddingService?.isLoaded ?? false)) {
        print("ServiceLocator: ERROR CRÍTICO: El modelo TFLite no pudo ser cargado después de todos los intentos. Último error: ${_embeddingService?.lastError}");
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
}