import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:math';

class SecureKeyService {
  // <<< CORRECCIÓN: Eliminar el 'const' del lado derecho >>>
  static final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _keyName = 'db_encryption_key';
  
  // Genera una clave aleatoria fuerte para la base de datos
  String _generateSecureKey() {
    const int length = 32;
    const String charset = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!@#\$%^&*()';
    final Random random = Random.secure();
    final String key = List.generate(length, (_) => charset[random.nextInt(charset.length)]).join();
    return key;
  }

  // Obtiene la clave de cifrado. Si no existe, genera una nueva y la guarda.
  Future<String> getOrCreateEncryptionKey() async {
    String? key = await _storage.read(key: _keyName);

    if (key == null || key.isEmpty) {
      key = _generateSecureKey();
      await _storage.write(key: _keyName, value: key);
      print("SecureKeyService: Nueva clave generada y almacenada de forma segura.");
    } else {
      print("SecureKeyService: Clave de cifrado recuperada de almacenamiento seguro.");
    }

    return key;
  }
}