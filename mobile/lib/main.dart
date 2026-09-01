import 'package:flutter/widgets.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // The assistant initializes itself lazily and degrades on its own, so
  // nothing AI-related runs before the app is on screen. A missing or
  // unsupported runtime can never delay or block startup.
  runApp(SwasthyaShieldApp.replay());
}
