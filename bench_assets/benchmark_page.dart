// Benchmark harness for saf_stream. Not part of the plugin itself --
// dropped into the example app's lib/ folder so it can drive the real
// SAF read/write paths on a real device.
//
// Flow:
//  1. Pick a folder (SAF tree uri) once.
//  2. Pick a file size + a set of chunk/buffer sizes to try.
//  3. For each chunk size, repeat N times:
//       - write a random blob of the chosen file size, chunked at that size
//       - read it straight back, chunked at that size
//       - record elapsed time for both
//  4. Show a results table (median of the repeats) and let you copy CSV.
//
// Run both variants (before/after JNI) with identical settings, note the
// table (or copy the CSV), compare.

import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:saf_stream/saf_stream.dart';
import 'package:saf_util/saf_util.dart';

class BenchResult {
  BenchResult({
    required this.label,
    required this.chunkSizeBytes,
    required this.fileSizeBytes,
    required this.writeMs,
    required this.readMs,
  });

  final String label;
  final int chunkSizeBytes;
  final int fileSizeBytes;
  final int writeMs;
  final int readMs;

  double get writeMBps => (fileSizeBytes / 1024 / 1024) / (writeMs / 1000);
  double get readMBps => (fileSizeBytes / 1024 / 1024) / (readMs / 1000);
}

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key, required this.buildLabel});

  /// Shown in the app bar / CSV output so you can tell the two APKs apart
  /// (e.g. "orig" vs "jni") when comparing screenshots or exported files.
  final String buildLabel;

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  final _safUtil = SafUtil();
  final _safStream = SafStream();

  String? _treeUri;
  bool _running = false;
  String _status = '';
  final List<BenchResult> _results = [];

  // Chunk/buffer sizes to sweep. Small sizes are where MethodChannel
  // per-call overhead shows up the most.
  final Map<String, int> _chunkSizes = {
    '64 KB': 64 * 1024,
    '256 KB': 256 * 1024,
    '1 MB': 1024 * 1024,
    '4 MB': 4 * 1024 * 1024,
  };
  final Set<String> _selectedChunkLabels = {'64 KB', '256 KB', '1 MB', '4 MB'};

  int _fileSizeMB = 100;
  int _repeats = 3;

  Future<void> _pickFolder() async {
    final dir = await _safUtil.pickDirectory();
    if (dir == null) return;
    setState(() => _treeUri = dir.uri);
  }

  Uint8List _randomBytes(int size) {
    final rnd = Random();
    final data = Uint8List(size);
    // Fill in bulk chunks; Random.nextInt per-byte would itself dominate
    // timing for large sizes, so batch it.
    const batch = 1 << 16;
    for (var i = 0; i < size; i += batch) {
      final len = min(batch, size - i);
      for (var j = 0; j < len; j++) {
        data[i + j] = rnd.nextInt(256);
      }
    }
    return data;
  }

  Future<int> _timedWrite(Uint8List data, int chunkSize, String fileName) async {
    final sw = Stopwatch()..start();
    final info = await _safStream.startWriteStream(
      _treeUri!,
      fileName,
      'application/octet-stream',
      overwrite: true,
    );
    var offset = 0;
    while (offset < data.length) {
      final end = min(offset + chunkSize, data.length);
      await _safStream.writeChunk(info.session, data.sublist(offset, end));
      offset = end;
    }
    await _safStream.endWriteStream(info.session);
    sw.stop();
    return sw.elapsedMilliseconds;
  }

  Future<int> _timedRead(String fileUri, int bufferSize, int expectedBytes) async {
    final sw = Stopwatch()..start();
    var total = 0;
    final stream = await _safStream.readFileStream(fileUri, bufferSize: bufferSize);
    await for (final chunk in stream) {
      total += chunk.length;
    }
    sw.stop();
    if (total != expectedBytes) {
      throw Exception('Byte count mismatch: expected $expectedBytes, got $total');
    }
    return sw.elapsedMilliseconds;
  }

  int _median(List<int> values) {
    final sorted = [...values]..sort();
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return ((sorted[mid - 1] + sorted[mid]) / 2).round();
  }

  Future<void> _runSuite() async {
    if (_treeUri == null) return;
    setState(() {
      _running = true;
      _status = 'Preparing test data...';
      _results.clear();
    });

    final fileSizeBytes = _fileSizeMB * 1024 * 1024;
    // Generate once; reuse the same random payload for every chunk size so
    // the comparison is apples-to-apples.
    final data = _randomBytes(fileSizeBytes);

    for (final label in _selectedChunkLabels) {
      final chunkSize = _chunkSizes[label]!;
      final writeTimes = <int>[];
      final readTimes = <int>[];

      for (var r = 0; r < _repeats; r++) {
        setState(() => _status =
            'Chunk $label — run ${r + 1}/$_repeats (write)...');
        final fileName = 'bench_${chunkSize}_$r.bin';
        try {
          final writeMs = await _timedWrite(data, chunkSize, fileName);
          writeTimes.add(writeMs);

          // Resolve the file we just wrote so we can read it straight back.
          // SAF doesn't give us the child uri from startWriteStream's
          // fileName alone across all vendors reliably, so re-list the dir.
          final files = await _safUtil.list(_treeUri!);
          final match = files.firstWhere((f) => f.name == fileName);

          setState(() => _status =
              'Chunk $label — run ${r + 1}/$_repeats (read)...');
          final readMs = await _timedRead(match.uri, chunkSize, fileSizeBytes);
          readTimes.add(readMs);
        } catch (e) {
          setState(() => _status = 'Error on $label run $r: $e');
        }
      }

      if (writeTimes.isNotEmpty && readTimes.isNotEmpty) {
        setState(() {
          _results.add(BenchResult(
            label: label,
            chunkSizeBytes: chunkSize,
            fileSizeBytes: fileSizeBytes,
            writeMs: _median(writeTimes),
            readMs: _median(readTimes),
          ));
        });
      }
    }

    setState(() {
      _running = false;
      _status = 'Done';
    });
  }

  String _toCsv() {
    final buf = StringBuffer();
    buf.writeln('build,chunk_label,chunk_bytes,file_bytes,write_ms,read_ms,write_MBps,read_MBps');
    for (final r in _results) {
      buf.writeln(
        '${widget.buildLabel},${r.label},${r.chunkSizeBytes},${r.fileSizeBytes},'
        '${r.writeMs},${r.readMs},'
        '${r.writeMBps.toStringAsFixed(2)},${r.readMBps.toStringAsFixed(2)}',
      );
    }
    return buf.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('saf_stream bench [${widget.buildLabel}]')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            OutlinedButton(
              onPressed: _running ? null : _pickFolder,
              child: Text(_treeUri == null ? 'Pick a folder' : 'Folder: $_treeUri'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('File size (MB): '),
                SizedBox(
                  width: 80,
                  child: TextFormField(
                    initialValue: '$_fileSizeMB',
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _fileSizeMB = int.tryParse(v) ?? _fileSizeMB,
                  ),
                ),
                const SizedBox(width: 24),
                const Text('Repeats: '),
                SizedBox(
                  width: 60,
                  child: TextFormField(
                    initialValue: '$_repeats',
                    keyboardType: TextInputType.number,
                    onChanged: (v) => _repeats = int.tryParse(v) ?? _repeats,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: _chunkSizes.keys.map((label) {
                final selected = _selectedChunkLabels.contains(label);
                return FilterChip(
                  label: Text(label),
                  selected: selected,
                  onSelected: (v) => setState(() {
                    if (v) {
                      _selectedChunkLabels.add(label);
                    } else {
                      _selectedChunkLabels.remove(label);
                    }
                  }),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: (_running || _treeUri == null) ? null : _runSuite,
              child: Text(_running ? 'Running...' : 'Run benchmark suite'),
            ),
            const SizedBox(height: 8),
            Text(_status),
            const SizedBox(height: 16),
            if (_results.isNotEmpty) ...[
              Table(
                border: TableBorder.all(color: Colors.grey),
                columnWidths: const {
                  0: FlexColumnWidth(1.2),
                  1: FlexColumnWidth(1.5),
                  2: FlexColumnWidth(1.5),
                  3: FlexColumnWidth(1.5),
                  4: FlexColumnWidth(1.5),
                },
                children: [
                  const TableRow(children: [
                    Padding(padding: EdgeInsets.all(6), child: Text('Chunk', style: TextStyle(fontWeight: FontWeight.bold))),
                    Padding(padding: EdgeInsets.all(6), child: Text('Write ms', style: TextStyle(fontWeight: FontWeight.bold))),
                    Padding(padding: EdgeInsets.all(6), child: Text('Write MB/s', style: TextStyle(fontWeight: FontWeight.bold))),
                    Padding(padding: EdgeInsets.all(6), child: Text('Read ms', style: TextStyle(fontWeight: FontWeight.bold))),
                    Padding(padding: EdgeInsets.all(6), child: Text('Read MB/s', style: TextStyle(fontWeight: FontWeight.bold))),
                  ]),
                  for (final r in _results)
                    TableRow(children: [
                      Padding(padding: const EdgeInsets.all(6), child: Text(r.label)),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${r.writeMs}')),
                      Padding(padding: const EdgeInsets.all(6), child: Text(r.writeMBps.toStringAsFixed(2))),
                      Padding(padding: const EdgeInsets.all(6), child: Text('${r.readMs}')),
                      Padding(padding: const EdgeInsets.all(6), child: Text(r.readMBps.toStringAsFixed(2))),
                    ]),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: _toCsv()));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('CSV copied to clipboard')),
                  );
                },
                child: const Text('Copy results as CSV'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
