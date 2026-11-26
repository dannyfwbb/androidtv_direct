// Copyright 2026 The androidtv_direct authors
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';

import 'package:androidtv_direct/src/protocol/remote_messages.dart';
import 'package:androidtv_direct/src/remote/features.dart';
import 'package:androidtv_direct/src/remote/session.dart';

/// The longest link [sendLink] sends, in bytes of UTF-8.
const int maxLinkBytes = 8192;

/// Sends [link] in [session], after checking it and the `appLink` feature.
void sendLink(RemoteSession session, String link) {
  if (link.isEmpty) throw ArgumentError.value(link, 'link', 'is empty');
  if (utf8.encode(link).length > maxLinkBytes) {
    throw ArgumentError.value(link, 'link', 'is longer than $maxLinkBytes bytes in UTF-8');
  }
  session
    ..require(TvFeature.appLink)
    ..send(OpenLinkMessage(link: link));
}
