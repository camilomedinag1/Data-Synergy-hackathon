import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';

import '../services/locator.dart';
import '../utils/mlkit_image.dart';
import '../utils/preprocess.dart';
import '../utils/yuv_to_rgb.dart';

enum EnrollmentPose { center, left, right, up, down }

class EnrollScreen extends StatefulWidget {
  const EnrollScreen({super.key});

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  CameraController? _controller;
  Future<void>? _init;
  bool _busy = false;
  bool _processingFace = false;
  bool _facePresent = false;
  String _status = 'Inicializando...';
  Uint8List? _thumbPng;
  CameraImage? _lastImage;

  final List<EnrollmentPose> _posesToCapture = [
    EnrollmentPose.center,
    EnrollmentPose.left,
    EnrollmentPose.right,
    EnrollmentPose.up,
    EnrollmentPose.down,
  ];

  int _currentPoseIndex = 0;
  final List<List<double>> _capturedEmbeddings = [];
  img.Image? _lastValidCropForSave;

  // Eliminamos el Timer de debounce por la lógica de _processingFace
  // Timer? _faceDebounce; 

  @override
  void initState() {
    super.initState();
    _init = _initialize();
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    // _faceDebounce?.cancel(); // Eliminamos la cancelación del Timer
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final List<CameraDescription> cams = await availableCameras();
      final CameraDescription cam = cams.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cams.first,
      );

      _controller = CameraController(
        cam,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller!.initialize();

      if (mounted) {
        if (!ServiceLocator.embedder.isLoaded) {
          _updateStatus(
              'Error cargando modelo: ${ServiceLocator.embedder.lastError ?? ''}');
        } else {
          _updateStatus(_getInstructionForPose(_posesToCapture[_currentPoseIndex]));
        }
        await _controller!.startImageStream(_onImage);
      }
    } catch (e) {
      if (mounted) _updateStatus('Error al iniciar cámara: $e');
    }
  }

  // -------------------- DETECCIÓN FACIAL (Corregida sin Timer) --------------------
  void _onImage(CameraImage image) {
    if (_processingFace) return;
    _processingFace = true;
    _lastImage = image;

    () async {
      try {
        final input = inputImageFromCameraImage(image, _controller!.description);
        final faces = await ServiceLocator.faceDetector.detectFaces(input);
        final bool detected = faces.isNotEmpty;

        if (mounted && detected != _facePresent) {
          setState(() {
            _facePresent = detected; // Se activa y desactiva instantáneamente con la detección
            if (_currentPoseIndex < _posesToCapture.length) {
              _status = detected
                  ? _getInstructionForPose(_posesToCapture[_currentPoseIndex])
                  : 'Acerque su rostro a la cámara';
            }
          });
        }
        
      } catch (e) {
        print("Error detección facial: $e");
      } finally {
        // Control de FPS: esperamos un microsegundo para que la CPU se recupere
        // y se procesen los frames en el siguiente ciclo.
        await Future.delayed(const Duration(milliseconds: 10)); 
        _processingFace = false;
      }
    }();
  }

  // -------------------- CAPTURAR ROSTRO --------------------
  Future<void> _captureCurrentPose() async {
    if (_currentPoseIndex >= _posesToCapture.length || _busy) return;
    
    // Aquí _facePresent es la detección cruda, si es false, el usuario falló.
    if (!_facePresent || _lastImage == null) { 
      _updateStatus('¡Error! Asegúrese de que su rostro esté visible.');
      return;
    }

    _busy = true; // Bloquea la UI para procesar
    _updateStatus('Procesando...');

    try {
      final CameraImage imageToProcess = _lastImage!;
      final InputImage input =
          inputImageFromCameraImage(imageToProcess, _controller!.description);
      final List<Face> faces = await ServiceLocator.faceDetector.detectFaces(input);

      if (faces.isNotEmpty) {
        final img.Image full = yuv420ToImage(imageToProcess);
        final Face first = faces.first;
        final Rect box = first.boundingBox;

        final int x = box.left.clamp(0, full.width - 1).toInt();
        final int y = box.top.clamp(0, full.height - 1).toInt();
        final int w = box.width.clamp(1, full.width - x).toInt();
        final int h = box.height.clamp(1, full.height - y).toInt();

        final img.Image cropped =
            img.copyCrop(full, x: x, y: y, width: w, height: h);

        if (_posesToCapture[_currentPoseIndex] == EnrollmentPose.center) {
          _lastValidCropForSave = cropped;
        }

        final data = preprocessTo112Rgb(cropped);
        final embedding = ServiceLocator.embedder.runEmbedding(data);
        _capturedEmbeddings.add(embedding);

        final img.Image thumb = img.copyResize(cropped, width: 72, height: 72);
        _thumbPng = Uint8List.fromList(img.encodePng(thumb));

        _currentPoseIndex++;
        
        setState(() {
          if (_currentPoseIndex < _posesToCapture.length) {
            _status = _getInstructionForPose(_posesToCapture[_currentPoseIndex]);
          } else {
            _status = '¡Captura completada! Presione Finalizar.';
             _controller?.stopImageStream();
          }
        });
      } else {
        _updateStatus('No se detectó rostro en la captura.');
      }
    } catch (e) {
      _updateStatus('Error: $e');
    } finally {
      _busy = false;
    }
  }

  // -------------------- GUARDAR DATOS (IMPLEMENTACIÓN COMPLETA) --------------------
  Future<void> _showSaveDialog(List<List<double>> embeddings,
      {img.Image? faceImage}) async {

    final String? savedPath = faceImage != null ? await _saveFaceImage(faceImage) : null;
    if (!mounted) return;

    // Controladores para TODOS los nuevos campos
    final TextEditingController nameController = TextEditingController();
    final TextEditingController docController = TextEditingController();
    final TextEditingController cargoController = TextEditingController();
    final TextEditingController telController = TextEditingController();
    final TextEditingController areaController = TextEditingController();
    final TextEditingController epsController = TextEditingController();
    final TextEditingController contactoNombreController = TextEditingController();
    final TextEditingController contactoTelController = TextEditingController();
    final TextEditingController tipoSangreController = TextEditingController();
    final TextEditingController alergiasController = TextEditingController();

    String? docError;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Guardar Empleado'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Nombre Completo*')),
                    TextField(
                      controller: docController,
                      decoration: InputDecoration(
                        labelText: 'Documento (Cédula)*',
                        errorText: docError,
                      ),
                      keyboardType: TextInputType.number,
                    ),
                    TextField(controller: telController, decoration: const InputDecoration(labelText: 'Teléfono'), keyboardType: TextInputType.phone),
                    // Nuevos campos
                    TextField(controller: areaController, decoration: const InputDecoration(labelText: 'Área de Trabajo')),
                    TextField(controller: cargoController, decoration: const InputDecoration(labelText: 'Cargo')),
                    TextField(controller: epsController, decoration: const InputDecoration(labelText: 'EPS')),
                    TextField(controller: contactoNombreController, decoration: const InputDecoration(labelText: 'Contacto Emergencia Nombre')),
                    TextField(controller: contactoTelController, decoration: const InputDecoration(labelText: 'Contacto Emergencia Teléfono'), keyboardType: TextInputType.phone),
                    TextField(controller: tipoSangreController, decoration: const InputDecoration(labelText: 'Tipo de Sangre')),
                    TextField(controller: alergiasController, decoration: const InputDecoration(labelText: 'Alergias Conocidas')),
                    const SizedBox(height: 10),
                    Text('* Campos obligatorios', style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(dialogContext).pop();
                    _resetEnrollmentState(); // Reiniciar estado si se cancela
                  },
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final String name = nameController.text.trim();
                    final String document = docController.text.trim();

                    if (name.isEmpty || document.isEmpty) {
                      setDialogState(() {
                         docError = "Nombre y Documento son obligatorios.";
                      });
                      return;
                    }

                    // Validar si la cédula ya existe
                    bool exists = await ServiceLocator.recognition.checkIfDocumentExists(document);
                    if (exists) {
                      setDialogState(() {
                        docError = 'Este documento ya está registrado.';
                      });
                      return;
                    } else {
                       setDialogState(() { docError = null; });
                    }

                    FocusScope.of(context).unfocus();
                    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

                    try {
                      // Llamar a la nueva función de guardado con todos los detalles
                      await ServiceLocator.recognition.saveIdentityWithDetails(
                        embeddings: embeddings,
                        imagePath: savedPath,
                        name: name, document: document,
                        cargo: cargoController.text.trim().isEmpty ? null : cargoController.text.trim(),
                        telefono: telController.text.trim().isEmpty ? null : telController.text.trim(),
                        area: areaController.text.trim().isEmpty ? null : areaController.text.trim(),
                        eps: epsController.text.trim().isEmpty ? null : epsController.text.trim(),
                        contactoNombre: contactoNombreController.text.trim().isEmpty ? null : contactoNombreController.text.trim(),
                        contactoTelefono: contactoTelController.text.trim().isEmpty ? null : contactoTelController.text.trim(),
                        tipoSangre: tipoSangreController.text.trim().isEmpty ? null : tipoSangreController.text.trim(),
                        alergias: alergiasController.text.trim().isEmpty ? null : alergiasController.text.trim(),
                      );

                       if (mounted) {
                          Navigator.of(context).pop(); // Cerrar indicador de progreso
                          Navigator.of(dialogContext).pop(); // Cerrar diálogo de guardar
                          Navigator.of(context).maybePop(); // Volver a la pantalla anterior (Settings)
                       }
                    } catch (e) {
                       print("EnrollScreen: Error guardando identidad: $e");
                       if (mounted) {
                          Navigator.of(context).pop();
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al guardar: $e')));
                       }
                    } finally {
                       if (!mounted) return;
                    }
                  },
                  child: const Text('Guardar'),
                ),
              ],
            );
          },
        );
      },
    ).then((_) {
       // Reiniciar el stream de la cámara si se cerró el diálogo
       if (mounted && _controller != null && !_controller!.value.isStreamingImages) {
          _controller!.startImageStream(_onImage);
       }
    });
  }

  // Función para reiniciar el estado si se cancela o se guarda exitosamente
  void _resetEnrollmentState() {
     print("EnrollScreen: Reiniciando estado de enrolamiento.");
    if (!mounted) return;
    setState(() {
      _currentPoseIndex = 0;
      _capturedEmbeddings.clear();
      _lastValidCropForSave = null;
      _thumbPng = null;
      _facePresent = false;
      if (ServiceLocator.embedder.isLoaded) {
         _status = _getInstructionForPose(_posesToCapture[_currentPoseIndex]);
      } else {
         _status = 'Modelo no cargado.';
      }
    });
    // Asegurarse de que el stream esté corriendo
    if (_controller != null && !_controller!.value.isStreamingImages) {
       _controller!.startImageStream(_onImage);
    }
  }


  String _getInstructionForPose(EnrollmentPose pose) {
    switch (pose) {
      case EnrollmentPose.center:
        return 'Mire al CENTRO y presione Capturar';
      case EnrollmentPose.left:
        return 'Gire LIGERAMENTE a la IZQUIERDA y presione Capturar';
      case EnrollmentPose.right:
        return 'Gire LIGERAMENTE a la DERECHA y presione Capturar';
      case EnrollmentPose.up:
        return 'Incline LIGERAMENTE HACIA ARRIBA y presione Capturar';
      case EnrollmentPose.down:
        return 'Incline LIGERAMENTE HACIA ABAJO y presione Capturar';
    }
  }

  Future<String?> _saveFaceImage(img.Image imgImage) async {
    try {
      final Directory appDir = await getApplicationDocumentsDirectory();
      final Directory facesDir = Directory('${appDir.path}/faces');
      if (!await facesDir.exists()) await facesDir.create(recursive: true);
      final String filePath = '${facesDir.path}/face_${DateTime.now().millisecondsSinceEpoch}.png';
      final bytes = img.encodePng(imgImage);
      await File(filePath).writeAsBytes(bytes, flush: true);
      print("EnrollScreen: Imagen de rostro guardada en $filePath");
      return filePath;
    } catch (e) {
      print("EnrollScreen: Error guardando imagen de rostro: $e");
      return null;
    }
  }

  void _updateStatus(String msg) {
    if (mounted) setState(() => _status = msg);
  }


  // -------------------- INTERFAZ --------------------
  @override
  Widget build(BuildContext context) {
    final bool isFinished = _currentPoseIndex >= _posesToCapture.length;
    
    // El botón se habilita si el modelo está cargado, no estamos ocupados, Y la cara está presente (o ya terminamos).
    // Usamos _facePresent (detección cruda) para habilitar el botón.
    final bool isButtonEnabled = ServiceLocator.embedder.isLoaded && !_busy && (_facePresent || isFinished); 
    
    return Scaffold(
      appBar: AppBar(title: const Text('Registrar Empleado')),
      body: FutureBuilder<void>(
        future: _init,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done ||
              _controller == null ||
              !_controller!.value.isInitialized) {
            return Center(child: snapshot.hasError
                ? Text('Error: ${snapshot.error}')
                : const CircularProgressIndicator());
          }

          // Renderizar la cámara y la interfaz
          return Stack(
            children: [
              Positioned.fill(child: CameraPreview(_controller!)),
              
              // Indicador visual de rostro detectado
              if (_facePresent)
                Positioned.fill(
                  child: IgnorePointer(
                     child: Container(
                        decoration: BoxDecoration(
                           border: Border.all(color: Colors.greenAccent, width: 4),
                        ),
                     ),
                  ),
                ),
              // Fin Indicador

              Align(
                alignment: Alignment.bottomCenter,
                child: Container(
                  color: Colors.black.withOpacity(0.6),
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Indicadores de poses
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: List.generate(
                          _posesToCapture.length,
                          (index) => Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4.0),
                            child: Icon(
                              index < _capturedEmbeddings.length
                                  ? Icons.check_circle
                                  : Icons.radio_button_unchecked,
                              color: index < _capturedEmbeddings.length
                                  ? Colors.green
                                  : Colors.white54,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      
                      // Thumbnail
                      if (_thumbPng != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.memory( _thumbPng!, width: 72, height: 72, fit: BoxFit.cover,),
                        ),
                      const SizedBox(height: 12),
                      
                      // Mensaje de estado
                      Text(
                        _status,
                        style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 16),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      
                      // Botón principal
                      FilledButton.icon(
                        onPressed: isButtonEnabled
                            ? (isFinished
                                ? () => _showSaveDialog(_capturedEmbeddings,
                                      faceImage: _lastValidCropForSave)
                                : _captureCurrentPose)
                            : null,
                        icon: Icon(isFinished ? Icons.save : Icons.camera_alt),
                        label: Text(isFinished
                            ? 'Finalizar Registro'
                            : 'Capturar (${_currentPoseIndex + 1}/${_posesToCapture.length})'),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(50),
                          backgroundColor: isButtonEnabled
                              ? Colors.blue
                              : Colors.grey.shade700,
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
