import 'package:flutter/widgets.dart';

import 'llamadart_studio.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installStudioProductionErrorHandlers();
  final dependencies = await StudioDependencies.bootstrapProduction();
  runApp(LlamadartStudioApp(dependencies: dependencies));
}
