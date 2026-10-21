import 'dart:io';
import 'dart:typed_data';

/// Reads [length] bytes of the local projector file at [location] from
/// [offset]; returns fewer at its end.
Future<Uint8List> readProjectorFileRange(
  String location,
  int offset,
  int length,
) async {
  final file = await File(location).open();
  try {
    await file.setPosition(offset);
    return await file.read(length);
  } finally {
    await file.close();
  }
}
