import 'dart:async';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;

import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
// <<< CAMBIO: Ya no necesitamos FilePicker aquí (era para el modelo) >>>
// import 'package:file_picker/file_picker.dart';

import '../services/locator.dart';
// <<< CAMBIO: Importar el modelo Area >>>
import '../services/recognition_service.dart' show Area;
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
    EnrollmentPose.center, EnrollmentPose.left, EnrollmentPose.right, EnrollmentPose.up, EnrollmentPose.down,
  ];

  int _currentPoseIndex = 0;
  final List<List<double>> _capturedEmbeddings = [];
  img.Image? _lastValidCropForSave;

  // <<< CAMBIO: Variables de estado para el Dropdown de Áreas >>>
  List<Area> _areas = []; // Lista de áreas cargadas
  Area? _selectedArea; // Área seleccionada en el Dropdown
  bool _loadingAreas = true; // Indicador de carga para las áreas

  @override
  void initState() {
    super.initState();
    _init = _initialize();
    // <<< CAMBIO: Cargar áreas al iniciar >>>
    _loadAreas();
  }

  // <<< CAMBIO: Nueva función para cargar las áreas >>>
  Future<void> _loadAreas() async {
    setState(() => _loadingAreas = true);
    try {
      final areas = await ServiceLocator.recognition.getAllAreas();
      if (mounted) {
        setState(() {
          _areas = areas;
          _loadingAreas = false;
        });
      }
    } catch (e) {
      print("EnrollScreen: Error cargando áreas: $e");
      if (mounted) setState(() => _loadingAreas = false);
      // Opcional: Mostrar SnackBar de error
    }
  }

  @override
  void dispose() {
    _controller?.stopImageStream();
    _controller?.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    // ... (sin cambios en _initialize) ...
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

  void _onImage(CameraImage image) {
    // ... (sin cambios en _onImage) ...
     if (_processingFace) return;
     _processingFace = true;
     _lastImage = image;

     () async {
       try {
         // <<< CAMBIO: Asegurarse que controller no sea null >>>
         final controller = _controller;
         if (controller == null || !controller.value.isInitialized) {
            _processingFace = false;
            return;
         }
         final input = inputImageFromCameraImage(image, controller.description);
         final faces = await ServiceLocator.faceDetector.detectFaces(input);
         final bool detected = faces.isNotEmpty;

         if (mounted && detected != _facePresent) {
           setState(() {
             _facePresent = detected;
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
         await Future.delayed(const Duration(milliseconds: 10));
          // <<< CAMBIO: Verificar mounted antes de actualizar >>>
         if (mounted) _processingFace = false;
       }
     }();
  }

  Future<void> _captureCurrentPose() async {
    // ... (sin cambios en _captureCurrentPose) ...
      if (_currentPoseIndex >= _posesToCapture.length || _busy) return;

      if (!_facePresent || _lastImage == null) {
        _updateStatus('¡Error! Asegúrese de que su rostro esté visible.');
        return;
      }

       // <<< CAMBIO: Asegurarse que controller no sea null >>>
      final controller = _controller;
      if (controller == null || !controller.value.isInitialized){
         _updateStatus('Error: Cámara no inicializada.');
         return;
      }

      _busy = true;
      _updateStatus('Procesando...');

      try {
        final CameraImage imageToProcess = _lastImage!;
        final InputImage input =
            inputImageFromCameraImage(imageToProcess, controller.description);
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
        _updateStatus('Error procesando captura: $e');
      } finally {
         // <<< CAMBIO: Verificar mounted antes de actualizar >>>
        if (mounted) _busy = false;
      }
  }

  // <<< CAMBIO: _showSaveDialog ahora usa Dropdown para Área >>>
  Future<void> _showSaveDialog(List<List<double>> embeddings, {img.Image? faceImage}) async {
    final String? savedPath = faceImage != null ? await _saveFaceImage(faceImage) : null;
    if (!mounted) return;

    // Controladores (sin cambios aquí)
    final nameController = TextEditingController();
    final docController = TextEditingController();
    final cargoController = TextEditingController();
    final telController = TextEditingController();
    // final areaController = TextEditingController(); // <-- Eliminado
    final epsController = TextEditingController();
    final contactoNombreController = TextEditingController();
    final contactoTelController = TextEditingController();
    final tipoSangreController = TextEditingController();
    final alergiasController = TextEditingController();

    String? docError;
    // Resetear selección de área para el diálogo
    _selectedArea = null;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder( // Usamos StatefulBuilder para actualizar el Dropdown y errores
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
                      decoration: InputDecoration(labelText: 'Documento (Cédula)*', errorText: docError),
                      keyboardType: TextInputType.number,
                    ),
                    TextField(controller: telController, decoration: const InputDecoration(labelText: 'Teléfono'), keyboardType: TextInputType.phone),

                    // <<< INICIO DEL CAMBIO: Dropdown para Área >>>
                    _loadingAreas
                      ? const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: CircularProgressIndicator())
                      : DropdownButtonFormField<Area>(
                          value: _selectedArea, // Área seleccionada actualmente
                          items: _areas.map((Area area) { // Crear un item por cada área en la lista
                            return DropdownMenuItem<Area>(
                              value: area,
                              child: Text(area.nombre),
                            );
                          }).toList(),
                          onChanged: (Area? newValue) {
                            // Actualizar el estado DENTRO del diálogo cuando se selecciona
                            setDialogState(() {
                              _selectedArea = newValue;
                            });
                          },
                          decoration: const InputDecoration(labelText: 'Área de Trabajo'),
                          // Opcional: Añadir validación si se requiere que seleccionen un área
                          // validator: (value) => value == null ? 'Seleccione un área' : null,
                        ),
                    // <<< FIN DEL CAMBIO >>>

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
                    _resetEnrollmentState();
                  },
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final String name = nameController.text.trim();
                    final String document = docController.text.trim();

                    if (name.isEmpty || document.isEmpty) {
                      setDialogState(() => docError = "Nombre y Documento son obligatorios.");
                      return;
                    }

                    // No necesitamos validar el área aquí si es opcional

                    // Validar duplicado de documento
                    // <<< CAMBIO: Verificar si ya existe ANTES de mostrar progreso >>>
                    bool exists = await ServiceLocator.recognition.checkIfDocumentExists(document);
                    if (exists) {
                       setDialogState(() => docError = 'Este documento ya está registrado.');
                       return;
                    } else {
                       setDialogState(() => docError = null);
                    }

                    FocusScope.of(context).unfocus();
                    // Mostrar progreso DESPUÉS de validaciones básicas
                    showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

                    try {
                      // <<< CAMBIO: Obtener el nombre del área seleccionada >>>
                      final String? selectedAreaName = _selectedArea?.nombre;

                      await ServiceLocator.recognition.saveIdentityWithDetails(
                        embeddings: embeddings,
                        imagePath: savedPath,
                        name: name, document: document,
                        cargo: cargoController.text.trim().isEmpty ? null : cargoController.text.trim(),
                        telefono: telController.text.trim().isEmpty ? null : telController.text.trim(),
                        // <<< CAMBIO: Pasar el nombre del área seleccionada >>>
                        areaName: selectedAreaName, // Pasamos el nombre o null
                        eps: epsController.text.trim().isEmpty ? null : epsController.text.trim(),
                        contactoNombre: contactoNombreController.text.trim().isEmpty ? null : contactoNombreController.text.trim(),
                        contactoTelefono: contactoTelController.text.trim().isEmpty ? null : contactoTelController.text.trim(),
                        tipoSangre: tipoSangreController.text.trim().isEmpty ? null : tipoSangreController.text.trim(),
                        alergias: alergiasController.text.trim().isEmpty ? null : alergiasController.text.trim(),
                      );

                       if (mounted) {
                          Navigator.of(context).pop(); // Cerrar progreso
                          Navigator.of(dialogContext).pop(); // Cerrar diálogo save
                          Navigator.of(context).maybePop(); // Volver a Settings
                       }
                    } catch (e) {
                       print("EnrollScreen: Error guardando identidad: $e");
                       if (mounted) {
                          Navigator.of(context).pop(); // Cerrar progreso
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al guardar: $e')));
                       }
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
       // ... (sin cambios en el .then) ...
        if (mounted && _controller != null && !_controller!.value.isStreamingImages) {
          _controller!.startImageStream(_onImage);
        }
    });
  }

  void _resetEnrollmentState() {
     // ... (sin cambios en _resetEnrollmentState) ...
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
      // Resetear área seleccionada también
      _selectedArea = null;
    });
    // Asegurarse de que el stream esté corriendo
    if (_controller != null && !_controller!.value.isStreamingImages) {
       _controller!.startImageStream(_onImage);
    }
    // Volver a cargar las áreas por si se añadió una nueva (aunque no implementamos añadir aquí)
    _loadAreas();
  }


  String _getInstructionForPose(EnrollmentPose pose) {
    // ... (sin cambios en _getInstructionForPose) ...
     switch (pose) {
       case EnrollmentPose.center: return 'Mire al CENTRO y presione Capturar';
       case EnrollmentPose.left: return 'Gire LIGERAMENTE a la IZQUIERDA y presione Capturar';
       case EnrollmentPose.right: return 'Gire LIGERAMENTE a la DERECHA y presione Capturar';
       case EnrollmentPose.up: return 'Incline LIGERAMENTE HACIA ARRIBA y presione Capturar';
       case EnrollmentPose.down: return 'Incline LIGERAMENTE HACIA ABAJO y presione Capturar';
     }
  }

  Future<String?> _saveFaceImage(img.Image imgImage) async {
    // ... (sin cambios en _saveFaceImage) ...
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


  @override
  Widget build(BuildContext context) {
    // ... (sin cambios en build) ...
     final bool isFinished = _currentPoseIndex >= _posesToCapture.length;
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

           return Stack(
             children: [
               Positioned.fill(child: CameraPreview(_controller!)),

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

               Align(
                 alignment: Alignment.bottomCenter,
                 child: Container(
                   color: Colors.black.withOpacity(0.6),
                   padding: const EdgeInsets.all(16),
                   child: Column(
                     mainAxisSize: MainAxisSize.min,
                     children: [
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

                       if (_thumbPng != null)
                         ClipRRect(
                           borderRadius: BorderRadius.circular(8),
                           child: Image.memory( _thumbPng!, width: 72, height: 72, fit: BoxFit.cover,),
                         ),
                       const SizedBox(height: 12),

                       Text(
                         _status,
                         style: const TextStyle(
                             color: Colors.white,
                             fontWeight: FontWeight.bold,
                             fontSize: 16),
                         textAlign: TextAlign.center,
                       ),
                       const SizedBox(height: 16),

                       FilledButton.icon(
                         onPressed: isButtonEnabled
                             ? (isFinished
                                 ? () => _showSaveDialog(_capturedEmbeddings, faceImage: _lastValidCropForSave)
                                 : _captureCurrentPose)
                             : null,
                         icon: Icon(isFinished ? Icons.save : Icons.camera_alt),
                         label: Text(isFinished
                             ? 'Finalizar Registro'
                             : 'Capturar (${_currentPoseIndex + 1}/${_posesToCapture.length})'),
                         style: FilledButton.styleFrom(
                           minimumSize: const Size.fromHeight(50),
                           backgroundColor: isButtonEnabled ? Colors.blue : Colors.grey.shade700,
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
} // Fin _EnrollScreenState