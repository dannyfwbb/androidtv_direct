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

1. An edit names a range of the field and the text that replaces it, in UTF-16 code units; the TV replaces the range wherever the cursor is. The package keeps the client's wanted text and the TV's reported text and turns one into the other in steps that cut between characters as the user sees them (an emoji with a skin tone is never split): first one edit deletes what differs after their common beginning, then one edit adds the rest.
2. The steps are shaped around how the TV behaves. It reports a change only when the length changes, so a deletion and an addition never go in one edit: a field that cuts or filters it could end at the old length with another text, unreported. An empty range inserts at the cursor, so an addition goes with the character before it. An empty replacement that starts at the cursor is ignored, so a deletion puts back the character before it too. Only emptying the whole field depends on the cursor: if the TV reports it at the start, or the emptying stalls, a placeholder goes first.
3. One step is in flight at a time: the TV accepts an edit only with the field's current revision, which changes with every edit and arrives with the TV's next report. What is wanted meanwhile (calls to `setText` while one runs, as when it is bound to a text box the user types in) is gathered and sent as the next step; all those calls complete together.
4. Each edit is answered by one report. A report other than the planned one, or none in time, means the field filtered or limited what was typed: the TV's text wins, `setText` completes with it, and `changes` reports it. "In time" is at least `textGiveUp` (1.5 s, a `TvRemote.connect` argument), and as long as the TV's answers take on a slower network: the session measures them from its start, as TCP measures its round trip (a smoothed time plus four times its variation, at most 10 s). A report that still comes after the wait ran out is recognised when it brings exactly the text of the step given up on: its time is measured too, and if the next edit was already on its way, that edit carried the revision from before and the TV dropped it, so it goes again. Checked on the emulator through a proxy adding up to 1.5 s each way.
5. A TV that inserts an edit with a range at its cursor does not take ranges: it gets keys for the rest of the session, Del keys for what differs at the end (at most 30 per step, since a TV flooded with a few hundred was seen to lose some), then one insert at the cursor. Keys carry no revision, so a batch is never sent twice while it may still land: a deletion always changes the length and so is always reported, a batch with no report yet is waited for up to 10 s, and only one whose reports stopped partway has the rest planned again (up to three times; those keys were lost). A report that is not one more key deleted, such as the cursor's, counts for nothing. Keys assume the cursor at the end, so if the TV reports it elsewhere the package sends Move End first, between steps, and waits for the TV's report of the cursor, at least 300 ms and as long as the TV's answers take.

Some apps' fields are said to replace their whole text with each edit instead of inserting (not seen on the emulator). `setText` then ends at what the TV has, and calling it again reaches the wanted text: it deletes the whole text and adds the wanted one. A step there whose result keeps the length is not reported, and the client keeps the text it knew until the TV reports again.

Every failure of `setText` comes through its future: `TvCancelledException` when the field lost the focus, `TvNotSupportedException` without `TvFeature.ime` and `TvFeature.key` (a TV without ranges gets Del and Move End, which are keys), and what ended the session. `insert` and `submit` throw the same synchronously.

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

- Cyrillic, combining accents, emoji with skin tones, family emoji, flags, right-to-left text, tabs and line breaks arrive intact. Any `setText`, including emptying a 2000-character field, takes tens of milliseconds; the same deletion by Del keys took over a minute, since the TV lost keys sent in quick succession.
- The cursor keys, Move End and Move Home sent through the remote did not move the field's cursor, and the TV does not report cursor moves; after an edit the cursor is at the end of the replaced range.
- An edit sent while no field has the focus is dropped silently; the session goes on.
