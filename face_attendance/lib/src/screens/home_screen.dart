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
  const HomeScreen({super.key, required this.onOpenSettings});

  final VoidCallback onOpenSettings;

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initFuture = _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;
    if (state == AppLifecycleState.inactive) {
      cameraController?.dispose();
      _controller = null;
    } else if (state == AppLifecycleState.resumed) {
      if (_controller == null) {
        // Solo reinicializar si el controlador fue dispuesto
        if (mounted) { // Verificar si el widget sigue montado
          setState(() {
            _initFuture = _initialize();
          });
        }
      }
    }
  }

  Future<void> _initialize() async {
    // Liberar controlador anterior si existe
    await _controller?.dispose();
    _controller = null;

    // Solicitar permiso de cámara
    await Permission.camera.request();
    if (!(await Permission.camera.isGranted)) {
       print("HomeScreen: Permiso de cámara denegado.");
       // Podrías mostrar un mensaje al usuario aquí
       return; // No continuar si no hay permiso
    }

    _cameras = await availableCameras();
    if (_cameras.isEmpty) {
       print("HomeScreen: No se encontraron cámaras disponibles.");
       // Podrías mostrar un mensaje al usuario aquí
       return; // No continuar si no hay cámaras
    }
    
    // Seleccionar cámara frontal preferentemente
    final CameraDescription camera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => _cameras.first,
    );

    // Crear e inicializar el controlador
    try {
       _controller = CameraController(
         camera,
         ResolutionPreset.medium,
         enableAudio: false,
         imageFormatGroup: ImageFormatGroup.yuv420,
       );
       await _controller!.initialize();
        print("HomeScreen: Controlador de cámara inicializado.");

       // Inicializar servicios (esto incluye _warmCache)
       // Usamos un try-catch por si ServiceLocator.init() falla
       try {
          print("HomeScreen: Llamando a ServiceLocator.init()...");
          await ServiceLocator.init();
          print("HomeScreen: ServiceLocator.init() completado.");
       } catch (e) {
          print("HomeScreen: ERROR durante ServiceLocator.init(): $e");
          // Considerar mostrar error al usuario
       }

       // Iniciar el stream de imágenes solo si todo está bien y el widget sigue montado
       if (mounted && _controller != null && _controller!.value.isInitialized) {
         await _controller!.startImageStream(_onCameraImage);
         print("HomeScreen: Image stream iniciado.");
       } else {
         print("HomeScreen: No se inició el image stream (widget desmontado o controlador no inicializado).");
       }
    } catch (e) {
       print("HomeScreen: ERROR inicializando la cámara: $e");
       _controller = null; // Asegurar que el controlador quede nulo si falla
       // Considerar mostrar error al usuario
    } finally {
       // Asegurar que el estado se actualice para reflejar si la cámara está lista o no
       if (mounted) {
          setState(() {});
       }
    }
  }


  void _onCameraImage(CameraImage image) {
    // Si ya estamos procesando un frame o el controlador no está listo, salir.
    if (_isProcessing || _controller == null || !_controller!.value.isInitialized) return;

    _isProcessing = true;
    // Usamos un closure asíncrono para manejar el procesamiento
    () async {
      try {
        // Convertir CameraImage a InputImage para ML Kit
        final input = inputImageFromCameraImage(image, _controller!.description);
        // Detectar caras
        final faces = await ServiceLocator.faceDetector.detectFaces(input);
        _facePresent = faces.isNotEmpty;

        // Actualizar UI si el widget sigue montado
        if (!mounted) {
           _isProcessing = false; // Liberar flag si el widget se desmontó
           return;
        }
        setState(() {}); // Actualizar UI (ej. mensaje "Buscando rostro...")

        // Si se detectaron caras...
        if (faces.isNotEmpty) {
          // Convertir YUV a RGB (puede ser costoso)
          final rgb = yuv420ToImage(image);
          // Recortar la primera cara detectada
          final Rect box = faces.first.boundingBox;
          final int x = box.left.clamp(0, rgb.width - 1).toInt();
          final int y = box.top.clamp(0, rgb.height - 1).toInt();
          final int w = box.width.clamp(1, rgb.width - x).toInt();
          final int h = box.height.clamp(1, rgb.height - y).toInt();
          final img.Image cropped = img.copyCrop(rgb, x: x, y: y, width: w, height: h);
          // Preprocesar imagen para el modelo TFLite
          final data = preprocessTo112Rgb(cropped);
          // Obtener el vector (embedding) del rostro
          final embedding = ServiceLocator.embedder.runEmbedding(data);
          _lastEmbedding = embedding; // Guardar último embedding por si acaso

          // PRINT DE DIAGNÓSTICO: Ver el estado del caché ANTES de identificar
          print('HomeScreen: Intentando identificar. Cache tiene: ${ServiceLocator.recognition.cacheStatus}');
          

          // Intentar identificar el rostro usando el embedding
          final match = await ServiceLocator.recognition.identify(embedding, threshold: 0.85);

          // Si se encontró una coincidencia...
          if (match != null) {
            // Actualizar los datos del rostro detectado
            _lastDetectedId = match.id;
            _lastDetectedName = match.name;
            _lastDetectedDocument = match.document;
            if (mounted) setState(() {}); // Actualizar UI para mostrar nombre/documento

            // Iniciar/reiniciar timer para ocultar el nombre después de 2 segundos
            _bannerTimer?.cancel();
            _bannerTimer = Timer(const Duration(seconds: 2), () {
              if (!mounted) return;
              _lastDetectedId = null;
              _lastDetectedName = null;
              _lastDetectedDocument = null;
              setState(() {}); // Ocultar nombre/documento
            });
          }
        }
      } catch (e) {
        // Capturar errores (ej. error en TFLite, conversión de imagen, etc.)
        // Evitamos crashear la app por un frame fallido.
         print('HomeScreen: Error en _onCameraImage: $e');
         // Considerar si es necesario hacer algo más aquí (ej. reintentar inicialización)
      } finally {
        // Añadir delay para limitar FPS y liberar CPU
        await Future.delayed(const Duration(milliseconds: 100));
        // Marcar que hemos terminado de procesar este frame
         // Solo cambiar si el widget sigue montado
         if (mounted) {
            _isProcessing = false;
         }
      }
    }(); // Ejecutar el closure asíncrono
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
    // Si no se detectó recientemente, intentar identificar con el último embedding visto
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
    // Si sigue sin haber ID, mostrar error
    if (id == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('No se detectó identidad válida recientemente')),
        );
      }
      return;
    }
    // Registrar asistencia
    try {
      final String eventType = isIngress ? 'entrada' : 'salida';
      if (isIngress) {
        await ServiceLocator.attendance.registerIngress(id);
      } else {
        await ServiceLocator.attendance.registerEgress(id);
      }
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
          IconButton(
            onPressed: widget.onOpenSettings,
            icon: const Icon(Icons.settings),
            tooltip: 'Configuración',
          ),
        ],
      ),
      body: FutureBuilder<void>(
        future: _initFuture, // El future que inicializa todo
        builder: (context, snapshot) {
          // Mientras inicializa, mostrar spinner
          if (snapshot.connectionState == ConnectionState.waiting) {
             print("HomeScreen: Build - Esperando inicialización (_initFuture)...");
            return const Center(child: CircularProgressIndicator());
          }
          // Si hubo un error durante la inicialización
          if (snapshot.hasError) {
             print("HomeScreen: Build - Error en FutureBuilder: ${snapshot.error}");
             return Center(child: Text('Error inicializando: ${snapshot.error}'));
          }
          // Si la inicialización terminó pero el controlador no está listo (o falló)
          final CameraController? ctrl = _controller;
          if (ctrl == null || !ctrl.value.isInitialized) {
             print("HomeScreen: Build - Inicialización completada, pero cámara no lista (ctrl is null: ${ctrl == null}, isInitialized: ${ctrl?.value.isInitialized})");
             // Podríamos intentar re-inicializar o mostrar un botón para reintentar
             return const Center(child: Text('Cámara no disponible. Verifique permisos o reinicie.'));
          }

          // Si todo está bien, mostrar la cámara y controles
           print("HomeScreen: Build - Mostrando CameraPreview.");
          return Stack(
            children: [
              Positioned.fill(child: CameraPreview(ctrl)), // Vista de la cámara
              // Banner superior con información del rostro detectado
              Positioned(
                top: 0, left: 0, right: 0,
                child: Container(
                  color: Colors.black.withOpacity(0.5), // Fondo semitransparente
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  child: SafeArea( // Evitar que el contenido se solape con la barra de estado
                    bottom: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min, // Ajustar altura al contenido
                      children: [
                        // Mostrar nombre si está detectado
                        if (_lastDetectedName != null)
                          Text(
                            _lastDetectedName!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                            maxLines: 1, overflow: TextOverflow.ellipsis,
                          )
                        // Si no hay nombre detectado, mostrar mensaje por defecto
                        else
                          const Text(
                            'Acerque su rostro a la cámara',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                        // Mostrar documento si está detectado y hay nombre
                        if (_lastDetectedDocument != null && _lastDetectedName != null)
                           Padding( // Añadir un poco de espacio
                             padding: const EdgeInsets.only(top: 2.0),
                             child: Text(
                               _lastDetectedDocument!,
                               textAlign: TextAlign.center,
                               style: const TextStyle(color: Colors.white70, fontSize: 14),
                               maxLines: 1, overflow: TextOverflow.ellipsis,
                             ),
                           )
                        // Si no hay rostro presente, mostrar "Buscando..."
                        else if (!_facePresent && _lastDetectedName == null) // Solo si no hay ni rostro ni detección reciente
                          const Padding(
                            padding: EdgeInsets.only(top: 2.0),
                            child: Text(
                              'Buscando rostro...',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white60, fontSize: 13),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              // Overlay simple con borde (decorativo)
              Positioned.fill(
                child: IgnorePointer( // Para que no interfiera con toques
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(color: kPrimaryColor.withOpacity(0.5), width: 6),
                    ),
                  ),
                ),
              ),
              // Botones de registro en la parte inferior
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.all(16).copyWith(bottom: 32), // Más padding inferior
                  child: Row( // Usar Row para poner botones lado a lado
                    children: [
                      Expanded( // Botón ocupa mitad del espacio
                        child: ElevatedButton.icon(
                          onPressed: _onRegisterIngress, // Acción al presionar
                          icon: const Icon(Icons.login),
                          label: const Text('Registrar ingreso'),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)), // Más alto
                        ),
                      ),
                      const SizedBox(width: 16), // Espacio entre botones
                      Expanded( // Botón ocupa la otra mitad
                        child: ElevatedButton.icon(
                          onPressed: _onRegisterEgress, // Acción al presionar
                          icon: const Icon(Icons.logout),
                          label: const Text('Registrar salida'),
                          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)), // Más alto
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