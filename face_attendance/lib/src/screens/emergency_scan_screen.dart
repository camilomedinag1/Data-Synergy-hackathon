// Archivo: lib/src/screens/emergency_scan_screen.dart

import 'dart:async';
import 'package:camera/camera.dart';
import '../models/recognized_person.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:image/image.dart' as img;

import '../services/locator.dart';
import '../utils/mlkit_image.dart';
import '../utils/preprocess.dart';
import '../utils/yuv_to_rgb.dart';

class EmergencyScanScreen extends StatefulWidget {
  const EmergencyScanScreen({super.key});

  @override
  State<EmergencyScanScreen> createState() => _EmergencyScanScreenState();
}

class _EmergencyScanScreenState extends State<EmergencyScanScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  Future<void>? _initFuture;
  List<CameraDescription> _cameras = const [];
  bool _isProcessing = false;
  String? _lastDetectedId;
  bool _facePresent = false;
  bool _detailsPanelVisible = false;

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
      if (_controller == null && mounted) {
        setState(() {
          _initFuture = _initialize();
        });
      }
    }
  }

  Future<void> _initialize() async {
    await _controller?.dispose();
    _controller = null;

    await Permission.camera.request();
    if (!(await Permission.camera.isGranted)) {
      print("EmergencyScan: Permiso de cámara denegado.");
      return;
    }

    _cameras = await availableCameras();
    if (_cameras.isEmpty) {
      print("EmergencyScan: No se encontraron cámaras disponibles.");
      return;
    }

    final CameraDescription camera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
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
       print("EmergencyScan: Controlador de cámara (TRASERA) inicializado.");

       if (mounted && _controller != null && _controller!.value.isInitialized) {
         await _controller!.startImageStream(_onCameraImage);
         print("EmergencyScan: Image stream iniciado.");
       }
    } catch (e) {
       print("EmergencyScan: ERROR inicializando la cámara: $e");
       _controller = null;
    } finally {
       if (mounted) {
          setState(() {});
       }
    }
  }


  void _onCameraImage(CameraImage image) {
    // Primera defensa (sin cambios)
    if (_isProcessing || _detailsPanelVisible || _controller == null || !_controller!.value.isInitialized) return;

    _isProcessing = true;
    () async {
      try {
        // <<< INICIO DEL CAMBIO (ARREGLO PARA RACE CONDITION) >>>
        // Segunda defensa: Verificar de nuevo DENTRO del try-catch
        if (_controller == null || !_controller!.value.isInitialized) {
           _isProcessing = false;
           return;
        }
        // <<< FIN DEL CAMBIO >>>

        final input = inputImageFromCameraImage(image, _controller!.description);
        final faces = await ServiceLocator.faceDetector.detectFaces(input);

        if (mounted) {
          setState(() => _facePresent = faces.isNotEmpty);
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

          final match = await ServiceLocator.recognition.identify(embedding, threshold: 0.80);

          if (match != null && match.id != _lastDetectedId && mounted) {
            _lastDetectedId = match.id;
            _detailsPanelVisible = true;
            _controller?.stopImageStream();

            print("EmergencyScan: Rostro identificado: ${match.name}. Mostrando panel.");
            _showEmergencyDetails(match);
          }
        }
      } catch (e) {
         print('EmergencyScan: Error en _onCameraImage: $e');
      } finally {
        await Future.delayed(const Duration(milliseconds: 100));
         if (mounted) {
            _isProcessing = false;
         }
      }
    }();
  }

  void _showEmergencyDetails(RecognizedPerson person) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                person.name ?? 'Empleado ID: ${person.id}',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
              ),
              Text(
                'Documento: ${person.document ?? 'No registrado'}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Divider(height: 32),

              Text(
                'DATOS DE EMERGENCIA',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),

              _EmergencyInfoTile(
                icon: Icons.bloodtype,
                title: 'Tipo de Sangre',
                value: person.tipoSangre,
              ),
              _EmergencyInfoTile(
                icon: Icons.local_hospital,
                title: 'EPS',
                value: person.eps,
              ),
              _EmergencyInfoTile(
                icon: Icons.warning_amber,
                title: 'Alergias Conocidas',
                value: person.alergias,
              ),
              _EmergencyInfoTile(
                icon: Icons.contact_phone,
                title: 'Contacto de Emergencia',
                value: person.contactoNombre,
              ),
              _EmergencyInfoTile(
                icon: Icons.phone,
                title: 'Teléfono de Contacto',
                value: person.contactoTelefono,
              ),

              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cerrar'),
                ),
              ),
              SizedBox(height: MediaQuery.of(context).viewPadding.bottom + 16),
            ],
          ),
        );
      },
    ).whenComplete(() {
      if (mounted) {
        setState(() {
          _lastDetectedId = null;
          _detailsPanelVisible = false;
        });
        _controller?.startImageStream(_onCameraImage);
        print("EmergencyScan: Panel cerrado, reanudando escaneo.");
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Escaneo de Emergencia'),
      ),
      body: FutureBuilder<void>(
        future: _initFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || _controller == null || !_controller!.value.isInitialized) {
             return const Center(child: Text('Error al iniciar cámara trasera. Verifique permisos.'));
          }

          return Stack(
            children: [
              Positioned.fill(child: CameraPreview(_controller!)),

              if (_facePresent)
                Positioned.fill(
                  child: IgnorePointer(
                     child: Container(
                        decoration: BoxDecoration(
                           border: Border.all(color: Colors.greenAccent, width: 4),
                           borderRadius: BorderRadius.circular(12)
                        ),
                        margin: const EdgeInsets.all(20)
                     ),
                  ),
                ),

              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  color: Colors.black.withOpacity(0.6),
                  width: double.infinity,
                  padding: const EdgeInsets.all(16).copyWith(top: MediaQuery.of(context).viewPadding.top + 16),
                  child: const Text(
                    'Apunte la cámara trasera al rostro del empleado para ver sus datos de emergencia.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white, fontSize: 16),
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

// Widget helper para mostrar la info
class _EmergencyInfoTile extends StatelessWidget {
  const _EmergencyInfoTile({required this.icon, required this.title, this.value});

  final IconData icon;
  final String title;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final bool hasData = value != null && value!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.primary, size: 28),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                Text(
                  hasData ? value! : 'No registrado',
                  style: hasData
                      ? Theme.of(context).textTheme.bodyLarge
                      : Theme.of(context).textTheme.bodyLarge?.copyWith(color: Colors.grey.shade600, fontStyle: FontStyle.italic),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}