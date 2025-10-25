// ****** recognition_service.dart (CON GESTIÓN DE ÁREAS) ******
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_sqlcipher/sqflite.dart' as sql;
import 'package:path/path.dart' as p;

import '../models/recognized_person.dart';

// <<< CAMBIO: Modelo simple para representar un Área >>>
class Area {
  final int id;
  final String nombre;
  Area({required this.id, required this.nombre});

  // Para facilitar el uso en Dropdowns
  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Area && runtimeType == other.runtimeType && id == other.id;
  @override
  int get hashCode => id.hashCode;
  @override
  String toString() => nombre;
}


class RecognitionService {
  RecognitionService(this._prefs, this._encryptionKey);

  final SharedPreferences _prefs;
  final String _encryptionKey;
  sql.Database? _db;
  sql.Database get database => _db!;

  static const String _dbName = 'reconocimiento_biometrico.sqlite';
  static const String _tableEmployees = 'empleados';
  static const String _tableBiometrics = 'datos_biometricos';
  static const String _tableAttendance = 'registros_asistencia';
  // <<< CAMBIO: Nueva tabla para Áreas >>>
  static const String _tableAreas = 'areas';

  List<_CacheEntry>? _cache;

  String get cacheStatus => _cache == null ? 'No inicializado' : '${_cache!.length} entradas';

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
              print('RecognitionService: ERROR [LOAD BLOB] Convirtiendo BLOB para ID $empleadoId: $e');
              return null;
          }
      }
      return null;
  }

  Future<void> init() async {
    if (_db != null) return;

    final String dbDir = await sql.getDatabasesPath();
    final String path = p.join(dbDir, _dbName);

    _db = await sql.openDatabase(
      path,
      // <<< CAMBIO: Incrementar versión para disparar onUpgrade >>>
      version: 3,
      onCreate: (db, version) async {
        // Se llama solo si la BD no existe
        await _createAllTables(db, version);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Se llama si la BD existe pero version es mayor
        print('RecognitionService: Actualizando BD de v$oldVersion a v$newVersion');
        if (oldVersion < 2) {
          // Migración de v1 a v2 (ya la tenías)
          try {
            await db.execute('ALTER TABLE $_tableAttendance ADD COLUMN sincronizado INTEGER DEFAULT 0');
            print('RecognitionService: Migración v1->v2 completada (columna sincronizado).');
          } catch (e) { print('RecognitionService: WARN v1->v2 - Error añadiendo columna sincronizado: $e'); }
        }
        if (oldVersion < 3) {
          // <<< CAMBIO: Migración de v2 a v3 (añadir tabla Areas y modificar Empleados) >>>
          await _migrateV2toV3(db);
        }
        // Puedes añadir más bloques 'if (oldVersion < X)' para futuras migraciones
      },
      password: _encryptionKey,
    );
    await _warmCache(); // Recargar caché con la nueva estructura
  }

  // <<< CAMBIO: Creación de tablas ahora incluye _tableAreas y modifica _tableEmployees >>>
  Future<void> _createAllTables(sql.Database db, int version) async {
     print('RecognitionService: Creando tablas (onCreate) para v$version...');
      // Crear tabla de Áreas primero
      await db.execute('''
        CREATE TABLE $_tableAreas (
          id_area INTEGER PRIMARY KEY AUTOINCREMENT,
          nombre_area TEXT NOT NULL UNIQUE
        )
      ''');
      print('RecognitionService: Tabla $_tableAreas creada.');

      // Crear tabla de Empleados modificada
      await db.execute('''
        CREATE TABLE $_tableEmployees (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          nombre TEXT NOT NULL,
          documento TEXT UNIQUE,
          cargo TEXT,
          telefono TEXT,
          imagePath TEXT,
          eps TEXT, contacto_emergencia_nombre TEXT,
          contacto_emergencia_telefono TEXT, tipo_sangre TEXT, alergias TEXT,
          -- Nueva columna para relacionar con áreas:
          id_area INTEGER,
          FOREIGN KEY(id_area) REFERENCES $_tableAreas(id_area) ON DELETE SET NULL -- Si se borra un área, el empleado queda sin área
        )
      ''');
       print('RecognitionService: Tabla $_tableEmployees creada.');

      // Crear tablas restantes (sin cambios)
      await db.execute(''' CREATE TABLE $_tableBiometrics (id_biometrico INTEGER PRIMARY KEY AUTOINCREMENT, id_empleado INTEGER NOT NULL, tipo_biometria TEXT NOT NULL DEFAULT 'rostro', vector_biometrico BLOB, fecha_registro TEXT DEFAULT CURRENT_TIMESTAMP, FOREIGN KEY(id_empleado) REFERENCES $_tableEmployees(id) ON DELETE CASCADE) ''');
      await db.execute(''' CREATE TABLE $_tableAttendance (id_registro INTEGER PRIMARY KEY AUTOINCREMENT, id_empleado INTEGER NOT NULL, id_dispositivo TEXT NOT NULL, tipo_evento TEXT NOT NULL, fecha_hora TEXT DEFAULT CURRENT_TIMESTAMP, validado_biometricamente INTEGER DEFAULT 1, sincronizado INTEGER DEFAULT 0, observaciones TEXT) ''');
      print('RecognitionService: Tablas $_tableBiometrics y $_tableAttendance creadas.');
  }

  // <<< CAMBIO: Lógica de migración para versión 3 >>>
  Future<void> _migrateV2toV3(sql.Database db) async {
      print('RecognitionService: Iniciando migración v2->v3...');
      try {
          // 1. Crear la nueva tabla de Áreas
          await db.execute('''
            CREATE TABLE $_tableAreas (
              id_area INTEGER PRIMARY KEY AUTOINCREMENT,
              nombre_area TEXT NOT NULL UNIQUE
            )
          ''');
           print('RecognitionService: v2->v3 - Tabla $_tableAreas creada.');

          // 2. Leer las áreas de texto únicas de la tabla empleados existente
          final List<Map<String, Object?>> distinctAreas = await db.query(
              _tableEmployees,
              columns: ['area'],
              distinct: true,
              where: 'area IS NOT NULL AND area != ?', // Ignorar nulos o vacíos
              whereArgs: ['']
          );
           print('RecognitionService: v2->v3 - Se encontraron ${distinctAreas.length} áreas únicas en empleados.');

          // 3. Insertar esas áreas en la nueva tabla _tableAreas
          final Map<String, int> areaNameToIdMap = {}; // Para mapear nombre a ID nuevo
          for (final row in distinctAreas) {
              final String areaName = row['area'] as String;
              if (areaName.isNotEmpty) {
                  try {
                    final int newAreaId = await db.insert(
                        _tableAreas,
                        {'nombre_area': areaName},
                        conflictAlgorithm: sql.ConflictAlgorithm.ignore // Si ya existe (poco probable), ignora
                    );
                    if (newAreaId > 0) {
                      areaNameToIdMap[areaName] = newAreaId;
                       print('RecognitionService: v2->v3 - Área "$areaName" insertada con ID $newAreaId.');
                    }
                  } catch (e) { print('RecognitionService: v2->v3 - Error insertando área "$areaName": $e');}
              }
          }

          // 4. Añadir la nueva columna id_area a la tabla empleados
          //    (SQLite no permite añadir FOREIGN KEY con ALTER TABLE fácilmente, lo omitimos aquí)
          await db.execute('ALTER TABLE $_tableEmployees ADD COLUMN id_area INTEGER');
           print('RecognitionService: v2->v3 - Columna id_area añadida a $_tableEmployees.');

          // 5. Actualizar la columna id_area en empleados basado en el mapeo
          for (final areaName in areaNameToIdMap.keys) {
              final int areaId = areaNameToIdMap[areaName]!;
              try {
                  final int updatedRows = await db.update(
                      _tableEmployees,
                      {'id_area': areaId},
                      where: 'area = ?',
                      whereArgs: [areaName]
                  );
                   print('RecognitionService: v2->v3 - Actualizados $updatedRows empleados para el área "$areaName" (ID $areaId).');
              } catch(e) { print('RecognitionService: v2->v3 - Error actualizando empleados para área "$areaName": $e');}
          }

          // 6. (Opcional pero recomendado) Eliminar la columna antigua 'area'
          //    Esto es complejo en SQLite. Una forma segura es crear tabla temporal, copiar, borrar, renombrar.
          //    Por rapidez, la dejaremos por ahora, pero no la usaremos más.
           print('RecognitionService: v2->v3 - Columna "area" antigua no se eliminará por ahora.');
           print('RecognitionService: Migración v2->v3 completada.');

      } catch (e) {
          print('RecognitionService: ERROR CRÍTICO durante migración v2->v3: $e');
          // Considerar lanzar excepción o manejar el fallo
      }
  }


  // <<< CAMBIO: _warmCache ahora une con Áreas >>>
  Future<void> _warmCache() async {
    print('RecognitionService: Iniciando _warmCache (v3)...');
    if (_db == null) { _cache = []; return; }
    final sql.Database useDb = _db!;

    // Obtener empleados CON el nombre del área usando JOIN
    final List<Map<String, Object?>> empRows = await useDb.rawQuery('''
      SELECT e.*, a.nombre_area
      FROM $_tableEmployees e
      LEFT JOIN $_tableAreas a ON e.id_area = a.id_area
    ''');

    final List<Map<String, Object?>> bioRows = await useDb.query(_tableBiometrics);

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
                 imagePath: employeeData['imagePath'] as String?,
                 // <<< CAMBIO: Leer el nombre del área del JOIN >>>
                 area: employeeData['nombre_area'] as String?, // Leemos 'nombre_area'
                 eps: employeeData['eps'] as String?, contactoNombre: employeeData['contacto_emergencia_nombre'] as String?,
                 contactoTelefono: employeeData['contacto_emergencia_telefono'] as String?, tipoSangre: employeeData['tipo_sangre'] as String?,
                 alergias: employeeData['alergias'] as String?,
               ),
             );
        }
    }
    _cache = list;
    print('RecognitionService: _warmCache (v3) completado. ${_cache?.length ?? 0} rostros cargados.');
  }


  Future<bool> checkIfDocumentExists(String document) async {
      final db = _db; if (db == null) return false; // Evitar init si solo es una consulta rápida
      final rows = await db.query(_tableEmployees, columns: ['id'], where: 'documento = ?', whereArgs: [document], limit: 1);
      return rows.isNotEmpty;
  }

  Future<Map<String, dynamic>?> getEmployeeDetailsByDocument(String document) async {
      final db = _db; if (db == null) return null;
      // <<< CAMBIO: Usar JOIN para obtener nombre de área >>>
      final rows = await db.rawQuery('''
          SELECT e.*, a.nombre_area
          FROM $_tableEmployees e
          LEFT JOIN $_tableAreas a ON e.id_area = a.id_area
          WHERE e.documento = ?
          LIMIT 1
      ''', [document]);
      return rows.isNotEmpty ? rows.first.cast<String, dynamic>() : null;
  }

  // <<< CAMBIO: Nueva función para obtener o crear un área por nombre >>>
  Future<int?> getOrCreateArea(String areaName) async {
    if (areaName.trim().isEmpty) return null; // No crear áreas vacías
    final db = _db; if (db == null) await init();
    final sql.Database useDb = _db!;

    // Intentar encontrarla primero
    final List<Map<String, Object?>> existing = await useDb.query(
      _tableAreas,
      columns: ['id_area'],
      where: 'nombre_area = ?',
      whereArgs: [areaName.trim()],
      limit: 1,
    );

    if (existing.isNotEmpty) {
      return existing.first['id_area'] as int; // Devolver ID existente
    } else {
      // Si no existe, crearla
      try {
        final int newId = await useDb.insert(
          _tableAreas,
          {'nombre_area': areaName.trim()},
          conflictAlgorithm: sql.ConflictAlgorithm.ignore, // Ignorar si se crea justo ahora por otro proceso
        );
         print('RecognitionService: Nueva área creada: "$areaName" (ID: $newId)');
        return newId > 0 ? newId : null; // Devolver nuevo ID o null si falla la inserción
      } catch (e) {
         print('RecognitionService: Error creando área "$areaName": $e');
         // Podría ser que ya exista (conflictAlgorithm.ignore falló?), intentar leerla de nuevo
         final List<Map<String, Object?>> retryRead = await useDb.query(_tableAreas, columns: ['id_area'], where: 'nombre_area = ?', whereArgs: [areaName.trim()], limit: 1);
         if (retryRead.isNotEmpty) return retryRead.first['id_area'] as int;
         return null; // Falló definitivamente
      }
    }
  }

  // <<< CAMBIO: Nueva función para leer todas las áreas >>>
  Future<List<Area>> getAllAreas() async {
    final db = _db; if (db == null) await init();
    final sql.Database useDb = _db!;
    final List<Map<String, Object?>> rows = await useDb.query(_tableAreas, orderBy: 'nombre_area ASC');
    return rows.map((row) => Area(id: row['id_area'] as int, nombre: row['nombre_area'] as String)).toList();
  }


  // <<< CAMBIO: upsertEmployee ahora usa id_area >>>
  Future<int> upsertEmployee({
    required String nombre, required String documento,
    String? cargo, String? telefono, String? imagePath,
    // Acepta el NOMBRE del área, buscará/creará el ID internamente
    String? areaName,
    String? eps, String? contactoNombre, String? contactoTelefono, String? tipoSangre, String? alergias,
  }) async {
    final db = _db; if (db == null) await init();
    final sql.Database useDb = _db!;

    // Obtener el ID del área
    int? areaId;
    if (areaName != null && areaName.isNotEmpty) {
      areaId = await getOrCreateArea(areaName);
    }

    final data = {
      'nombre': nombre, 'documento': documento, 'cargo': cargo, 'telefono': telefono, 'imagePath': imagePath,
      // 'area': area, // Ya no usamos esta columna
      'id_area': areaId, // Guardamos el ID numérico
      'eps': eps, 'contacto_emergencia_nombre': contactoNombre, 'contacto_emergencia_telefono': contactoTelefono,
      'tipo_sangre': tipoSangre, 'alergias': alergias,
    };

    // Eliminar claves con valores nulos para evitar problemas en UPDATE vs INSERT
    data.removeWhere((key, value) => value == null);

    final rows = await useDb.query(_tableEmployees, columns: ['id'], where: 'documento = ?', whereArgs: [documento], limit: 1);

    if (rows.isNotEmpty) {
      final foundId = rows.first['id'] as int;
      await useDb.update(_tableEmployees, data, where: 'id = ?', whereArgs: [foundId]);
      print('RecognitionService: Empleado actualizado (ID: $foundId), Doc: $documento, AreaID: $areaId');
      return foundId;
    } else {
      try {
        final newId = await useDb.insert(_tableEmployees, data, conflictAlgorithm: sql.ConflictAlgorithm.fail);
        print('RecognitionService: Nuevo empleado insertado (ID: $newId), Nombre: $nombre, Doc: $documento, AreaID: $areaId');
        return newId;
      } catch (e) {
         print('RecognitionService: ERROR insertando empleado (¿Documento duplicado?): $e');
         // Si falla, intentamos leer por documento por si acaso
         final retryRead = await useDb.query(_tableEmployees, columns: ['id'], where: 'documento = ?', whereArgs: [documento], limit: 1);
         if (retryRead.isNotEmpty) return retryRead.first['id'] as int;
         return -1; // Falló la inserción
      }
    }
  }

  // <<< CAMBIO: saveIdentityWithDetails ahora acepta areaName >>>
  Future<void> saveIdentityWithDetails({
    required List<List<double>> embeddings,
    required String name, required String document,
    String? imagePath, String? cargo, String? telefono,
    // Acepta nombre de área
    String? areaName,
    String? eps, String? contactoNombre, String? contactoTelefono, String? tipoSangre, String? alergias,
  }) async {
    final int empId = await upsertEmployee(
      nombre: name, documento: document, cargo: cargo, telefono: telefono, imagePath: imagePath,
      // Pasa el nombre del área
      areaName: areaName,
      eps: eps, contactoNombre: contactoNombre, contactoTelefono: contactoTelefono, tipoSangre: tipoSangre, alergias: alergias,
    );

    if (empId <= 0) { // Comprobar si upsert falló
       throw Exception("Fallo al guardar/actualizar empleado. Documento duplicado o error de BD.");
    }

    // Borrar vectores antiguos ANTES de insertar los nuevos (para evitar acumulación si se re-registra)
    await _db?.delete(_tableBiometrics, where: 'id_empleado = ?', whereArgs: [empId]);
    print('RecognitionService: Vectores biométricos antiguos eliminados para ID: $empId');

    for (final embedding in embeddings) {
       await _insertBiometricVector(empId, embedding);
    }

    await _updateCacheForEmployee(empId); // Actualizar caché con nueva info (incluida área)
  }

  Future<void> _insertBiometricVector(int empleadoId, List<double> embedding) async {
      final db = _db; if (db == null) return; // No intentar init aquí, debe estar listo
      final sql.Database useDb = db;
      // ... (lógica de conversión a BLOB sin cambios) ...
       final Float64List vec64 = Float64List.fromList(embedding);
       final Uint8List blob = vec64.buffer.asUint8List(vec64.offsetInBytes, vec64.lengthInBytes);
       if (blob.lengthInBytes != 1024) {
           print('RecognitionService: ERROR CRÍTICO [SAVE] - BLOB inválido para ID $empleadoId.');
           return;
       }
      await useDb.insert( _tableBiometrics, {'id_empleado': empleadoId, 'tipo_biometria': 'rostro', 'vector_biometrico': blob}, );
      // print('RecognitionService: Vector biométrico guardado para ID: $empleadoId.'); // Reducir logs
  }

  // <<< CAMBIO: _updateCacheForEmployee ahora lee nombre de área >>>
  Future<void> _updateCacheForEmployee(int empleadoId) async {
    if (_db == null) return;
    // Leer empleado con JOIN a área
    final rows = await _db!.rawQuery('''
      SELECT e.*, a.nombre_area
      FROM $_tableEmployees e
      LEFT JOIN $_tableAreas a ON e.id_area = a.id_area
      WHERE e.id = ?
      LIMIT 1
    ''', [empleadoId]);

    if (rows.isEmpty) return;
    final employeeData = rows.first;
    final bioRows = await _db!.query(_tableBiometrics, where: 'id_empleado = ?', whereArgs: [empleadoId]);

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
         imagePath: employeeData['imagePath'] as String?,
         area: employeeData['nombre_area'] as String?, // Usar nombre_area
         eps: employeeData['eps'] as String?, contactoNombre: employeeData['contacto_emergencia_nombre'] as String?,
         contactoTelefono: employeeData['contacto_emergencia_telefono'] as String?, tipoSangre: employeeData['tipo_sangre'] as String?,
         alergias: employeeData['alergias'] as String?,
       );
       _cache ??= <_CacheEntry>[];
       final idx = _cache!.indexWhere((e) => e.idEmpleado == empleadoId);
       if (idx >= 0) { _cache![idx] = entry; } else { _cache!.add(entry); }
        print('RecognitionService: Cache actualizado para ID $empleadoId (Área: ${entry.area ?? "N/A"})');
    } else { print('RecognitionService: WARN - No se pudo actualizar caché para ID $empleadoId (sin vectores).'); }
  }


  // <<< CAMBIO: readAllEmployees ahora une con Áreas para devolver el nombre >>>
  Future<List<Map<String, dynamic>>> readAllEmployees() async {
    final db = _db; if (db == null) await init();
    final sql.Database useDb = _db!;
    // Usar JOIN para obtener el nombre del área
    final List<Map<String, Object?>> rows = await useDb.rawQuery('''
      SELECT e.*, a.nombre_area
      FROM $_tableEmployees e
      LEFT JOIN $_tableAreas a ON e.id_area = a.id_area
      ORDER BY e.nombre ASC
    ''');
    // Mapear incluyendo el nombre_area (renombrarlo a 'area' para consistencia con el código anterior?)
     return rows.map((row) {
        final map = Map<String, dynamic>.from(row);
        map['area'] = map.remove('nombre_area'); // Renombrar para que SettingsScreen funcione igual
        return map;
     }).toList();
  }

  // Aún no implementamos la agrupación aquí, SettingsScreen lo hará

  Future<void> deleteEmployee(String personId, {bool deleteImage = true}) async {
    // ... (sin cambios, el ON DELETE CASCADE se encarga de los biométricos) ...
      final db = _db; if (db == null) await init();
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
    // ... (sin cambios, ya usa el caché que ahora tiene el nombre del área) ...
     if (_cache == null) { await _warmCache(); }
     if (_cache == null || _cache!.isEmpty) { print('RecognitionService: identify() - El caché está vacío.'); return null; }

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
        // print('RecognitionService: Identificado ID: $bestId (${bestMatchEntry.nombre ?? 'N/A'}), Dist: $bestDist'); // Reducir logs
        return RecognizedPerson(
          id: bestId, name: bestMatchEntry.nombre, document: bestMatchEntry.documento, cargo: bestMatchEntry.cargo, telefono: bestMatchEntry.telefono,
          imagePath: bestMatchEntry.imagePath, distance: bestDist,
          // Pasa el nombre del área desde el caché
          area: bestMatchEntry.area,
          eps: bestMatchEntry.eps, contactoNombre: bestMatchEntry.contactoNombre, contactoTelefono: bestMatchEntry.contactoTelefono, tipoSangre: bestMatchEntry.tipoSangre,
          alergias: bestMatchEntry.alergias,
        );
    }
    // else if (bestId != null) { print('RecognitionService: No reconocido - Mejor match ID: $bestId, Dist: $bestDist'); }
    // else { print('RecognitionService: No se encontró ningún match.'); }
    return null;
  }

  double _euclidean(List<double> a, List<double> b) {
    final int n = min(a.length, b.length); double sum = 0.0; for (int i = 0; i < n; i++) { final double d = a[i] - b[i]; sum += d * d; } return sum > 0 ? sqrt(sum) : 0.0;
  }

} // Fin clase RecognitionService


// <<< CAMBIO: _CacheEntry ahora también tiene el nombre del área (String?) >>>
class _CacheEntry {
  _CacheEntry({
    required this.idEmpleado, required this.vectors,
    this.nombre, this.documento, this.cargo, this.telefono, this.imagePath,
    this.area, // <--- Nombre del área (viene del JOIN)
    this.eps, this.contactoNombre, this.contactoTelefono, this.tipoSangre, this.alergias,
  });
   final int idEmpleado;
   final List<List<double>> vectors;
   final String? nombre; final String? documento; final String? cargo; final String? telefono; final String? imagePath;
   final String? area; // <<< Nombre del área como String >>>
   final String? eps; final String? contactoNombre; final String? contactoTelefono; final String? tipoSangre; final String? alergias;
}