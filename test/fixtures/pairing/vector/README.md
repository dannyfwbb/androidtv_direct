# Pairing test vector

Recorded from an Android TV Remote Service 5.99 on 2026-11-13. With `client.crt.pem` as the client's certificate and `tv.crt.pem` as the TV's, the TV showed the code `FDFD37` and accepted the secret

```
fdb6b5c3613bcff2ada1ae1c5e5489727473995741909bae39adf79f917a632b
```

The SHA-256 fingerprint of the TV's public key (over its SubjectPublicKeyInfo) is

```
cd3c355d08cfdcea3ae0f4ba4bf289fad0ceff28715826334a2514d2101bf3da
```

These files are kept permanently: the vector cannot be made again without the TV that made it.
