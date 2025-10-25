import 'package:flutter/material.dart';
import 'dart:io';
import '../services/locator.dart';
import 'package:file_picker/file_picker.dart';
import 'enroll_screen.dart';
import 'attendance_history_screen.dart';
// <<< CAMBIO: Importar servicios de Flutter para TextInputFormatter >>>
import 'package:flutter/services.dart';

// <<< CAMBIO: Convertido a StatefulWidget >>>
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // <<< CAMBIO: Variables de estado para la autenticación >>>
  bool _isLoading = true; // Empieza cargando para verificar PIN
  bool _isAuthenticated = false; // Solo muestra contenido si es true
  String? _pinError; // Para mostrar errores en el diálogo

  @override
  void initState() {
    super.initState();
    // Al iniciar, verifica si necesita pedir PIN
    _checkAuthentication();
  }

  // <<< CAMBIO: Lógica para verificar/pedir PIN >>>
  Future<void> _checkAuthentication() async {
    setState(() => _isLoading = true);
    final authService = ServiceLocator.auth;
    final bool hasPin = await authService.hasPin();

    if (!mounted) return; // Verificar si el widget sigue montado

    if (hasPin) {
      // Si ya hay PIN, pedirlo
      final bool? authenticated = await _showEnterPinDialog();
      if (authenticated == true && mounted) {
        setState(() {
          _isAuthenticated = true;
          _isLoading = false;
        });
      } else if (mounted) {
        // Si falla o cancela, no mostrar contenido y cerrar pantalla
        Navigator.of(context).pop();
      }
    } else {
      // Si no hay PIN, pedir crearlo
      final bool? pinCreated = await _showCreatePinDialog();
      if (pinCreated == true && mounted) {
        setState(() {
          _isAuthenticated = true; // Autenticado después de crear
          _isLoading = false;
        });
      } else if (mounted) {
        // Si cancela la creación, no mostrar contenido y cerrar pantalla
        Navigator.of(context).pop();
      }
    }
  }

  // --- Diálogo para INGRESAR PIN existente ---
  Future<bool?> _showEnterPinDialog() {
    final pinController = TextEditingController();
    _pinError = null; // Resetear error

    return showDialog<bool>(
      context: context,
      barrierDismissible: false, // No se puede cerrar tocando fuera
      builder: (context) {
        return StatefulBuilder( // Para poder actualizar el error dentro del diálogo
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Ingresar PIN de Acceso'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 6, // Longitud del PIN
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'PIN (6 dígitos)',
                      errorText: _pinError,
                      counterText: '', // Ocultar contador de caracteres
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false), // Cancelar
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final enteredPin = pinController.text;
                    if (enteredPin.length == 6) {
                      final bool verified = await ServiceLocator.auth.verifyPin(enteredPin);
                      if (verified && mounted) {
                        Navigator.of(context).pop(true); // Éxito
                      } else {
                        setDialogState(() {
                          _pinError = 'PIN incorrecto';
                        });
                      }
                    } else {
                       setDialogState(() {
                          _pinError = 'El PIN debe tener 6 dígitos';
                        });
                    }
                  },
                  child: const Text('Desbloquear'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // --- Diálogo para CREAR PIN la primera vez ---
  Future<bool?> _showCreatePinDialog() {
    final pinController = TextEditingController();
    final confirmPinController = TextEditingController();
     _pinError = null;

    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Crear PIN de Acceso'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Cree un PIN numérico de 6 dígitos para proteger la configuración.'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: pinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Nuevo PIN (6 dígitos)',
                       counterText: '',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: confirmPinController,
                    keyboardType: TextInputType.number,
                    obscureText: true,
                    maxLength: 6,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: InputDecoration(
                      labelText: 'Confirmar PIN',
                      errorText: _pinError,
                       counterText: '',
                    ),
                  ),
                ],
              ),
              actions: [
                 TextButton(
                  onPressed: () => Navigator.of(context).pop(false), // Cancelar
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final pin1 = pinController.text;
                    final pin2 = confirmPinController.text;

                    if (pin1.length != 6) {
                      setDialogState(() => _pinError = 'El PIN debe tener 6 dígitos');
                      return;
                    }
                    if (pin1 != pin2) {
                       setDialogState(() => _pinError = 'Los PIN no coinciden');
                       return;
                    }
                    // Si todo está bien, guardar y cerrar
                     setDialogState(() => _pinError = null);
                    await ServiceLocator.auth.setPin(pin1);
                    if (mounted) Navigator.of(context).pop(true); // PIN creado exitosamente
                  },
                  child: const Text('Guardar PIN'),
                ),
              ],
            );
          },
        );
      },
    );
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración'),
      ),
      // <<< CAMBIO: Mostrar contenido solo si está autenticado >>>
      body: _isLoading
          ? const Center(child: CircularProgressIndicator()) // Muestra carga mientras verifica
          : !_isAuthenticated
              ? const Center(child: Text('Acceso bloqueado.')) // Muestra bloqueo si falla PIN
              : _buildSettingsContent(), // Muestra la configuración si pasa PIN
    );
  }

  // <<< CAMBIO: Mover el contenido original a una función separada >>>
  Widget _buildSettingsContent() {
    // El contenido original de tu ListView
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Gestión de empleados',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const EnrollScreen()),
              );
            },
            icon: const Icon(Icons.person_add),
            label: const Text('Registrar Nuevo Empleado'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const AttendanceHistoryScreen()),
              );
            },
            icon: const Icon(Icons.history),
            label: const Text('Historial de Asistencia Local'),
          ),
          const SizedBox(height: 24),
          const Text(
             'Gestión de Áreas',
             style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
           const SizedBox(height: 8),
           OutlinedButton.icon(
             onPressed: () {
               ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Funcionalidad de gestión de áreas próximamente...')));
             },
             icon: const Icon(Icons.business_center),
             label: const Text('Administrar Áreas de Trabajo'),
           ),

          const SizedBox(height: 24),
          const Text(
            'Empleados Registrados (Biometría)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          FutureBuilder<List<Map<String, dynamic>>>(
            future: ServiceLocator.recognition.readAllEmployees(),
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final List<Map<String, dynamic>> employees = snapshot.data ?? const [];

              if (employees.isEmpty) {
                return const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('No hay empleados enrolados'),
                );
              }

              return ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: employees.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final e = employees[index];
                  final String personId = (e['id'] as int).toString();

                  final String? imagePath = e['imagePath'] as String?;
                  final String? name = e['nombre'] as String?;
                  final String? document = e['documento'] as String?;
                  final String? telefono = e['telefono'] as String?;

                  final String subtitleText = [
                    if (document != null && document.isNotEmpty) 'Cédula: $document',
                    if (telefono != null && telefono.isNotEmpty) 'Tel: $telefono',
                    if (e['area'] is String && e['area'].isNotEmpty) 'Área: ${e['area']}',
                  ].join(' | ');

                  return ListTile(
                    leading: CircleAvatar(
                      child: imagePath == null ? const Icon(Icons.person) : null,
                      foregroundImage: imagePath != null ? FileImage(File(imagePath)) : null,
                    ),
                    title: Text(name ?? 'ID: $personId'),
                    subtitle: Text(subtitleText.isEmpty ? 'Sin datos de contacto' : subtitleText),

                    trailing: IconButton(
                      icon: const Icon(Icons.delete, color: Colors.red),
                      onPressed: () async {
                        final bool? ok = await showDialog<bool>(
                          context: context,
                          builder: (_) => AlertDialog(
                            title: const Text('Eliminar empleado'),
                            content: Text('¿Deseas eliminar a "${name ?? personId}" y todos sus datos biométricos?'),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(context).pop(false),
                                child: const Text('Cancelar'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.of(context).pop(true),
                                child: const Text('Eliminar'),
                              ),
                            ],
                          ),
                        );
                        if (ok == true) {
                          await ServiceLocator.recognition.deleteEmployee(personId);
                          // Forzar rebuild para refrescar lista
                           if (mounted) setState(() {});
                        }
                      },
                    ),
                  );
                },
              );
            },
          ),

          // --- SECCIÓN DE MODELO ---
          const SizedBox(height: 24),
          const Text(
            'Modelo',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          if (ServiceLocator.embedder.source == 'asset')
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Modelo embebido'),
              subtitle: Text(
                ServiceLocator.embedder.isLoaded
                    ? 'Cargado desde assets/models/mobilefacenet_112x112_128d.tflite (o fallback)'
                    : 'No cargado',
              ),
            )
          else
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Seleccionar modelo TFLite'),
              subtitle: Text(ServiceLocator.embedder.isLoaded
                  ? (ServiceLocator.embedder.source == 'file' ? 'Modelo cargado desde archivo' : 'Modelo cargado')
                  : (ServiceLocator.embedder.lastError != null
                      ? 'Error: ${ServiceLocator.embedder.lastError}'
                      : 'No cargado')),
              trailing: Icon(
                ServiceLocator.embedder.isLoaded ? Icons.check_circle : Icons.info_outline,
                color: ServiceLocator.embedder.isLoaded ? Colors.green : null,
              ),
              onTap: () async {
                final FilePickerResult? result = await FilePicker.platform.pickFiles(
                  type: FileType.any,
                );
                if (result != null && result.files.single.path != null) {
                  final String path = result.files.single.path!;
                  await ServiceLocator.embedder.loadModelFromFile(path);
                  await ServiceLocator.setCustomModelPath(
                    ServiceLocator.embedder.isLoaded ? path : null,
                  );
                  if (mounted) {
                     setState(() {}); // Forzar rebuild para mostrar estado del modelo
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(ServiceLocator.embedder.isLoaded ? 'Modelo cargado' : 'Error cargando modelo'),
                      ),
                    );
                  }
                }
              },
            ),
        ],
      );
  }
} 