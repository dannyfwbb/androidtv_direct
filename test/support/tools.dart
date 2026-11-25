// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:io';

/// External programs used as independent oracles. Tests that need one are skipped, with the reason, when it is not
/// installed.
abstract final class Tools {
  /// `openssl`, if on the PATH.
  static final String? openssl = _find(['openssl']);

  /// `python3`, if on the PATH.
  static final String? python = _find(['python3'], probe: ['--version']);

  /// Skip reason for tests needing [tool] named [name], or null to run.
  static String? skipUnless(String? tool, String name) => tool == null ? '$name is not installed' : null;

  /// Runs [executable] with [arguments] and returns its stdout as text. Throws with its output when it fails, and kills
  /// it after [timeout].
  static Future<String> run(
    String executable,
    List<String> arguments, {
    List<int>? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async => String.fromCharCodes(await runBytes(executable, arguments, stdin: stdin, timeout: timeout));

  /// Like [run] but returns raw stdout bytes.
  static Future<List<int>> runBytes(
    String executable,
    List<String> arguments, {
    List<int>? stdin,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final process = await Process.start(executable, arguments);
    if (stdin != null) process.stdin.add(stdin);
    await process.stdin.close();
    final out = process.stdout.fold<List<int>>([], (a, b) => a..addAll(b));
    final err = process.stderr.fold<List<int>>([], (a, b) => a..addAll(b));
    final code = await process.exitCode.timeout(
      timeout,
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw ProcessException(executable, arguments, 'timed out', -1);
      },
    );
    final stdout = await out;
    if (code != 0) {
      throw ProcessException(
        executable,
        arguments,
        '${String.fromCharCodes(await err)}${String.fromCharCodes(stdout)}',
        code,
      );
    }
    return stdout;
  }

  /// The SHA-256 of the public key in [certificatePem], computed by OpenSSL alone, lower-case hex.
  static Future<String> opensslSpkiFingerprint(String certificatePem) async {
    final publicKey = await runBytes(openssl!, ['x509', '-pubkey', '-noout'], stdin: certificatePem.codeUnits);
    final der = await runBytes(openssl!, ['pkey', '-pubin', '-outform', 'DER'], stdin: publicKey);
    final digest = await run(openssl!, ['dgst', '-sha256', '-hex'], stdin: der);
    return digest.trim().split(' ').last;
  }

  static String? _find(List<String> candidates, {List<String> probe = const ['version']}) {
    for (final candidate in candidates) {
      try {
        final result = Process.runSync(candidate, probe, runInShell: false);
        if (result.exitCode == 0) return candidate;
      } on ProcessException {
        continue;
      }
    }
    return null;
  }
}
