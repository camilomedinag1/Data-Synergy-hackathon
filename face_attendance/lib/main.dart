import 'package:flutter/material.dart';
// <<< CAMBIO: Importar ServiceLocator y SplashScreen >>>
import 'src/services/locator.dart';
import 'src/navigation/app_router.dart';
import 'src/theme/app_theme.dart';
import 'src/screens/splash_screen.dart'; // Importar la pantalla Splash
import 'dart:async'; // Importar Timer

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    print("Main: Iniciando ServiceLocator...");
    // Esperar a que los servicios estén listos ANTES de mostrar nada
    await ServiceLocator.init();
    print("Main: ServiceLocator inicializado correctamente.");
  } catch (e) {
    print("Main: ERROR CRÍTICO inicializando ServiceLocator: $e");
    // Considerar mostrar una pantalla de error aquí
  }
  runApp(const FaceAttendanceApp());
}

// <<< CAMBIO: Convertido a StatefulWidget para manejar el estado del Splash >>>
class FaceAttendanceApp extends StatefulWidget {
  const FaceAttendanceApp({super.key});

  @override
  State<FaceAttendanceApp> createState() => _FaceAttendanceAppState();
}

class _FaceAttendanceAppState extends State<FaceAttendanceApp> {
  // Estado para controlar si se muestra el splash
  bool _showSplash = true;

  @override
  void initState() {
    super.initState();
    // Iniciar un temporizador para ocultar el splash después de 3 segundos
    Timer(const Duration(seconds: 3), () {
      // Comprobar si el widget todavía está montado antes de cambiar el estado
      if (mounted) {
        setState(() {
          _showSplash = false; // Cambiar estado para mostrar la app principal
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Mostrar SplashScreen o la MaterialApp principal según el estado
    if (_showSplash) {
      // Muestra el SplashScreen
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        home: SplashScreen(onStart: () {
           // Si el usuario presiona "Comenzar" antes de que acabe el timer
           if (mounted) { setState(() => _showSplash = false); }
        }),
      );
    } else {
      // Muestra la app principal con el router
      return MaterialApp.router(
        title: 'DataFace', // Nombre actualizado de la app
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        routerConfig: buildRouter(), // Usar el router existente
      );
    }
  }
}