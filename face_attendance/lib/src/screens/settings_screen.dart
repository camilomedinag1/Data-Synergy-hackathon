import 'package:flutter/material.dart';
import 'dart:io';
import '../services/locator.dart';
import 'package:file_picker/file_picker.dart';
import 'enroll_screen.dart';
import 'attendance_history_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuración'),
      ),
      body: ListView(
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
                          (context as Element).markNeedsBuild();
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
                
                // <<< INICIO DEL CAMBIO (ARREGLO PARA PROBLEMA B) >>>
                // Cambiamos FileType.custom por FileType.any para máxima compatibilidad
                // y evitamos el crash que estabas viendo.
                final FilePickerResult? result = await FilePicker.platform.pickFiles(
                  type: FileType.any,
                );
                // <<< FIN DEL CAMBIO >>>

                if (result != null && result.files.single.path != null) {
                  final String path = result.files.single.path!;
                  await ServiceLocator.embedder.loadModelFromFile(path);
                  await ServiceLocator.setCustomModelPath(
                    ServiceLocator.embedder.isLoaded ? path : null,
                  );
                  if (context.mounted) {
                    (context as Element).markNeedsBuild();
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
      ),
    );
  }
}