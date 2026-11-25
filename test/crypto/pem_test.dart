// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'package:androidtv_direct/src/crypto/pem.dart';
import 'package:test/test.dart';

void main() {
  test('encodes in lines of 64 characters and decodes back', () {
    final der = List.generate(100, (i) => i);
    final pem = Pem.encode('CERTIFICATE', der);
    final lines = pem.trim().split('\n');
    expect(lines.first, '-----BEGIN CERTIFICATE-----');
    expect(lines.last, '-----END CERTIFICATE-----');
    expect(lines[1], hasLength(64));
    expect(Pem.decode(pem).single.der, der);
  });

  test('reads several blocks, CRLF line ends and text around them', () {
    final text = 'header\r\n${Pem.encode('A', [1])}between\r\n${Pem.encode('B KEY', [2, 3])}'.replaceAll('\n', '\r\n');
    final blocks = Pem.decode(text);
    expect(blocks.map((b) => b.label), ['A', 'B KEY']);
    expect(blocks.map((b) => b.der.toList()), [
      [1],
      [2, 3],
    ]);
  });

  test('a block whose END label differs is not a block', () {
    expect(Pem.decode('-----BEGIN A-----\nAQ==\n-----END B-----\n'), isEmpty);
  });

  test('bad base64 is a format error', () {
    expect(() => Pem.decode('-----BEGIN A-----\n!!!\n-----END A-----\n'), throwsFormatException);
  });
}
