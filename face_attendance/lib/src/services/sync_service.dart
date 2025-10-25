
import 'package:flutter/foundation.dart';import 'dart:async'; // Para Streams y Timers
import 'dart:convert'; // Para codificar a JSON (jsonEncode)

import 'package:connectivity_plus/connectivity_plus.dart'; // Para detectar conexión
import 'package:http/http.dart' as http; // Para hacer peticiones web (envío API)
import 'package:sqflite_sqlcipher/sqflite.dart' as sql;

import 'locator.dart'; // Para obtener la conexión a la BD centralizada

class SyncService {
  SyncService() {
    // Constructor vacío
  }

  sql.Database? _db; // Variable para la conexión a la BD
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription; // Listener de red
  bool _isSyncing = false; // Bandera anti-duplicados

  // Nombres de las tablas
  static const String _tableAttendance = 'registros_asistencia';
  static const String _tableEmployees = 'empleados';

  final String _apiUrl = 'https://webhook.site/60abfcfa-fbe3-4012-88b8-2ac35df2dc4c';

  Future<void> init() async {
    _db = ServiceLocator.recognition.database;
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_handleConnectivityChange);
    print('SyncService: Iniciado. Intentando sincronización inicial.');
    await _attemptSync();
  }

  void dispose() {
    _connectivitySubscription?.cancel();
  }

  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final bool hasConnection = results.contains(ConnectivityResult.mobile) || results.contains(ConnectivityResult.wifi);
    if (hasConnection) {
      print('SyncService: Conexión detectada. Intentando sincronizar...');
      _attemptSync();
    } else {
      print('SyncService: Sin conexión.');
    }
  }

  Future<void> _attemptSync() async {
    if (_isSyncing || _db == null) return;
    _isSyncing = true;
    print('SyncService: Iniciando ciclo de sincronización.');
    try {
      final List<Map<String, Object?>> pendingRecords = await _getPendingRecords();
      print('SyncService: Se encontraron ${pendingRecords.length} registros pendientes.');
      if (pendingRecords.isEmpty) {
        _isSyncing = false;
        // <<< CAMBIO: Notificar a los listeners que ya no hay pendientes >>>
        _notifyListeners(); // Asegura que el icono se actualice a verde
        return;
      }
      for (final record in pendingRecords) {
        final int recordId = record['id_registro'] as int;
        print('SyncService: Procesando registro ID: $recordId');
        final bool success = await _sendRecordToApi(record);
        if (success) {
          await _markRecordAsSynced(recordId);
          print('SyncService: Registro ID: $recordId marcado como sincronizado.');
        } else {
          print('SyncService: Falló el envío del registro ID: $recordId. Se reintentará.');
        }
        // <<< CAMBIO: Notificar después de procesar cada registro >>>
        _notifyListeners(); // Actualiza el contador mientras sincroniza
      }
      print('SyncService: Ciclo de sincronización completado.');
    } catch (e) {
      print('SyncService: Error general durante la sincronización: $e');
    } finally {
      _isSyncing = false;
       // <<< CAMBIO: Notificar al finalizar (incluso si hubo error) >>>
      _notifyListeners(); // Asegura estado final correcto
    }
  }

  Future<List<Map<String, Object?>>> _getPendingRecords({int limit = 50}) async {
    // <<< CAMBIO: Asegurarse que _db no sea null antes de usarlo >>>
    if (_db == null) return [];
    return await _db!.query(
      _tableAttendance,
      where: 'sincronizado = ?', whereArgs: [0],
      limit: limit, orderBy: 'fecha_hora ASC',
    );
  }

  Future<bool> _sendRecordToApi(Map<String, Object?> record) async {
     // <<< CAMBIO: Asegurarse que _db no sea null antes de usarlo >>>
    if (_db == null) return false;
    try {
      final int empleadoId = record['id_empleado'] as int;
      final List<Map<String, Object?>> employeeData = await _db!.query(
        _tableEmployees,
        columns: ['nombre', 'documento'],
        where: 'id = ?',
        whereArgs: [empleadoId],
        limit: 1,
      );

      if (employeeData.isEmpty) {
        print('SyncService: Error - No se encontró empleado con ID: $empleadoId para el registro ${record['id_registro']}.');
        return false;
      }

      final String? nombreEmpleado = employeeData.first['nombre'] as String?;
      final String? documentoEmpleado = employeeData.first['documento'] as String?;

      final body = jsonEncode({
        'documento': documentoEmpleado ?? '',
        'nombre': nombreEmpleado ?? '',
        'fecha_hora_evento': record['fecha_hora'],
        'tipo_evento': record['tipo_evento'],
      });

      print('SyncService: Enviando a API: POST $_apiUrl');
      print('SyncService: Cuerpo JSON: $body');

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {'Content-Type': 'application/json; charset=UTF-8'},
        body: body,
      ).timeout(const Duration(seconds: 20));

      print('SyncService: Respuesta de API [${response.statusCode}] para registro ${record['id_registro']}: ${response.body}');
      return response.statusCode >= 200 && response.statusCode < 300;

    } catch (e) {
      print('SyncService: Error procesando/enviando registro ${record['id_registro']}: $e');
      return false;
    }
  }

  Future<void> _markRecordAsSynced(int recordId) async {
     // <<< CAMBIO: Asegurarse que _db no sea null antes de usarlo >>>
    if (_db == null) return;
    await _db!.update(
      _tableAttendance, {'sincronizado': 1},
      where: 'id_registro = ?', whereArgs: [recordId],
    );
  }

  // --- NUEVO CÓDIGO PARA EL INDICADOR ---

  // Lista de funciones que quieren ser notificadas de cambios en el contador
  final List<VoidCallback> _listeners = [];

  // Método para que otros (HomeScreen) se suscriban a los cambios
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  // Método para que otros se desuscriban
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  // Notifica a todos los listeners suscritos
  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  // Devuelve la cantidad ACTUAL de registros pendientes
  Future<int> getPendingRecordCount() async {
    if (_db == null) return 0;
    try {
      // Usamos `rawQuery` para simplificar la obtención del COUNT
      final List<Map<String, Object?>> result = await _db!.rawQuery(
        'SELECT COUNT(*) as count FROM $_tableAttendance WHERE sincronizado = 0'
      );
      return (result.first['count'] as int?) ?? 0;
    } catch (e) {
      print('SyncService: Error contando registros pendientes: $e');
      return 0;
    }
  }
  // --- FIN NUEVO CÓDIGO ---
}