// ****** CÓDIGO FINAL PARA recognition_service.dart ******
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui'; 

import 'package:shared_preferences/shared_preferences.dart';
// <<< CAMBIO CRÍTICO: Usar alias para SQLCipher >>>
import 'package:sqflite_sqlcipher/sqflite.dart' as sql;
import 'package:path/path.dart' as p;

import '../models/recognized_person.dart';

class RecognitionService {
  // Constructor acepta la clave de cifrado
  RecognitionService(this._prefs, this._encryptionKey);

  final SharedPreferences _prefs;
  final String _encryptionKey;
  sql.Database? _db;
  sql.Database get database => _db!; // Tipo de retorno ajustado

  static const String _dbName = 'reconocimiento_biometrico.sqlite';
  static const String _tableEmployees = 'empleados';
  static const String _tableBiometrics = 'datos_biometricos';
  static const String _tableAttendance = 'registros_asistencia';

  List<_CacheEntry>? _cache;

  String get cacheStatus => _cache == null ? 'No inicializado' : '${_cache!.length} entradas';

  // --- Conversión de BLOB (lógica final corregida) ---
  List<double>? _blobToVector(Uint8List blob, int empleadoId) {
      const int expectedBytes = 1024;
      const int vectorLength = 128;

      if (blob.lengthInBytes == expectedBytes) {
          try {
              ByteData byteData = blob.buffer.asByteData(blob.offsetInBytes, blob.lengthInBytes);
              List<double> vectorResult = List<double>.filled(vectorLength, 0.0);

              for (int i = 0; i < vectorLength; i++) {
                  vectorResult[i] = byteData.getFloat64(i * 8, Endian.host);
              }
              return vectorResult;
          } catch (e) {
              print('RecognitionService: ERROR [LOAD BLOB] Convirtiendo BLOB a Float64List para ID $empleadoId: $e');
              return null;
          }
      }
      return null;
  }
  // ====================================================================================

  Future<void> init() async {
    if (_db != null) return;
    
    // <<< CORRECCIÓN: Usar sql.getDatabasesPath() >>>
    final String dbDir = await sql.getDatabasesPath(); 
    final String path = p.join(dbDir, _dbName);
    
    // <<< CORRECCIÓN: Usar sql.openDatabase() y password >>>
    _db = await sql.openDatabase(
      path,
      version: 2,
      onCreate: (db, version) async {
        await _createAllTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          try {
            await db.execute(''' ALTER TABLE $_tableAttendance ADD COLUMN sincronizado INTEGER DEFAULT 0 ''');
            print('RecognitionService: Columna "sincronizado" añadida.');
          } catch (e) {
            print('RecognitionService: WARN - Error añadiendo columna "sincronizado": $e');
          }
        }
      },
      password: _encryptionKey,
    );
    await _warmCache();
  }

  // Creación de tablas con TODOS los nuevos campos
  Future<void> _createAllTables(sql.Database db) async {
     print('RecognitionService: Creando tablas (onCreate)...');
    await db.execute(''' 
      CREATE TABLE $_tableEmployees (
        id INTEGER PRIMARY KEY AUTOINCREMENT, 
        nombre TEXT NOT NULL, 
        documento TEXT UNIQUE, 
        cargo TEXT, 
        telefono TEXT, 
        imagePath TEXT,
        area TEXT, eps TEXT, contacto_emergencia_nombre TEXT,
        contacto_emergencia_telefono TEXT, tipo_sangre TEXT, alergias TEXT
      ) 
    ''');
    await db.execute(''' CREATE TABLE $_tableBiometrics (id_biometrico INTEGER PRIMARY KEY AUTOINCREMENT, id_empleado INTEGER NOT NULL, tipo_biometria TEXT NOT NULL DEFAULT 'rostro', vector_biometrico BLOB, fecha_registro TEXT DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY(id_empleado) REFERENCES $_tableEmployees(id) ON DELETE CASCADE) ''');
    await db.execute(''' CREATE TABLE $_tableAttendance (id_registro INTEGER PRIMARY KEY AUTOINCREMENT, id_empleado INTEGER NOT NULL, id_dispositivo TEXT NOT NULL, tipo_evento TEXT NOT NULL, fecha_hora TEXT DEFAULT CURRENT_TIMESTAMP, validado_biometricamente INTEGER DEFAULT 1, sincronizado INTEGER DEFAULT 0, observaciones TEXT) ''');
     print('RecognitionService: Tablas creadas.');
  }

  // Lógica de carga del caché (multi-vector)
  Future<void> _warmCache() async {
    print('RecognitionService: Iniciando _warmCache...');
    if (_db == null) { /*...*/ _cache = []; return; }
    final sql.Database useDb = _db!;

    final List<Map<String, Object?>> bioRows = await useDb.query(_tableBiometrics);
    final List<Map<String, Object?>> empRows = await useDb.query(_tableEmployees);

    final Map<int, Map<String, Object?>> employeeMap = { for (var row in empRows) (row['id'] as int): row };
    final Map<int, List<List<double>>> groupedVectors = {};

    for (final r in bioRows) {
        final int empId = r['id_empleado'] as int;
        final dynamic vectorBlob = r['vector_biometrico'];

        if (vectorBlob is Uint8List) {
            List<double>? vector = _blobToVector(vectorBlob, empId);
            if (vector != null) { groupedVectors.putIfAbsent(empId, () => []).add(vector); }
        }
    }

    final List<_CacheEntry> list = <_CacheEntry>[];
    for (final empId in groupedVectors.keys) {
        final employeeData = employeeMap[empId];
        if (employeeData != null && groupedVectors[empId]!.isNotEmpty) {
             list.add(
               _CacheEntry(
                 idEmpleado: empId, vectors: groupedVectors[empId]!,
                 nombre: employeeData['nombre'] as String?, documento: employeeData['documento'] as String?,
                 cargo: employeeData['cargo'] as String?, telefono: employeeData['telefono'] as String?,
                 imagePath: employeeData['imagePath'] as String?, area: employeeData['area'] as String?,
                 eps: employeeData['eps'] as String?, contactoNombre: employeeData['contacto_emergencia_nombre'] as String?,
                 contactoTelefono: employeeData['contacto_emergencia_telefono'] as String?, tipoSangre: employeeData['tipo_sangre'] as String?,
                 alergias: employeeData['alergias'] as String?,
               ),
             );
        }
    }

    _cache = list;
    print('RecognitionService: _warmCache completado. ${_cache?.length ?? 0} rostros cargados.');
  }

  // Requisito: Validar que no se pueden registrar dos cédulas iguales.
  Future<bool> checkIfDocumentExists(String document) async {
    final db = _db; if (db == null) { await init(); }
    final rows = await db!.query(
      _tableEmployees, columns: ['id'], where: 'documento = ?', whereArgs: [document], limit: 1,
    );
    return rows.isNotEmpty;
  }
  
  // Función para obtener detalles de empleado por documento (para Escaneo de Emergencia)
  Future<Map<String, dynamic>?> getEmployeeDetailsByDocument(String document) async {
      final db = _db; if (db == null) { await init(); }
      final rows = await db!.query(_tableEmployees, where: 'documento = ?', whereArgs: [document], limit: 1);
      return rows.isNotEmpty ? rows.first.cast<String, dynamic>() : null; 
  }
  
  // Guardado de empleado y sus vectores
  Future<int> upsertEmployee({
    required String nombre, required String documento, 
    String? cargo, String? telefono, String? imagePath,
    String? area, String? eps, String? contactoNombre, String? contactoTelefono, String? tipoSangre, String? alergias,
  }) async {
    final db = _db; if (db == null) { await init(); }
    final sql.Database useDb = _db!;
    
    final data = {
      'nombre': nombre, 'documento': documento, 'cargo': cargo, 'telefono': telefono, 'imagePath': imagePath,
      'area': area, 'eps': eps, 'contacto_emergencia_nombre': contactoNombre, 'contacto_emergencia_telefono': contactoTelefono,
      'tipo_sangre': tipoSangre, 'alergias': alergias,
    };

    final rows = await useDb.query(_tableEmployees, columns: ['id'], where: 'documento = ?', whereArgs: [documento], limit: 1);
    
    if (rows.isNotEmpty) {
      final foundId = rows.first['id'] as int;
      await useDb.update(_tableEmployees, data, where: 'id = ?', whereArgs: [foundId]);
      print('RecognitionService: Empleado actualizado (ID: $foundId) por documento: $documento');
      return foundId;
    } else {
      // <<< CORRECCIÓN: Usar el alias sql.ConflictAlgorithm.fail >>>
      final newId = await useDb.insert(_tableEmployees, data, conflictAlgorithm: sql.ConflictAlgorithm.fail); 
      print('RecognitionService: Nuevo empleado insertado (ID: $newId). Nombre: $nombre, Doc: $documento');
      return newId;
    }
  }

  // Inserta múltiples vectores
  Future<void> saveIdentityWithDetails({ 
    required List<List<double>> embeddings, 
    required String name, required String document,
    String? imagePath, String? cargo, String? telefono,
    String? area, String? eps, String? contactoNombre, String? contactoTelefono, String? tipoSangre, String? alergias,
  }) async {
    final int empId = await upsertEmployee( 
      nombre: name, documento: document, cargo: cargo, telefono: telefono, imagePath: imagePath,
      area: area, eps: eps, contactoNombre: contactoNombre, contactoTelefono: contactoTelefono, tipoSangre: tipoSangre, alergias: alergias,
    );

    if (empId == -1) {
       throw Exception("Fallo al guardar empleado. Documento duplicado o error de BD.");
    }
    
    for (final embedding in embeddings) {
       await _insertBiometricVector(empId, embedding);
    }

    await _updateCacheForEmployee(empId);
  }

  // Lógica de eliminación y lectura (ajustada para el alias sql.)
  Future<void> _insertBiometricVector(int empleadoId, List<double> embedding) async {
      final db = _db; if (db == null) { await init(); }
      final sql.Database useDb = _db!;

      final Float64List vec64 = Float64List.fromList(embedding);
      final Uint8List blob = vec64.buffer.asUint8List(vec64.offsetInBytes, vec64.lengthInBytes);

      if (blob.lengthInBytes != 1024) {
          print('RecognitionService: ERROR CRÍTICO [SAVE] - BLOB generado con ${blob.lengthInBytes} bytes. Omitiendo guardado.');
          return;
      }

      await useDb.insert( _tableBiometrics, {'id_empleado': empleadoId, 'tipo_biometria': 'rostro', 'vector_biometrico': blob}, );
      print('RecognitionService: Vector biométrico guardado para ID: $empleadoId. Longitud: ${embedding.length}');
  }

  Future<void> _updateCacheForEmployee(int empleadoId) async {
    if (_db == null) return;
    final rows = await _db!.query(_tableEmployees, where: 'id = ?', whereArgs: [empleadoId], limit: 1);
    if (rows.isEmpty) return;
    final employeeData = rows.first;
    final bioRows = await _db!.query(_tableBiometrics, where: 'id_empleado = ?', whereArgs: [empleadoId], orderBy: 'fecha_registro DESC');
    
    final List<List<double>> vectors = [];
    for (final row in bioRows) {
        final dynamic vectorBlob = row['vector_biometrico'];
        if (vectorBlob is Uint8List) {
            List<double>? vector = _blobToVector(vectorBlob, empleadoId);
            if (vector != null) { vectors.add(vector); }
        }
    }

    if (vectors.isNotEmpty) {
       final entry = _CacheEntry( 
         idEmpleado: empleadoId, vectors: vectors,
         nombre: employeeData['nombre'] as String?, documento: employeeData['documento'] as String?, 
         cargo: employeeData['cargo'] as String?, telefono: employeeData['telefono'] as String?, 
         imagePath: employeeData['imagePath'] as String?, area: employeeData['area'] as String?,
         eps: employeeData['eps'] as String?, contactoNombre: employeeData['contacto_emergencia_nombre'] as String?,
         contactoTelefono: employeeData['contacto_emergencia_telefono'] as String?, tipoSangre: employeeData['tipo_sangre'] as String?,
         alergias: employeeData['alergias'] as String?,
       );
       _cache ??= <_CacheEntry>[];
       final idx = _cache!.indexWhere((e) => e.idEmpleado == empleadoId);
       if (idx >= 0) { _cache![idx] = entry; print('RecognitionService: Entrada de caché actualizada para ID: $empleadoId (Vectores: ${vectors.length})'); }
       else { _cache!.add(entry); print('RecognitionService: Nueva entrada de caché añadida para ID: $empleadoId (Vectores: ${vectors.length})'); }
    } else { print('RecognitionService: WARN - No se pudo actualizar caché para ID $empleadoId, no se encontraron vectores válidos.'); }
  }


  Future<void> saveIdentity( String personId, List<double> embedding, { String? imagePath, String? name, String? document, String? cargo, String? telefono, }) async {
    print('RecognitionService: saveIdentity (OBSOLETA) llamado. Usar saveIdentityWithDetails.');
    throw UnsupportedError("Usar saveIdentityWithDetails para registro de empleado.");
  }

  Future<List<Map<String, dynamic>>> readAllEmployees() async {
    final db = _db; if (db == null) { await init(); }
    final sql.Database useDb = _db!;
    final List<Map<String, Object?>> rows = await useDb.query(_tableEmployees, orderBy: 'id ASC');
    return rows.map((e) => e.cast<String, dynamic>()).toList();
  }

  Future<void> deleteEmployee(String personId, {bool deleteImage = true}) async {
    final db = _db; if (db == null) { await init(); }
    final sql.Database useDb = _db!;
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
     if (_cache == null) { await _warmCache(); }
     if (_cache!.isEmpty) { print('RecognitionService: identify() - El caché está vacío.'); return null; }
    
    String? bestId; double bestDist = double.infinity; _CacheEntry? bestMatchEntry; 

    for (final _CacheEntry entry in _cache!) { 
       double employeeMinDist = double.infinity;
       
       for (final vector in entry.vectors) { 
           if (vector.length != embedding.length) { continue; } 
           final double dist = _euclidean(embedding, vector);
           if (dist < employeeMinDist) { employeeMinDist = dist; }
       }
       
       if (employeeMinDist < bestDist) {
          bestDist = employeeMinDist;
          bestId = entry.idEmpleado.toString();
          bestMatchEntry = entry;
       }
    }

    if (bestId != null && bestMatchEntry != null && bestDist <= threshold) { 
        print('RecognitionService: Identificación exitosa - ID: $bestId (${bestMatchEntry.nombre ?? 'N/A'}), Dist: $bestDist (Umbral: $threshold)'); 
        return RecognizedPerson( 
          id: bestId, name: bestMatchEntry.nombre, document: bestMatchEntry.documento, cargo: bestMatchEntry.cargo, telefono: bestMatchEntry.telefono, 
          imagePath: bestMatchEntry.imagePath, distance: bestDist, area: bestMatchEntry.area, eps: bestMatchEntry.eps, 
          contactoNombre: bestMatchEntry.contactoNombre, contactoTelefono: bestMatchEntry.contactoTelefono, tipoSangre: bestMatchEntry.tipoSangre, 
          alergias: bestMatchEntry.alergias,
        ); 
    } 
    else if (bestId != null) { print('RecognitionService: No reconocido - Mejor match ID: $bestId (${bestMatchEntry?.nombre ?? 'N/A'}), Dist: $bestDist (Umbral: $threshold)'); }
    else { print('RecognitionService: No se encontró ningún match.'); }
    return null;
  }

  double _euclidean(List<double> a, List<double> b) {
    final int n = a.length; double sum = 0.0; for (int i = 0; i < n; i++) { final double d = a[i] - b[i]; sum += d * d; } return sum > 0 ? sqrt(sum) : 0.0;
  }

} // Fin clase RecognitionService


// Clase _CacheEntry: Almacena lista de vectores y todos los nuevos campos
class _CacheEntry {
  _CacheEntry({ 
    required this.idEmpleado, required this.vectors, 
    this.nombre, this.documento, this.cargo, this.telefono, this.imagePath, 
    this.area, this.eps, this.contactoNombre, this.contactoTelefono, this.tipoSangre, this.alergias,
  });
   final int idEmpleado; 
   final List<List<double>> vectors;
   final String? nombre; final String? documento; final String? cargo; final String? telefono; final String? imagePath;
   final String? area; final String? eps; final String? contactoNombre; final String? contactoTelefono; final String? tipoSangre; final String? alergias;
}
// ****** FIN DEL CÓDIGO FINAL para recognition_service.dart ******