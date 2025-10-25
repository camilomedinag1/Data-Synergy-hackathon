import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;

import '../theme/app_theme.dart';
import '../services/locator.dart';
import '../utils/mlkit_image.dart';
import '../utils/preprocess.dart';
import '../utils/yuv_to_rgb.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.onOpenSettings,
    required this.onOpenEmergencyScan,
  });

  final VoidCallback onOpenSettings;
  final VoidCallback onOpenEmergencyScan;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  List<CameraDescription> _cameras = const [];
  bool _isProcessing = false;
  String? _lastDetectedId;
  String? _lastDetectedName;
  String? _lastDetectedDocument;
  Timer? _bannerTimer;
  bool _facePresent = false;
  List<double>? _lastEmbedding;

  // <<< CAMBIO: Variables para el indicador de sincronización >>>
  int _pendingSyncCount = 0;
  Timer? _syncStatusTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _initialize();

    // <<< CAMBIO: Inicializar indicador de sincronización >>>
    // Obtener estado inicial
    _updateSyncStatus();
    // Escuchar cambios desde SyncService
    ServiceLocator.sync.addListener(_updateSyncStatus);
    // Refrescar periódicamente (ej. cada 30 seg) por si acaso
    _syncStatusTimer = Timer.periodic(const Duration(seconds: 30), (_) {
       // Solo actualiza si el widget todavía está montado
       if (mounted) _updateSyncStatus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    // <<< CAMBIO: Limpiar listener y timer de sincronización >>>
    ServiceLocator.sync.removeListener(_updateSyncStatus);
    _syncStatusTimer?.cancel();
    super.dispose();
  }

  // <<< CAMBIO: Nueva función para actualizar el estado de sincronización >>>
  Future<void> _updateSyncStatus() async {
    // Verificar que el widget siga montado antes de llamar a setState
    if (!mounted) return;
    final count = await ServiceLocator.sync.getPendingRecordCount();
    // Solo actualizar si el valor cambió para evitar rebuilds innecesarios
    if (count != _pendingSyncCount && mounted) {
      setState(() {
        _pendingSyncCount = count;
      });
       print("HomeScreen: Estado de sincronización actualizado. Pendientes: $count");
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (state == AppLifecycleState.inactive) {
      cameraController?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null) {
        if (mounted) {
          setState(() {
            _initFuture = _initialize();
          });
        }
      }
      // <<< CAMBIO: Actualizar estado de sync al volver a la app >>>
       if (mounted) _updateSyncStatus();
    }
  }

  Future<void> _initialize() async {
    // ... (resto de _initialize sin cambios) ...
      await _controller?.dispose();
      _controller = null;

      await Permission.camera.request();
      if (!(await Permission.camera.isGranted)) {
        print("HomeScreen: Permiso de cámara denegado.");
        return;
      }

      _cameras = await availableCameras();
      if (_cameras.isEmpty) {
        print("HomeScreen: No se encontraron cámaras disponibles.");
        return;
      }

      final CameraDescription camera = _cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => _cameras.first,
      );

      try {
        _controller = CameraController(
          camera,
          ResolutionPreset.medium,
          enableAudio: false,
          imageFormatGroup: ImageFormatGroup.yuv420,
        );
        await _controller!.initialize();
        print("HomeScreen: Controlador de cámara inicializado.");

        if (mounted && _controller != null && _controller!.value.isInitialized) {
          await _controller!.startImageStream(_onCameraImage);
          print("HomeScreen: Image stream iniciado.");
        } else {
          print("HomeScreen: No se inició el image stream (widget desmontado o controlador no inicializado).");
        }
      } catch (e) {
        print("HomeScreen: ERROR inicializando la cámara: $e");
        _controller = null;
      } finally {
        if (mounted) {
          setState(() {});
        }
      }
  }

  void _onCameraImage(CameraImage image) {
    // ... (resto de _onCameraImage sin cambios) ...
      if (_isProcessing || _controller == null || !_controller!.value.isInitialized) return;

      _isProcessing = true;
      () async {
        try {
          if (_controller == null || !_controller!.value.isInitialized) {
            _isProcessing = false;
            return;
          }

          final input = inputImageFromCameraImage(image, _controller!.description);
          final faces = await ServiceLocator.faceDetector.detectFaces(input);
          _facePresent = faces.isNotEmpty;

          if (!mounted) {
            _isProcessing = false;
            return;
          }
          // Evitar setState si solo cambió _facePresent (puede causar jank)
          // Solo llamamos setState si _facePresent cambió O si hay datos detectados
          bool needsSetState = false;
          if( (faces.isNotEmpty != _facePresent) ) {
            _facePresent = faces.isNotEmpty;
            needsSetState = true;
          }


          if (faces.isNotEmpty) {
            final rgb = yuv420ToImage(image);
            final Rect box = faces.first.boundingBox;
            final int x = box.left.clamp(0, rgb.width - 1).toInt();
            final int y = box.top.clamp(0, rgb.height - 1).toInt();
            final int w = box.width.clamp(1, rgb.width - x).toInt();
            final int h = box.height.clamp(1, rgb.height - y).toInt();
            final img.Image cropped = img.copyCrop(rgb, x: x, y: y, width: w, height: h);
            final data = preprocessTo112Rgb(cropped);
            final embedding = ServiceLocator.embedder.runEmbedding(data);
            _lastEmbedding = embedding;

            // print('HomeScreen: Intentando identificar. Cache tiene: ${ServiceLocator.recognition.cacheStatus}');

            final match = await ServiceLocator.recognition.identify(embedding, threshold: 0.85);

            if (match != null) {
              // Si el ID detectado es diferente al último, necesitamos setState
              if (match.id != _lastDetectedId) needsSetState = true;

              _lastDetectedId = match.id;
              _lastDetectedName = match.name;
              _lastDetectedDocument = match.document;


              _bannerTimer?.cancel();
              _bannerTimer = Timer(const Duration(seconds: 2), () {
                if (!mounted) return;
                // Verificar si el ID sigue siendo el mismo antes de borrar
                if (_lastDetectedId == match.id) {
                    _lastDetectedId = null;
                    _lastDetectedName = null;
                    _lastDetectedDocument = null;
                    if(mounted) setState(() {}); // Necesario para ocultar el banner
                }
              });
            } else {
                // Si antes había una detección y ahora no, necesitamos setState para limpiar banner
                if (_lastDetectedId != null) needsSetState = true;
                _lastDetectedId = null;
                _lastDetectedName = null;
                _lastDetectedDocument = null;
            }
          } else {
             // Si antes había una detección y ahora no, necesitamos setState
             if (_lastDetectedId != null) needsSetState = true;
             _lastDetectedId = null;
             _lastDetectedName = null;
             _lastDetectedDocument = null;
          }

          // Llamar a setState solo si es necesario
          if (needsSetState && mounted) {
             setState(() {});
          }

        } catch (e) {
          print('HomeScreen: Error en _onCameraImage: $e');
        } finally {
          await Future.delayed(const Duration(milliseconds: 100));
          if (mounted) {
            _isProcessing = false;
          }
        }
      }();
  }

  // --- Funciones de registro de ingreso/egreso (sin cambios) ---
  void _onRegisterIngress() {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Intentando identificar para ingreso...')),
      );
      _registerAttendance(isIngress: true);
    }

  void _onRegisterEgress() {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Intentando identificar para salida...')),
      );
      _registerAttendance(isIngress: false);
    }

  Future<void> _registerAttendance({required bool isIngress}) async {
      String? id = _lastDetectedId;
      if (id == null && _lastEmbedding != null) {
        try {
          print('HomeScreen: _registerAttendance - Re-intentando identificar con último embedding...');
          final match = await ServiceLocator.recognition.identify(_lastEmbedding!, threshold: 1.20);
          if (match != null) {
            id = match.id;
            _lastDetectedId = match.id;
            _lastDetectedName = match.name;
            _lastDetectedDocument = match.document;
            if (mounted) setState(() {});
            print('HomeScreen: _registerAttendance - Identificación exitosa en re-intento.');
          } else {
            print('HomeScreen: _registerAttendance - Re-intento fallido.');
          }
        } catch (e) {
          print('HomeScreen: _registerAttendance - Error en re-intento de identificación: $e');
        }
      }
      if (id == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('No se detectó identidad válida recientemente')),
          );
        }
        return;
      }
      try {
        final String eventType = isIngress ? 'entrada' : 'salida';
        if (isIngress) {
          await ServiceLocator.attendance.registerIngress(id);
        } else {
          await ServiceLocator.attendance.registerEgress(id);
        }
        // <<< CAMBIO: Forzar actualización del indicador de sync DESPUÉS de registrar >>>
        if (mounted) _updateSyncStatus();

        if (mounted) {
          final String label = _lastDetectedName ?? 'ID $id';
          final String suffix = _lastDetectedDocument != null ? ' · Doc: ${_lastDetectedDocument}' : '';
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${eventType.replaceFirst('e', 'E')} registrada para $label$suffix')));
          print('HomeScreen: Registro de $eventType exitoso para ID $id ($label)');
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error al registrar asistencia: $e')),
          );
        }
        print('HomeScreen: ERROR registrando asistencia para ID $id: $e');
      }
    }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Asistencia Facial'),
        actions: [
          // <<< CAMBIO: Añadir el indicador de sincronización >>>
          IconButton(
            icon: Icon(
              _pendingSyncCount == 0 ? Icons.cloud_done_outlined : Icons.cloud_upload_outlined,
              color: _pendingSyncCount == 0 ? Colors.greenAccent : Colors.orangeAccent,
            ),
            tooltip: _pendingSyncCount == 0
                ? 'Sincronizado'
                : '$_pendingSyncCount registros pendientes',
            onPressed: () {
              // Opcional: Podríamos forzar un intento de sincronización al tocar
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(_pendingSyncCount == 0
                      ? 'Todos los registros están sincronizados.'
                      : 'Hay $_pendingSyncCount registros pendientes de envío.')));
              // ServiceLocator.sync.triggerManualSync(); // <-- Necesitaríamos añadir esta función a SyncService si quisiéramos forzar
            },
          ),
          IconButton(
            onPressed: widget.onOpenEmergencyScan,
            icon: const Icon(Icons.health_and_safety_outlined),
            tooltip: 'Escaneo de Emergencia',
          ),
          IconButton(
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.settings),
            tooltip: 'Configuración',
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          // ... (resto del build sin cambios) ...
           if (snapshot.connectionState == ConnectionState.waiting) {
             print("HomeScreen: Build - Esperando inicialización (_initFuture)...");
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
             print("HomeScreen: Build - Error en FutureBuilder: ${snapshot.error}");
             return Center(child: Text('Error inicializando: ${snapshot.error}'));
          }
          final CameraController? ctrl = _controller;
          if (ctrl == null || !ctrl.value.isInitialized) {
             print("HomeScreen: Build - Inicialización completada, pero cámara no lista (ctrl is null: ${ctrl == null}, isInitialized: ${ctrl?.value.isInitialized})");
             return const Center(child: Text('Cámara no disponible. Verifique permisos o reinicie.'));
          }

           // print("HomeScreen: Build - Mostrando CameraPreview."); // Evitar spam en consola
          return Stack(
            children: [
              Positioned.fill(child: CameraPreview(ctrl)),
              Positioned(
                top: 0, left: 0, right: 0,
                child: Container(
                  color: Colors.black.withOpacity(0.5),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SafeArea(
                    bottom: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (_lastDetectedName != null)
                          Text(
                            _lastDetectedName!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                          )
                        else
                          const Text(
                            'Acerque su rostro a la cámara',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        if (_lastDetectedDocument != null && _lastDetectedName != null)
                           Padding(
                             padding: const EdgeInsets.only(top: 2.0),
                             child: Text(
                               _lastDetectedDocument!,
                               textAlign: TextAlign.center,
                               style: const TextStyle(color: Colors.white70, fontSize: 14),
                               maxLines: 1, overflow: TextOverflow.ellipsis,
                             ),
                           )
                        else if (!_facePresent && _lastDetectedName == null)
                           // Ya no mostramos "Buscando rostro..." aquí para reducir jank
                           // Dejamos solo el mensaje principal o el nombre detectado
                           const SizedBox.shrink(),
                      ],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: kPrimaryColor.withOpacity(0.5), width: 6),
                    ),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(16).copyWith(bottom: 32),
                  child: Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _onRegisterIngress,
                          icon: const Icon(Icons.login),
                          label: const Text('Registrar ingreso'),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _onRegisterEgress,
                          icon: const Icon(Icons.logout),
                          label: const Text('Registrar salida'),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}