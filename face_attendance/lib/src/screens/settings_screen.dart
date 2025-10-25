import 'package:flutter/material.dart';
import 'dart:io';
import '../services/locator.dart';
import '../services/recognition_service.dart' show Area; // Importar Area
// import 'package:file_picker/file_picker.dart'; // Ya no se usa
import 'enroll_screen.dart';
import 'attendance_history_screen.dart';
import 'package:flutter/services.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _isLoading = true;
  bool _isAuthenticated = false;
  String? _pinError;
  List<Area> _areas = [];
  // bool _loadingAreas = true; // Ya no necesitamos este bool aquí

  @override
  void initState() {
    super.initState();
    _checkAuthentication();
    _loadAreas();
  }

  Future<void> _loadAreas() async {
    try {
      final areas = await ServiceLocator.recognition.getAllAreas();
      if (mounted) {
        setState(() {
          _areas = areas;
        });
      }
    } catch (e) {
      print("SettingsScreen: Error cargando áreas: $e");
    }
  }

  Future<void> _checkAuthentication() async {
    // ... (sin cambios) ...
      setState(() => _isLoading = true);
      final authService = ServiceLocator.auth;
      final bool hasPin = await authService.hasPin();

      if (!mounted) return;

      if (hasPin) {
        final bool? authenticated = await _showEnterPinDialog();
        if (authenticated == true && mounted) {
          setState(() {
            _isAuthenticated = true;
            _isLoading = false;
          });
        } else if (mounted) {
          Navigator.of(context).pop();
        }
      } else {
        final bool? pinCreated = await _showCreatePinDialog();
        if (pinCreated == true && mounted) {
          setState(() {
            _isAuthenticated = true;
            _isLoading = false;
          });
        } else if (mounted) {
          Navigator.of(context).pop();
        }
      }
  }

  Future<bool?> _showEnterPinDialog() {
      // ... (sin cambios) ...
       final pinController = TextEditingController();
       _pinError = null;

       return showDialog<bool>(
         context: context,
         barrierDismissible: false,
         builder: (context) {
           return StatefulBuilder(
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
                       maxLength: 6,
                       inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                       decoration: InputDecoration(
                         labelText: 'PIN (6 dígitos)',
                         errorText: _pinError,
                         counterText: '',
                       ),
                     ),
                   ],
                 ),
                 actions: [
                   TextButton(
                     onPressed: () => Navigator.of(context).pop(false),
                     child: const Text('Cancelar'),
                   ),
                   FilledButton(
                     onPressed: () async {
                       final enteredPin = pinController.text;
                       if (enteredPin.length == 6) {
                         final bool verified = await ServiceLocator.auth.verifyPin(enteredPin);
                         if (verified && mounted) {
                           Navigator.of(context).pop(true);
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

  Future<bool?> _showCreatePinDialog() {
     // ... (sin cambios) ...
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
                    onPressed: () => Navigator.of(context).pop(false),
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
                       setDialogState(() => _pinError = null);
                      await ServiceLocator.auth.setPin(pin1);
                      if (mounted) Navigator.of(context).pop(true);
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

  Future<Map<String?, List<Map<String, dynamic>>>> _loadEmployeesAndGroup() async {
    // ... (sin cambios) ...
      final employees = await ServiceLocator.recognition.readAllEmployees();
      final grouped = <String?, List<Map<String, dynamic>>>{};

      for (final emp in employees) {
        final String? areaName = emp['area'] as String?;
        grouped.putIfAbsent(areaName, () => []).add(emp);
      }
       final sortedKeys = grouped.keys.toList()
        ..sort((a, b) {
          if (a == null) return 1;
          if (b == null) return -1;
          return a.compareTo(b);
        });

       final sortedGrouped = <String?, List<Map<String, dynamic>>>{};
       for(final key in sortedKeys){
          final list = grouped[key]!;
          list.sort((a,b) => (a['nombre'] as String? ?? '').compareTo(b['nombre'] as String? ?? ''));
          sortedGrouped[key] = list;
       }
      return sortedGrouped;
  }

  Future<void> _showEditEmployeeDialog(Map<String, dynamic> employeeData) async {
    // ... (sin cambios) ...
     final int employeeId = employeeData['id'] as int;
     final String currentName = employeeData['nombre'] as String? ?? '';
     final String currentDoc = employeeData['documento'] as String? ?? '';
     final String? currentCargo = employeeData['cargo'] as String?;
     final String? currentTel = employeeData['telefono'] as String?;
     final String? currentAreaName = employeeData['area'] as String?;
     final String? currentEps = employeeData['eps'] as String?;
     final String? currentContactoNombre = employeeData['contacto_emergencia_nombre'] as String?;
     final String? currentContactoTel = employeeData['contacto_emergencia_telefono'] as String?;
     final String? currentTipoSangre = employeeData['tipo_sangre'] as String?;
     final String? currentAlergias = employeeData['alergias'] as String?;
     final String? imagePath = employeeData['imagePath'] as String?;

     final nameController = TextEditingController(text: currentName);
     final docController = TextEditingController(text: currentDoc);
     final cargoController = TextEditingController(text: currentCargo);
     final telController = TextEditingController(text: currentTel);
     final epsController = TextEditingController(text: currentEps);
     final contactoNombreController = TextEditingController(text: currentContactoNombre);
     final contactoTelController = TextEditingController(text: currentContactoTel);
     final tipoSangreController = TextEditingController(text: currentTipoSangre);
     final alergiasController = TextEditingController(text: currentAlergias);

     Area? findAreaByName(String? name) {
       if (name == null || name.isEmpty) return null;
       try {
         return _areas.firstWhere((a) => a.nombre == name);
       } catch (e) {
         return null;
       }
     }
     Area? selectedArea = findAreaByName(currentAreaName);

     String? docError;

     await showDialog<void>(
       context: context,
       barrierDismissible: false,
       builder: (BuildContext dialogContext) {
         return StatefulBuilder(
           builder: (context, setDialogState) {
             return AlertDialog(
               title: const Text('Editar Empleado'),
               content: SingleChildScrollView(
                 child: Column(
                   mainAxisSize: MainAxisSize.min,
                   children: [
                     TextField(controller: nameController, decoration: const InputDecoration(labelText: 'Nombre Completo*')),
                     TextField(controller: docController, readOnly: true, decoration: InputDecoration(labelText: 'Documento (Cédula)*', errorText: docError), keyboardType: TextInputType.number),
                     TextField(controller: telController, decoration: const InputDecoration(labelText: 'Teléfono'), keyboardType: TextInputType.phone),
                     DropdownButtonFormField<Area>(
                         value: selectedArea,
                         items: _areas.map((Area area) {
                           return DropdownMenuItem<Area>(value: area, child: Text(area.nombre));
                         }).toList(),
                         onChanged: (Area? newValue) {
                           setDialogState(() => selectedArea = newValue);
                         },
                         decoration: const InputDecoration(labelText: 'Área de Trabajo'),
                       ),
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
                 TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancelar')),
                 FilledButton(
                   onPressed: () async {
                     final String name = nameController.text.trim();
                     final String document = docController.text.trim();
                     if (name.isEmpty) { setDialogState(() => docError = "Nombre es obligatorio."); return; }
                     setDialogState(() => docError = null);
                     FocusScope.of(context).unfocus();
                     showDialog(context: context, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
                     try {
                       await ServiceLocator.recognition.upsertEmployee(
                         documento: document, nombre: name,
                         cargo: cargoController.text.trim().isEmpty ? null : cargoController.text.trim(),
                         telefono: telController.text.trim().isEmpty ? null : telController.text.trim(),
                         areaName: selectedArea?.nombre,
                         eps: epsController.text.trim().isEmpty ? null : epsController.text.trim(),
                         contactoNombre: contactoNombreController.text.trim().isEmpty ? null : contactoNombreController.text.trim(),
                         contactoTelefono: contactoTelController.text.trim().isEmpty ? null : contactoTelController.text.trim(),
                         tipoSangre: tipoSangreController.text.trim().isEmpty ? null : tipoSangreController.text.trim(),
                         alergias: alergiasController.text.trim().isEmpty ? null : alergiasController.text.trim(),
                       );
                        if (mounted) { Navigator.of(context).pop(); Navigator.of(dialogContext).pop(); setState(() {}); }
                     } catch (e) {
                        print("SettingsScreen: Error actualizando empleado: $e");
                        if (mounted) { Navigator.of(context).pop(); ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al actualizar: $e'))); }
                     }
                   },
                   child: const Text('Guardar Cambios'),
                 ),
               ],
             );
           },
         );
       },
     );
  }

  // <<< CAMBIO: Diálogo para AÑADIR nueva Área >>>
  Future<void> _showAddAreaDialog() async {
    final areaNameController = TextEditingController();
    String? areaError;

    final bool? created = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Añadir Nueva Área'),
              content: TextField(
                controller: areaNameController,
                decoration: InputDecoration(
                  labelText: 'Nombre del Área',
                  errorText: areaError,
                ),
                textCapitalization: TextCapitalization.words, // Poner mayúscula inicial
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false), // Cancelar
                  child: const Text('Cancelar'),
                ),
                FilledButton(
                  onPressed: () async {
                    final String name = areaNameController.text.trim();
                    if (name.isEmpty) {
                      setDialogState(() => areaError = 'El nombre no puede estar vacío');
                      return;
                    }
                    // Verificar si ya existe (insensible a mayúsculas/minúsculas)
                    final exists = _areas.any((a) => a.nombre.toLowerCase() == name.toLowerCase());
                    if (exists) {
                       setDialogState(() => areaError = 'Esta área ya existe');
                       return;
                    }

                    // Si es válido, intentar crearla
                    setDialogState(() => areaError = null);
                    try {
                      final newAreaId = await ServiceLocator.recognition.getOrCreateArea(name);
                      if (newAreaId != null && mounted) {
                        Navigator.of(dialogContext).pop(true); // Indicar éxito
                      } else if (mounted) {
                        // Si getOrCreateArea devuelve null (error raro), mostrar mensaje
                         Navigator.of(dialogContext).pop(false);
                         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Error al crear el área')));
                      }
                    } catch (e) {
                       print("SettingsScreen: Error en diálogo al crear área: $e");
                       if(mounted) Navigator.of(dialogContext).pop(false);
                       ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
                    }
                  },
                  child: const Text('Crear Área'),
                ),
              ],
            );
          },
        );
      },
    );

    // Si el diálogo indicó éxito (created == true), recargar áreas y refrescar UI
    if (created == true) {
      await _loadAreas(); // Recarga la lista de áreas para incluir la nueva
      if (mounted) setState(() {}); // Refresca la pantalla principal de Settings
    }
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configuración')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : !_isAuthenticated
              ? const Center(child: Text('Acceso bloqueado.'))
              : _buildSettingsContent(),
    );
  }

  Widget _buildSettingsContent() {
    return ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // --- Sección Gestión Empleados ---
          const Text('Gestión de empleados', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const EnrollScreen())),
            icon: const Icon(Icons.person_add), label: const Text('Registrar Nuevo Empleado'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AttendanceHistoryScreen())),
            icon: const Icon(Icons.history), label: const Text('Historial de Asistencia Local'),
          ),
          const SizedBox(height: 24),

          // --- Sección Gestión Áreas ---
          const Text('Gestión de Áreas', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
           const SizedBox(height: 8),
           OutlinedButton.icon(
             // <<< CAMBIO: Llamar al diálogo para añadir área >>>
             onPressed: _showAddAreaDialog,
             icon: const Icon(Icons.add_business_outlined), // Icono cambiado
             label: const Text('Añadir Nueva Área'), // Texto cambiado
           ),
           // TODO: Añadir aquí la lista de áreas con opción de eliminar/editar si da tiempo
          const SizedBox(height: 24),

          // --- Sección Empleados Registrados (Agrupados) ---
          const Text('Empleados Registrados', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          FutureBuilder<Map<String?, List<Map<String, dynamic>>>>(
            future: _loadEmployeesAndGroup(),
            builder: (context, snapshot) {
              // ... (resto del FutureBuilder sin cambios) ...
               if (snapshot.connectionState != ConnectionState.done) {
                 return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator()));
               }
               if (snapshot.hasError) {
                  return ListTile(leading: Icon(Icons.error, color: Colors.red), title: Text('Error cargando empleados: ${snapshot.error}'));
               }
               final groupedEmployees = snapshot.data ?? {};
               if (groupedEmployees.isEmpty) {
                 return const ListTile(leading: Icon(Icons.info_outline), title: Text('No hay empleados enrolados'));
               }
               return ListView.builder(
                 shrinkWrap: true,
                 physics: const NeverScrollableScrollPhysics(),
                 itemCount: groupedEmployees.length,
                 itemBuilder: (context, index) {
                   final areaName = groupedEmployees.keys.elementAt(index);
                   final employeesInArea = groupedEmployees[areaName]!;
                   final String areaTitle = areaName ?? 'Sin Área Asignada';
                   return ExpansionTile(
                     title: Text(areaTitle, style: TextStyle(fontWeight: FontWeight.bold, color: Theme.of(context).colorScheme.primary)),
                     initiallyExpanded: true,
                     children: employeesInArea.map((e) {
                       final String personId = (e['id'] as int).toString();
                       final String? imagePath = e['imagePath'] as String?;
                       final String? name = e['nombre'] as String?;
                       final String? document = e['documento'] as String?;
                       final String? telefono = e['telefono'] as String?;
                       final String subtitleText = [
                         if (document != null && document.isNotEmpty) 'Cédula: $document',
                         if (telefono != null && telefono.isNotEmpty) 'Tel: $telefono',
                       ].where((s) => s.isNotEmpty).join(' | ');
                       return ListTile(
                         leading: CircleAvatar(
                           child: imagePath == null ? const Icon(Icons.person) : null,
                           foregroundImage: imagePath != null ? FileImage(File(imagePath)) : null,
                         ),
                         title: Text(name ?? 'ID: $personId'),
                         subtitle: Text(subtitleText.isEmpty ? 'Sin datos de contacto' : subtitleText),
                         trailing: Row(
                           mainAxisSize: MainAxisSize.min,
                           children: [
                             IconButton(
                               icon: Icon(Icons.edit, color: Theme.of(context).colorScheme.primary),
                               tooltip: 'Editar Empleado',
                               onPressed: () => _showEditEmployeeDialog(e),
                             ),
                             IconButton(
                               icon: const Icon(Icons.delete, color: Colors.red),
                               tooltip: 'Eliminar Empleado',
                               onPressed: () async {
                                 final bool? ok = await showDialog<bool>(
                                   context: context,
                                   builder: (_) => AlertDialog(
                                      title: const Text('Eliminar empleado'),
                                      content: Text('¿Deseas eliminar a "${name ?? personId}" y todos sus datos biométricos?'),
                                      actions: [
                                        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
                                        FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Eliminar')),
                                      ],
                                   ),
                                 );
                                 if (ok == true) {
                                   await ServiceLocator.recognition.deleteEmployee(personId);
                                   if (mounted) setState(() {});
                                 }
                               },
                             ),
                           ],
                         ),
                       );
                     }).toList(),
                   );
                 },
               );
            },
          ), // Fin FutureBuilder Empleados

          // --- SECCIÓN DE MODELO (sin cambios) ---
          const SizedBox(height: 24),
          const Text('Modelo', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
           if (ServiceLocator.embedder.source == 'asset')
            ListTile(
              leading: const Icon(Icons.check_circle, color: Colors.green),
              title: const Text('Modelo embebido'),
              subtitle: Text( ServiceLocator.embedder.isLoaded ? 'Cargado desde assets/models/mobilefacenet_112x112_128d.tflite (o fallback)' : 'No cargado', ),
            )
          else
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Seleccionar modelo TFLite'),
              subtitle: Text(ServiceLocator.embedder.isLoaded ? (ServiceLocator.embedder.source == 'file' ? 'Modelo cargado desde archivo' : 'Modelo cargado') : (ServiceLocator.embedder.lastError != null ? 'Error: ${ServiceLocator.embedder.lastError}' : 'No cargado')),
              trailing: Icon( ServiceLocator.embedder.isLoaded ? Icons.check_circle : Icons.info_outline, color: ServiceLocator.embedder.isLoaded ? Colors.green : null, ),
              onTap: () async {
                 ScaffoldMessenger.of(context).showSnackBar( const SnackBar(content: Text('La selección de modelo personalizado está deshabilitada.')) );
              },
            ),
        ],
      );
  }
} // Fin _SettingsScreenState