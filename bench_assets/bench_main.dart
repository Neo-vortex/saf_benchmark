// Separate entry point so the normal example app (lib/main.dart) is left
// untouched. Build/run this one specifically for benchmarking:
//   flutter run -t lib/bench_main.dart --release
//   flutter build apk --release -t lib/bench_main.dart
import 'package:flutter/material.dart';

import 'benchmark_page.dart';

// BENCH_BUILD_LABEL is substituted by the driver script (orig/jni) so the
// two APKs are visually distinguishable and CSV exports are labeled.
const String kBenchBuildLabel = 'BENCH_BUILD_LABEL';

void main() {
  runApp(const BenchApp());
}

class BenchApp extends StatelessWidget {
  const BenchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'saf_stream bench',
      home: const BenchmarkPage(buildLabel: kBenchBuildLabel),
    );
  }
}
