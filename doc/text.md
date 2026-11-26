# Text input

A session with `TvFeature.ime` follows the text field that has the focus on the TV and can type into it. `ime` is not in the default features (some TVs show a "use the keyboard on your phone" notice while a client has it), so ask for it:

```dart
final remote = await TvRemote.connect(host, identity: me, fingerprint: fp, features: {...TvFeature.defaults, TvFeature.ime});

remote.textFieldChanges.listen((field) {
  if (field == null) return;                    // no field has the focus any more
  print('${field.kind}: "${field.text}"');      // password? action key?
});

final field = remote.textField;                 // the focused field now, or null
await field?.setText('nature documentaries');
field?.submit();                                // the field's action key (Search, Done…)
```

## The field

`remote.textField` is a `TvTextField` while a text field on the TV has the focus, and `null` otherwise; `remote.textFieldChanges` gives a new `TvTextField` each time a field gets the focus and `null` when none has it. A field object belongs to one focus: once the focus moves, `isFocused` is false and its calls throw `TvCancelledException`.

- `text`: the field's whole text, as the TV last reported it.
- `selection`: start and end of the selection, in UTF-16 code units (the cursor is `end`); Dart's `String.length` counts the same units.
- `kind`: `password` (text or number password fields), `multiLine`, and `action`, the field's action key (`go`, `search`, `send`, `next`, `done`, `previous`, `none`).
- `keyboardOpen`: whether the TV's own on-screen keyboard is open.
- `changes`: texts the field took other than by `setText` reaching its text: edits made on the TV itself (its remote or keyboard; the TV reports every typed character, so a word arrives as several changes), the reports that follow `insert`, and the TV's text when `setText` gave way to it.

## `setText`

`await field.setText('text')` brings the TV's field to the given text and completes with the field's text once the TV has reported it. How:

1. The TV **inserts** what the client sends at its cursor; it has no "set the whole field" message. So the package keeps the client's wanted text and the TV's reported text, and turns one into the other: Del keys for what differs at the end, then one insert for the rest. Del keys count characters as the user sees them (an emoji with a skin tone is one; one Del removes it whole).
2. If the TV reports the cursor away from the end (or a selected range), the package sends Move End first and waits for the TV's report of the cursor, or 300 ms (the emulator did not report cursor moves). In a multi-line field Move End goes to the end of the cursor's line. This path has not been seen on a TV yet: the emulator always reported the cursor at the end.
3. One step is in flight at a time: the TV accepts an edit only with the field's current revision, which changes with every edit and arrives with the TV's next report. What is wanted meanwhile (calls to `setText` while one runs, as when it is bound to a text box the user types in) is gathered and sent as the next step; all those calls complete together.
4. Del keys go out at most 30 per step; a TV flooded with a few hundred at once was seen to lose some.
5. When an awaited report does not come within `textGiveUp` (1.5 s, a `TvRemote.connect` argument): a deletion is planned again from the TV's text (a lost key), up to three times; an insertion gives way to the TV's text, because the field filtered or limited what was typed. `setText` then completes with the TV's text, which differs from the one asked for, and `changes` reports it.

Some apps' fields replace their whole text with each edit instead of inserting. `setText` then ends at what the TV has, and calling it again reaches the wanted text (it deletes and types the whole text).

Every failure of `setText` comes through its future: `TvCancelledException` when the field lost the focus, `TvNotSupportedException` without `TvFeature.ime` and `TvFeature.key` (Del and Move End are keys), and what ended the session. `insert` and `submit` throw the same synchronously.

## Binding to a text box (Flutter)

```dart
class TvTextBox extends StatefulWidget {
  const TvTextBox({super.key, required this.remote});

  final TvRemote remote;

  @override
  State<TvTextBox> createState() => _TvTextBoxState();
}

class _TvTextBoxState extends State<TvTextBox> {
  final _controller = TextEditingController();
  StreamSubscription<TvTextField?>? _focus;
  StreamSubscription<String>? _changes;
  bool _fromTv = false;

  @override
  void initState() {
    super.initState();
    _follow(widget.remote.textField);                       // a field may have the focus already
    _focus = widget.remote.textFieldChanges.listen(_follow);
    _controller.addListener(_onTyped);
  }

  void _follow(TvTextField? field) {
    _changes?.cancel();
    if (field == null || !field.isFocused) return;
    _show(field.text);
    _changes = field.changes.listen(_show);                 // typed on the TV, or what the field kept
  }

  void _onTyped() {
    if (_fromTv) return;
    widget.remote.textField?.setText(_controller.text).ignore();   // failures: the field or session went away
  }

  void _show(String text) {
    _fromTv = true;
    _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
    _fromTv = false;
  }

  @override
  void dispose() {
    _focus?.cancel();
    _changes?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(controller: _controller);
}
```

## Lower level

- `field.insert('text')` inserts at the cursor with one edit, without waiting for the TV; the TV's report of the result arrives on `changes`.
- `field.submit()` presses Enter, which the field takes as its action key.

## Behaviour seen on the Android TV emulator (remote service 7.00)

- Cyrillic, emoji with skin tones and 200 characters at once arrive intact; a 200-character text was deleted key by key in about 3 seconds.
- The cursor keys and Move Home did not change the selection the TV reports; the TV reports the cursor at the end after every edit.
- An edit sent while no field has the focus is dropped silently; the session goes on.
