import 'package:flutter/material.dart';
// <<< CAMBIO: Importar el ServiceLocator >>>
import 'src/services/locator.dart'; 
import 'src/navigation/app_router.dart';
import 'src/theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // <<< CAMBIO IMPORTANTE: Inicializar y esperar a que los servicios estén listos >>>
  try {
    print("Main: Iniciando ServiceLocator...");
    await ServiceLocator.init(); // <-- El 'await' asegura que esperamos
    print("Main: ServiceLocator inicializado correctamente.");
  } catch (e) {
    // Si algo falla DURANTE la inicialización (BD, modelo, etc.), lo veremos aquí
    print("Main: ERROR CRÍTICO inicializando ServiceLocator: $e");
    // Aquí podríamos decidir mostrar una pantalla de error en lugar de la app normal
    // Por ahora, solo lo imprimimos.
  }

  // Ya no necesitamos esto aquí, ServiceLocator se encarga
  // await SharedPreferences.getInstance(); 

  runApp(const FaceAttendanceApp());
}

class FaceAttendanceApp extends StatelessWidget {
  const FaceAttendanceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Asistencia Facial',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routerConfig: buildRouter(),
    );
  }
}