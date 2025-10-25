class RecognizedPerson {
  RecognizedPerson({
    required this.id,
    this.name,
    this.document,
    this.cargo,
    this.telefono,
    this.imagePath,
    this.distance,
    // <<< CAMPOS DE EMERGENCIA Y NUEVOS DETALLES >>>
    this.area,
    this.eps,
    this.contactoNombre,
    this.contactoTelefono,
    this.tipoSangre,
    this.alergias,
  });

  final String id;
  final String? name;
  final String? document;
  final String? cargo;
  final String? telefono;
  final String? imagePath;
  final double? distance;
  // <<< CAMPOS NUEVOS >>>
  final String? area;
  final String? eps;
  final String? contactoNombre;
  final String? contactoTelefono;
  final String? tipoSangre;
  final String? alergias;
}
