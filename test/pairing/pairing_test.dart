// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:async';
import 'dart:io';

import 'package:androidtv_direct/androidtv_direct.dart';
import 'package:androidtv_direct/src/bytes.dart';
import 'package:androidtv_direct/src/crypto/pairing_secret.dart';
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/fake_pairing.dart';
import '../support/fake_tv.dart';
import '../support/fixtures.dart';
import '../support/wait.dart';

void main() {
  final identity = testClient();
  final tvFingerprint = TvIdentity.fromCertificate(pemOf(testIdentity('tv').certificatePem)).fingerprint;

  Future<(FakeTv, FakePairing)> fakeTv([FakePairing? pairing]) async {
    final fake = pairing ?? FakePairing();
    return (await startFakeTv(onPairing: fake.serve), fake);
  }

  Future<TvPairing> start(FakeTv tv, {TvClock clock = TvClock.system, Future<void>? cancelOn}) => TvPairing.start(
    InternetAddress.loopbackIPv4,
    port: tv.pairingPort,
    identity: identity,
    clientName: 'Test Remote',
    clock: clock,
    cancelOn: cancelOn,
  );

  test('pairs: the TV shows a code, the right code returns the TV and its fingerprint', () async {
    final (tv, fake) = await fakeTv();
    final pairing = await start(tv);
    expect(fake.clientName, 'Test Remote');
    expect(pairing.tv.fingerprint, tvFingerprint);
    final result = await pairing.finish((await fake.code.future).toLowerCase());
    expect(result.fingerprint, tvFingerprint);
    expect(pairing.isOpen, isFalse);
    expect(tv.errors, isEmpty);
  });

  test('a code that cannot be right is refused locally, and the pairing stays open', () async {
    final (tv, fake) = await fakeTv();
    final pairing = await start(tv);
    final code = await fake.code.future;
    for (final wrong in ['', '12345', '1234567', 'GGGGGG', codeWithWrongCheckByte(code)]) {
      await expectLater(pairing.finish(wrong), throwsA(isA<TvWrongCodeException>()), reason: wrong);
      expect(pairing.isOpen, isTrue);
    }
    expect(fake.secretReceived, isFalse);
    expect((await pairing.finish(code)).fingerprint, tvFingerprint);
  });

  test('a wrong code that passes the check byte is refused by the TV with 402', () async {
    final (tv, fake) = await fakeTv();
    final pairing = await start(tv);
    final code = await fake.code.future;
    final otherNonce = [int.parse(code.substring(2, 4), radix: 16) ^ 1, int.parse(code.substring(4), radix: 16)];
    final hash = pairingHash(client: identity.publicKey, tv: pairing.tv.publicKey, nonce: otherNonce);
    await expectLater(
      pairing.finish(hexEncode([hash[0], ...otherNonce])),
      throwsA(isA<TvPairingRefusedException>().having((e) => e.status, 'status', 402)),
    );
    expect(pairing.isOpen, isFalse);
    expect(() => pairing.finish(code), throwsStateError);
  });

  test('an acknowledgement without the echo still pairs; a different echo is a protocol error', () async {
    final (silentTv, silent) = await fakeTv(FakePairing(faultAt: PairingStep.secret, fault: PairingFault.noEcho));
    final first = await start(silentTv);
    expect((await first.finish(await silent.code.future)).fingerprint, tvFingerprint);
    final (wrongTv, wrong) = await fakeTv(FakePairing(faultAt: PairingStep.secret, fault: PairingFault.wrongEcho));
    final second = await start(wrongTv);
    await expectLater(second.finish(await wrong.code.future), throwsA(isA<TvProtocolException>()));
  });

  group('a TV that misbehaves', () {
    final expected = {
      PairingFault.errorStatus: isA<TvPairingRefusedException>().having((e) => e.status, 'status', 400),
      PairingFault.close: isA<TvPairingRefusedException>().having((e) => e.status, 'status', isNull),
      PairingFault.garbage: isA<TvProtocolException>(),
      PairingFault.unexpected: isA<TvProtocolException>(),
      PairingFault.silence: isA<TvTimeoutException>(),
    };

    for (final step in PairingStep.values) {
      for (final MapEntry(key: fault, value: matcher) in expected.entries) {
        test('${fault.name} at ${step.name}', () async {
          final (tv, fake) = await fakeTv(FakePairing(faultAt: step, fault: fault));
          final clock = FakeClock();
          final outcome = _run(start(tv, clock: clock), fake, step);
          if (fault == PairingFault.silence) {
            await until(() => fake.reached == step && clock.pendingTimers > 0);
            clock.advance(const Duration(seconds: 10));
          }
          await expectLater(outcome, throwsA(matcher));
        });
      }
    }
  });

  test('a TV that closes while the user reads the code ends the pairing', () async {
    final closeNow = Completer<void>();
    final fake = FakePairing();
    final tv = await startFakeTv(
      onPairing: (c) async {
        unawaited(fake.serve(c));
        await closeNow.future;
        await c.close();
      },
    );
    final pairing = await start(tv);
    closeNow.complete();
    await until(() => !pairing.isOpen);
    await expectLater(pairing.finish(await fake.code.future), throwsA(isA<TvPairingRefusedException>()));
  });

  test('cancel closes the connection; the pairing is over', () async {
    final (tv, fake) = await fakeTv();
    final pairing = await start(tv);
    await pairing.cancel();
    expect(pairing.isOpen, isFalse);
    expect(() => pairing.finish('000000'), throwsStateError);
    await pairing.cancel();
    expect(fake.secretReceived, isFalse);
  });

  test('cancel during finish is a cancellation, not a refusal', () async {
    final (tv, fake) = await fakeTv(FakePairing(faultAt: PairingStep.secret, fault: PairingFault.silence));
    final pairing = await start(tv);
    final outcome = pairing.finish(await fake.code.future);
    await until(() => fake.reached == PairingStep.secret);
    await pairing.cancel();
    await expectLater(outcome, throwsA(isA<TvCancelledException>()));
  });

  test('a second finish while one runs is a state error', () async {
    final (tv, fake) = await fakeTv(FakePairing(faultAt: PairingStep.secret, fault: PairingFault.silence));
    final pairing = await start(tv);
    final code = await fake.code.future;
    final first = pairing.finish(code);
    expect(() => pairing.finish(code), throwsStateError);
    await pairing.cancel();
    await expectLater(first, throwsA(isA<TvCancelledException>()));
  });

  test('cancelOn stops a start that waits for the TV', () async {
    final (tv, fake) = await fakeTv(FakePairing(faultAt: PairingStep.request, fault: PairingFault.silence));
    final cancel = Completer<void>();
    final outcome = start(tv, cancelOn: cancel.future);
    await until(() => fake.reached == PairingStep.request);
    cancel.complete();
    await expectLater(outcome, throwsA(isA<TvCancelledException>()));
  });

  test('cancelOn completing after start returned leaves the pairing alone', () async {
    final (tv, fake) = await fakeTv();
    final cancel = Completer<void>();
    final pairing = await start(tv, cancelOn: cancel.future);
    cancel.complete();
    await Future<void>.delayed(Duration.zero);
    expect(pairing.isOpen, isTrue);
    expect((await pairing.finish(await fake.code.future)).fingerprint, tvFingerprint);
  });

  test('a port where nothing listens has no service', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    await server.close();
    await expectLater(
      TvPairing.start(InternetAddress.loopbackIPv4, port: port, identity: identity, clientName: 'x'),
      throwsA(isA<TvNoServiceException>()),
    );
  });
}

/// [start]'s outcome, finishing with the shown code when the fault is at the secret step.
Future<void> _run(Future<TvPairing> start, FakePairing fake, PairingStep step) async {
  final pairing = await start;
  if (step == PairingStep.secret) await pairing.finish(await fake.code.future);
}
