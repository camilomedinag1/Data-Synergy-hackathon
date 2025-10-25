import 'dart:math';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sql;
// import 'package:path/path.dart' as p; // <-- ELIMINADO
import 'locator.dart'; // <-- AÑADIDO

class AttendanceService {
  AttendanceService(this._prefs);

  static const String _kDeviceKey = 'device_id_v1';
  final SharedPreferences _prefs;
  sql.Database? _db;

  // static const String _dbName = ...; // <-- ELIMINADO
  static const String _table = 'registros_asistencia';

  // ===========================================================================
  // ========================= SECCIÓN MODIFICADA ============================
  // ===========================================================================
  // Esta función ahora solo obtiene la conexión de la base de datos
  // que 'RecognitionService' ya abrió.
  Future<void> init() async {
    if (_db != null) return;
    _db = ServiceLocator.recognition.database;
  }

  // La función '_ensureTable' se ha eliminado por completo.
  // ===========================================================================
  // ======================= FIN DE SECCIÓN MODIFICADA =======================
  // ===========================================================================

  Future<String> _getOrCreateDeviceId() async {
    String? id = _prefs.getString(_kDeviceKey);
    if (id != null && id.isNotEmpty) return id;
    // Generar ID simple estable
    final int rand = DateTime.now().millisecondsSinceEpoch ^ Random().nextInt(1 << 31);
    id = 'dev-${rand.toRadixString(36)}';
    await _prefs.setString(_kDeviceKey, id);
    return id;
  }

  Future<void> registerIngress(String personId) async {
    await _append('entrada', personId);
  }

  Future<void> registerEgress(String personId) async {
    await _append('salida', personId);
  }

  Future<List<Map<String, Object?>>> readLog({int limit = 100}) async {
    // Esta lógica ahora funciona, porque llamará a nuestro nuevo 'init()'
    final db = _db; if (db == null) { await init(); }
    final sql.Database useDb = _db!;
    return await useDb.query(_table, orderBy: 'fecha_hora DESC', limit: limit);
  }

  Future<void> _append(String type, String personId, {bool validated = true, String? notes}) async {
    // Esta lógica ahora funciona, porque llamará a nuestro nuevo 'init()'
    final db = _db; if (db == null) { await init(); }
    final sql.Database useDb = _db!;
    final String deviceId = await _getOrCreateDeviceId();
    final int empleadoId = int.tryParse(personId) ?? -1;
    if (empleadoId <= 0) return;
    await useDb.insert(
      _table,
      <String, Object?>{
        'id_empleado': empleadoId,
        'id_dispositivo': deviceId,
        'tipo_evento': type,
        'fecha_hora': DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now()),
        'validado_biometricamente': validated ? 1 : 0,
        'observaciones': notes,
      },
    );
  }
}