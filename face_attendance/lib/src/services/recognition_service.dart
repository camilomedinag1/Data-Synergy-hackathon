// ****** INICIO DEL CÓDIGO CORREGIDO para recognition_service.dart ******
import 'dart:convert';
import 'dart:io';
import 'dart:math'; // Asegúrate que esté al inicio
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/recognized_person.dart';

class RecognitionService {
  RecognitionService(this._prefs);

  final SharedPreferences _prefs;
  Database? _db;
  Database get database => _db!;

  static const String _dbName = 'reconocimiento_biometrico.sqlite';
  static const String _tableEmployees = 'empleados';
  static const String _tableBiometrics = 'datos_biometricos';
  static const String _tableAttendance = 'registros_asistencia';

  List<_CacheEntry>? _cache;

  String get cacheStatus => _cache == null ? 'No inicializado' : '${_cache!.length} entradas';

  Future<void> init() async {
    if (_db != null) return;
    final String dbDir = await getDatabasesPath();
    final String path = p.join(dbDir, _dbName);
    _db = await openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createAllTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute('''
              ALTER TABLE $_tableAttendance
              ADD COLUMN sincronizado INTEGER DEFAULT 0
            ''');
             print('RecognitionService: Columna "sincronizado" añadida.');
          } catch (e) {
             print('RecognitionService: WARN - Error añadiendo columna "sincronizado": $e');
          }
        }
      },
    );
    await _warmCache();
  }

  Future<void> _createAllTables(Database db) async {
     print('RecognitionService: Creando tablas (onCreate)...');
    await db.execute(''' CREATE TABLE $_tableEmployees (id INTEGER PRIMARY KEY AUTOINCREMENT, nombre TEXT NOT NULL, documento TEXT UNIQUE, cargo TEXT, telefono TEXT, imagePath TEXT) ''');
    await db.execute(''' CREATE TABLE $_tableBiometrics (id_biometrico INTEGER PRIMARY KEY AUTOINCREMENT, id_empleado INTEGER NOT NULL, tipo_biometria TEXT NOT NULL DEFAULT 'rostro', vector_biometrico BLOB, fecha_registro TEXT DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY(id_empleado) REFERENCES $_tableEmployees(id) ON DELETE CASCADE) ''');
    await db.execute(''' CREATE TABLE $_tableAttendance (id_registro INTEGER PRIMARY KEY AUTOINCREMENT, id_empleado INTEGER NOT NULL, id_dispositivo TEXT NOT NULL, tipo_evento TEXT NOT NULL, fecha_hora TEXT DEFAULT CURRENT_TIMESTAMP, validado_biometricamente INTEGER DEFAULT 1, sincronizado INTEGER DEFAULT 0, observaciones TEXT) ''');
     print('RecognitionService: Tablas creadas.');
  }

 // --- VERSIÓN CORREGIDA (DE NUEVO) DE _blobToVector ---
  List<double>? _blobToVector(Uint8List blob, int empleadoId) {
      const int expectedBytes = 1024; // 128 doubles * 8 bytes/double
      const int vectorLength = 128;
      print('RecognitionService: [LOAD BLOB] BLOB leído para ID $empleadoId tiene bytes: ${blob.lengthInBytes}');

      if (blob.lengthInBytes == expectedBytes) {
          try {
              // *** MÉTODO CORREGIDO: Usando ByteData para leer Floats ***
              // 1. Obtener una vista ByteData del buffer del blob
              //    Aseguramos leer desde el inicio (offset 0) hasta el final (expectedBytes)
              ByteData byteData = blob.buffer.asByteData(blob.offsetInBytes, blob.lengthInBytes);

              // 2. Crear la lista resultado
              List<double> vectorResult = List<double>.filled(vectorLength, 0.0);

              // 3. Leer cada número Float64 (8 bytes) del ByteData
              for (int i = 0; i < vectorLength; i++) {
                  // Calculamos el offset en bytes: i * 8 (porque cada double ocupa 8 bytes)
                  // Usamos Endian.host para que funcione en distintas arquitecturas
                  vectorResult[i] = byteData.getFloat64(i * 8, Endian.host);
              }

              print('RecognitionService: [LOAD BLOB] Vector reconstruido para ID $empleadoId tiene longitud: ${vectorResult.length}');

              // Verificación extra (NaN/Infinito)
              bool isValid = true;
              for(double val in vectorResult) {
                 if (val.isNaN || val.isInfinite) { isValid = false; break; }
              }
              if (!isValid) {
                 print('RecognitionService: ERROR [LOAD BLOB] Vector reconstruido contiene NaN/Infinito para ID $empleadoId.');
                 return null;
              }

              return vectorResult;
          } catch (e) {
              print('RecognitionService: ERROR [LOAD BLOB] Convirtiendo BLOB (ByteData) a List<double> para ID $empleadoId: $e');
              return null;
          }
      } else {
          print('RecognitionService: WARN [LOAD BLOB] Vector biométrico tamaño incorrecto para ID $empleadoId. Esperado: $expectedBytes, Obtenido: ${blob.lengthInBytes}');
          return null;
      }
  }
  Future<void> _warmCache() async {
    print('RecognitionService: Iniciando _warmCache...');
    if (_db == null) { /*...*/ _cache = []; return; } // Código igual
    final Database useDb = _db!;
    final String sql = ''' SELECT b.id_empleado, b.vector_biometrico, e.nombre, e.documento, e.cargo, e.telefono, e.imagePath FROM $_tableBiometrics b JOIN $_tableEmployees e ON e.id = b.id_empleado GROUP BY b.id_empleado ''';
    try {
      final List<Map<String, Object?>> rows = await useDb.rawQuery(sql);
      final List<_CacheEntry> list = <_CacheEntry>[];
      print('RecognitionService: _warmCache - ${rows.length} filas encontradas.');
      for (final r in rows) {
        final int empId = r['id_empleado'] as int;
        final dynamic vectorBlob = r['vector_biometrico'];
        List<double>? vector; // Puede ser null si falla la conversión

        if (vectorBlob is Uint8List) {
           // *** USAMOS LA FUNCIÓN CORREGIDA ***
           vector = _blobToVector(vectorBlob, empId);
        } else {
           print('RecognitionService: WARN - [WARM CACHE] Vector no es Uint8List para ID $empId.');
        }

        // Solo añadir al caché si el vector se pudo leer correctamente
        if (vector != null) {
           list.add(
             _CacheEntry(
               idEmpleado: empId, vector: vector,
               nombre: r['nombre'] as String?, documento: r['documento'] as String?,
               cargo: r['cargo'] as String?, telefono: r['telefono'] as String?,
               imagePath: r['imagePath'] as String?,
             ),
           );
        } else {
           print('RecognitionService: WARN - [WARM CACHE] No se añadió entrada para ID $empId por vector inválido.');
        }
      }
      _cache = list;
      print('RecognitionService: _warmCache completado. ${_cache?.length ?? 0} rostros cargados.');
    } catch (e) { /*...*/ _cache = []; } // Código igual
  }

  Future<int> upsertEmployee({ required String nombre, String? documento, String? cargo, String? telefono, String? imagePath, }) async {
     // ... (Sin cambios aquí) ...
     final db = _db; if (db == null) { await init(); }
    final Database useDb = _db!;
    int? foundId;
    if (documento != null && documento.isNotEmpty) {
      final rows = await useDb.query( _tableEmployees, columns: ['id'], where: 'documento = ?', whereArgs: [documento], limit: 1, );
      if (rows.isNotEmpty) { foundId = rows.first['id'] as int; await useDb.update( _tableEmployees, {'nombre': nombre, 'cargo': cargo, 'telefono': telefono, 'imagePath': imagePath}, where: 'id = ?', whereArgs: [foundId], ); print('RecognitionService: Empleado actualizado (ID: $foundId)'); }
    }
    if (foundId == null) { foundId = await useDb.insert( _tableEmployees, {'nombre': nombre, 'documento': documento, 'cargo': cargo, 'telefono': telefono, 'imagePath': imagePath}, conflictAlgorithm: ConflictAlgorithm.ignore, ); print('RecognitionService: Nuevo empleado insertado (ID: $foundId)'); }
    return foundId ?? -1;
  }

  Future<void> saveIdentityForEmployee({ required int empleadoId, required List<double> embedding, }) async {
    final db = _db; if (db == null) { await init(); }
    final Database useDb = _db!;

    print('RecognitionService: [SAVE] Embedding recibido para ID $empleadoId tiene longitud: ${embedding.length}'); // <-- Mantenemos print

    // --- CORRECCIÓN EN LA ESCRITURA DEL BLOB ---
    Uint8List blob;
    try {
        // Creamos Float64List y OBTENEMOS SU VISTA Uint8List
        final Float64List vec64 = Float64List.fromList(embedding);
        // *** LA CORRECCIÓN CLAVE ESTÁ AQUÍ ***
        // Usamos buffer.asUint8List asegurándonos de copiar los bytes exactos
        blob = vec64.buffer.asUint8List(vec64.offsetInBytes, vec64.lengthInBytes);
        print('RecognitionService: [SAVE] BLOB generado para ID $empleadoId tiene longitud en bytes: ${blob.lengthInBytes}'); // <-- Mantenemos print (Debe ser 1024)

         // Doble chequeo por si acaso
         if (blob.lengthInBytes != 1024) {
            print('RecognitionService: ERROR CRÍTICO [SAVE] - BLOB generado tiene tamaño incorrecto ${blob.lengthInBytes}. NO SE GUARDARÁ.');
            return; // No guardar si el blob es incorrecto
         }

    } catch (e) {
        print('RecognitionService: ERROR CRÍTICO [SAVE] - Convirtiendo embedding a BLOB para ID $empleadoId: $e');
        return; // No continuar si falla la conversión
    }

    await useDb.insert(
      _tableBiometrics,
      {'id_empleado': empleadoId, 'tipo_biometria': 'rostro', 'vector_biometrico': blob},
    );
     print('RecognitionService: [SAVE] Vector biométrico guardado para empleado ID: $empleadoId');

    // Refrescar caché (ahora usa la lectura corregida)
    await _updateCacheForEmployee(empleadoId);
  }

 Future<void> _updateCacheForEmployee(int empleadoId) async {
    if (_db == null) return;
    final rows = await _db!.query(_tableEmployees, where: 'id = ?', whereArgs: [empleadoId], limit: 1);
    if (rows.isEmpty) return;
    final employeeData = rows.first;
    final bioRows = await _db!.query(_tableBiometrics, where: 'id_empleado = ?', whereArgs: [empleadoId], orderBy: 'fecha_registro DESC', limit: 1);
    if (bioRows.isEmpty) return;

    final dynamic vectorBlob = bioRows.first['vector_biometrico'];
    List<double>? vector; // Puede ser null
    if (vectorBlob is Uint8List) {
        // *** USAMOS LA FUNCIÓN CORREGIDA ***
        vector = _blobToVector(vectorBlob, empleadoId);
    }

    if (vector != null) { // Solo actualizar si el vector es válido
       final entry = _CacheEntry( idEmpleado: empleadoId, vector: vector, nombre: employeeData['nombre'] as String?, documento: employeeData['documento'] as String?, cargo: employeeData['cargo'] as String?, telefono: employeeData['telefono'] as String?, imagePath: employeeData['imagePath'] as String?, );
       _cache ??= <_CacheEntry>[];
       final idx = _cache!.indexWhere((e) => e.idEmpleado == empleadoId);
       if (idx >= 0) { _cache![idx] = entry; print('RecognitionService: Entrada de caché actualizada para ID: $empleadoId'); }
       else { _cache!.add(entry); print('RecognitionService: Nueva entrada de caché añadida para ID: $empleadoId'); }
    } else { print('RecognitionService: WARN - No se pudo actualizar caché para ID $empleadoId, vector inválido.'); }
 }


  Future<void> saveIdentity( String personId, List<double> embedding, { String? imagePath, String? name, String? document, String? cargo, String? telefono, }) async {
     // ... (Sin cambios aquí) ...
     print('RecognitionService: saveIdentity llamado con personId: $personId, name: $name, document: $document');
    final String effectiveName = name ?? (document ?? personId);
    final String? effectiveDocument = document?.isNotEmpty == true ? document : null;
    final int empId = await upsertEmployee( nombre: effectiveName, documento: effectiveDocument, cargo: cargo, telefono: telefono, imagePath: imagePath, );
    if (empId != -1) { await saveIdentityForEmployee(empleadoId: empId, embedding: embedding); }
    else { print('RecognitionService: ERROR - Falló upsertEmployee, no se guardó identidad.'); }
  }

  Future<Map<String, dynamic>> readAll() async {
     // ... (Sin cambios aquí) ...
    final db = _db; if (db == null) { await init(); }
    final Database useDb = _db!;
    final List<Map<String, Object?>> rows = await useDb.query(_tableEmployees, orderBy: 'id ASC');
    final Map<String, dynamic> out = <String, dynamic>{};
    for (final r in rows) { final String key = (r['id'] as int).toString(); out[key] = { 'name': r['nombre'], 'document': r['documento'], 'cargo': r['cargo'], 'telefono': r['telefono'], 'imagePath': r['imagePath'], }; }
    return out;
  }

  Future<void> deleteIdentity(String personId, {bool deleteImage = true}) async {
     // ... (Sin cambios aquí) ...
    final db = _db; if (db == null) { await init(); }
    final Database useDb = _db!;
    final int id = int.tryParse(personId) ?? -1;
    if (id <= 0) return;
    String? imagePath;
    try { final rows = await useDb.query(_tableEmployees, where: 'id = ?', whereArgs: [id], limit: 1); if (rows.isNotEmpty) imagePath = rows.first['imagePath'] as String?; } catch (_) {}
    await useDb.delete(_tableBiometrics, where: 'id_empleado = ?', whereArgs: [id]);
    final deletedRows = await useDb.delete(_tableEmployees, where: 'id = ?', whereArgs: [id]);
     print('RecognitionService: Empleado ID $id eliminado ($deletedRows filas afectadas).');
    _cache?.removeWhere((e) => e.idEmpleado == id);
    if (deleteImage && imagePath != null && imagePath.isNotEmpty) { try { final File f = File(imagePath); if (await f.exists()) { await f.delete(); print('RecognitionService: Imagen eliminada: $imagePath'); } } catch (e) { print('RecognitionService: WARN - Error eliminando imagen $imagePath: $e'); } }
  }

  Future<RecognizedPerson?> identify(List<double> embedding, {double threshold = 1.05}) async {
     // ... (Sin cambios aquí) ...
     if (_cache == null) { print('RecognitionService: WARN - identify() llamado antes de que _warmCache completara. Forzando recarga...'); await _warmCache(); if (_cache == null) { print('RecognitionService: ERROR - _warmCache falló repetidamente. No se puede identificar.'); return null; } print('RecognitionService: _warmCache recargado dentro de identify().'); }
     if (_cache!.isEmpty) { print('RecognitionService: identify() - El caché está vacío.'); return null; }
    String? bestId; double bestDist = double.infinity; _CacheEntry? bestMatchEntry;
    for (final _CacheEntry entry in _cache!) {
       if (entry.vector.length != embedding.length) { print('RecognitionService: WARN - Discrepancia longitud. Cache ID ${entry.idEmpleado} (${entry.vector.length}) vs Actual (${embedding.length}). Saltando.'); continue; }
      final double dist = _euclidean(embedding, entry.vector);
      if (dist < bestDist) { bestDist = dist; bestId = entry.idEmpleado.toString(); bestMatchEntry = entry; }
    }
    if (bestId != null && bestMatchEntry != null && bestDist <= threshold) { print('RecognitionService: Identificación exitosa - ID: $bestId (${bestMatchEntry.nombre ?? 'N/A'}), Dist: $bestDist'); return RecognizedPerson( id: bestId, name: bestMatchEntry.nombre, document: bestMatchEntry.documento, cargo: bestMatchEntry.cargo, telefono: bestMatchEntry.telefono, imagePath: bestMatchEntry.imagePath, distance: bestDist, ); }
    else if (bestId != null) { print('RecognitionService: No reconocido - Mejor match ID: $bestId (${bestMatchEntry?.nombre ?? 'N/A'}), Dist: $bestDist'); }
    else { print('RecognitionService: No se encontró ningún match.'); }
    return null;
  }

  double _euclidean(List<double> a, List<double> b) {
     // ... (Sin cambios aquí) ...
    final int n = a.length; double sum = 0.0; for (int i = 0; i < n; i++) { final double d = a[i] - b[i]; sum += d * d; } return sum > 0 ? sqrt(sum) : 0.0;
  }

} // Fin clase RecognitionService


// Clase _CacheEntry (sin cambios)
class _CacheEntry {
   _CacheEntry({ required this.idEmpleado, required this.vector, this.nombre, this.documento, this.cargo, this.telefono, this.imagePath, });
   final int idEmpleado; final List<double> vector; final String? nombre; final String? documento; final String? cargo; final String? telefono; final String? imagePath;
}
// ****** FIN DEL CÓDIGO CORREGIDO para recognition_service.dart ******