// Archivo: lib/src/screens/splash_screen.dart (CON LOGO)
import 'package:flutter/material.dart';
import '../theme/app_theme.dart'; // Para usar kPrimaryColor

class SplashScreen extends StatelessWidget {
  final VoidCallback onStart;

  const SplashScreen({super.key, required this.onStart});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kPrimaryColor, // Fondo con el color principal de SIOMA
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Logo de DataFace (AHORA CON IMAGEN)
            Image.asset(
              'assets/images/logo_dataface.png', // <<< USA EL LOGO
              width: 180, // Ajusta el tamaño si es necesario
              height: 180,
            ),
            const SizedBox(height: 20),
            // Texto de bienvenida
            const Text(
              'Bienvenido',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
             const SizedBox(height: 8),
            // Subtítulo
            const Text(
              'by Data Synergy',
              style: TextStyle(
                fontSize: 16, // Un poco más pequeño
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 50),
            // Botón Comenzar
            ElevatedButton(
              onPressed: onStart,
              style: ElevatedButton.styleFrom(
                foregroundColor: kPrimaryColor,
                backgroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 50, vertical: 18),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
                textStyle: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              child: const Text('Comenzar'),
            ),
          ],
        ),
      ),
    );
  }
}