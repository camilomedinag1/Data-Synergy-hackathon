// Archivo: lib/src/services/auth_service.dart (NUEVO)

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class AuthService {
  // Usamos flutter_secure_storage para guardar el PIN
  static final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const String _pinKey = 'settings_pin_key';

  // Verifica si ya se ha establecido un PIN
  Future<bool> hasPin() async {
    final String? pin = await _storage.read(key: _pinKey);
    return pin != null && pin.isNotEmpty;
  }

  // Guarda un nuevo PIN (solo debe llamarse la primera vez)
  Future<void> setPin(String newPin) async {
    // Podríamos añadir validaciones aquí (ej. longitud mínima)
    if (newPin.isNotEmpty) {
      await _storage.write(key: _pinKey, value: newPin);
      print("AuthService: Nuevo PIN guardado de forma segura.");
    }
  }

  // Verifica si el PIN introducido coincide con el guardado
  Future<bool> verifyPin(String enteredPin) async {
    final String? storedPin = await _storage.read(key: _pinKey);
    return storedPin != null && storedPin == enteredPin;
  }

  // (Opcional) Función para eliminar el PIN si se quisiera implementar
  // Future<void> deletePin() async {
  //   await _storage.delete(key: _pinKey);
  // }
}