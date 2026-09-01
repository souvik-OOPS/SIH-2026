import 'package:flutter/widgets.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:flutter_gemma_builtin_ai/flutter_gemma_builtin_ai.dart';
import 'package:flutter_gemma_litertlm/flutter_gemma_litertlm.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // The AI layer is optional. If engine registration fails on this device the
  // app still starts, monitors, and escalates — the assistant simply degrades
  // to its offline knowledge base.
  try {
    await FlutterGemma.initialize(
      inferenceEngines: [BuiltInAiEngine(), LiteRtLmEngine()],
    );
  } on Object catch (error) {
    debugPrint('[assistant] engine registration failed: $error');
  }

  runApp(SwasthyaShieldApp.replay());
}
