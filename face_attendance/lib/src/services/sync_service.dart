import 'dart:async'; // Para Streams y Timers
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

  // Nombres de las tablas (deben coincidir con recognition_service.dart)
  static const String _tableAttendance = 'registros_asistencia';
  // ===================================================================
  // ====================== SECCIÓN MODIFICADA 1 =======================
  // ===================================================================
  // Añadir nombre de la tabla de empleados para poder consultarla
  static const String _tableEmployees = 'empleados';
  // ===================================================================
  // ==================== FIN DE SECCIÓN MODIFICADA 1 ==================
  // ===================================================================

  // URL para Webhook (o la API real de SIOMA)
  final String _apiUrl = 'https://webhook.site/60abfcfa-fbe3-4012-88b8-2ac35df2dc4c'; // URL de destino

  // Inicialización del servicio
  Future<void> init() async {
    _db = ServiceLocator.recognition.database; // Obtener BD
    _connectivitySubscription = Connectivity().onConnectivityChanged.listen(_handleConnectivityChange); // Escuchar red
    print('SyncService: Iniciado. Intentando sincronización inicial.');
    await _attemptSync(); // Sincronizar al inicio
  }

  // Liberar recursos
  void dispose() {
    _connectivitySubscription?.cancel();
  }

  // Manejador de cambios de red
  void _handleConnectivityChange(List<ConnectivityResult> results) {
    final bool hasConnection = results.contains(ConnectivityResult.mobile) || results.contains(ConnectivityResult.wifi);
    if (hasConnection) {
      print('SyncService: Conexión detectada. Intentando sincronizar...');
      _attemptSync();
    } else {
      print('SyncService: Sin conexión.');
    }
  }

  // Orquestador de la sincronización
  Future<void> _attemptSync() async {
    if (_isSyncing || _db == null) return; // Evitar ejecuciones paralelas o sin BD
    _isSyncing = true;
    print('SyncService: Iniciando ciclo de sincronización.');
    try {
      final List<Map<String, Object?>> pendingRecords = await _getPendingRecords();
      print('SyncService: Se encontraron ${pendingRecords.length} registros pendientes.');
      if (pendingRecords.isEmpty) {
        _isSyncing = false;
        return;
      }
      for (final record in pendingRecords) {
        final int recordId = record['id_registro'] as int;
        print('SyncService: Procesando registro ID: $recordId');
        // MODIFICADO: Ahora _sendRecordToApi puede fallar si no encuentra al empleado
        final bool success = await _sendRecordToApi(record);
        if (success) {
          await _markRecordAsSynced(recordId);
          print('SyncService: Registro ID: $recordId marcado como sincronizado.');
        } else {
          print('SyncService: Falló el envío del registro ID: $recordId (podría ser error de red o empleado no encontrado). Se reintentará.');
        }
      }
      print('SyncService: Ciclo de sincronización completado.');
    } catch (e) {
      print('SyncService: Error general durante la sincronización: $e');
    } finally {
      _isSyncing = false;
    }
  }

  // Obtener registros pendientes (sin cambios)
  Future<List<Map<String, Object?>>> _getPendingRecords({int limit = 50}) async {
    return await _db!.query(
      _tableAttendance,
      where: 'sincronizado = ?', whereArgs: [0],
      limit: limit, orderBy: 'fecha_hora ASC',
    );
  }

  // ===================================================================
  // ====================== SECCIÓN MODIFICADA 2 =======================
  // ===================================================================
  // Función para enviar UN registro a la API (AHORA BUSCA NOMBRE Y DOCUMENTO)
  Future<bool> _sendRecordToApi(Map<String, Object?> record) async {
    try {
      // 1. Obtener el ID interno del empleado desde el registro de asistencia
      final int empleadoId = record['id_empleado'] as int;

      // 2. Buscar Nombre y Documento (Cédula) en la tabla 'empleados'
      final List<Map<String, Object?>> employeeData = await _db!.query(
        _tableEmployees,
        columns: ['nombre', 'documento'], // Solo necesitamos estas columnas
        where: 'id = ?', // Buscar por el ID interno
        whereArgs: [empleadoId],
        limit: 1, // Solo esperamos un resultado
      );

      // Si por alguna razón no encontramos al empleado (muy raro), fallamos el envío
      if (employeeData.isEmpty) {
        print('SyncService: Error - No se encontró empleado con ID: $empleadoId para el registro ${record['id_registro']}.');
        return false; // Indicar fallo para que se reintente luego
      }

      // Extraer los datos del empleado
      final String? nombreEmpleado = employeeData.first['nombre'] as String?;
      final String? documentoEmpleado = employeeData.first['documento'] as String?; // Esta es la Cédula

      // 3. Preparar los datos en formato JSON CON LOS DATOS CORRECTOS
      final body = jsonEncode({
        // Usar los nombres de campo que SIOMA espera:
        'documento': documentoEmpleado ?? '', // Enviar cédula (o vacío si no existe)
        'nombre': nombreEmpleado ?? '',       // Enviar nombre (o vacío si no existe)
        'fecha_hora_evento': record['fecha_hora'], // Fecha/Hora del registro
        'tipo_evento': record['tipo_evento'],     // 'entrada' o 'salida'
        // 'id_dispositivo': record['id_dispositivo'], // Descomenta si SIOMA también necesita esto
      });

      print('SyncService: Enviando a API: POST $_apiUrl');
      print('SyncService: Cuerpo JSON: $body'); // Ahora mostrará nombre y documento

      // 4. Hacer la petición POST a la API (sin cambios aquí)
      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json; charset=UTF-8',
          // 'Authorization': 'Bearer TU_TOKEN_AQUI', // Si necesitas autenticación
        },
        body: body,
      ).timeout(const Duration(seconds: 20));

      print('SyncService: Respuesta de API [${response.statusCode}] para registro ${record['id_registro']}: ${response.body}');

      // 5. Verificar si la respuesta fue exitosa (código 2xx)
      return response.statusCode >= 200 && response.statusCode < 300;

    } catch (e) {
      // Capturar errores de red, timeouts, o errores buscando al empleado
      print('SyncService: Error procesando/enviando registro ${record['id_registro']}: $e');
      return false; // Indicar que el envío falló
    }
  }
  // ===================================================================
  // ==================== FIN DE SECCIÓN MODIFICADA 2 ==================
  // ===================================================================

  // Marcar registro como sincronizado (sin cambios)
  Future<void> _markRecordAsSynced(int recordId) async {
    await _db!.update(
      _tableAttendance, {'sincronizado': 1},
      where: 'id_registro = ?', whereArgs: [recordId],
    );
  }
}