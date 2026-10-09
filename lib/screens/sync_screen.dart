import 'package:flutter/material.dart';

import '../services/launcher_controller.dart';
import '../services/s3_config.dart';
import '../services/sync.dart';

/// S3 sync settings, "Sync now" and the other phones the last sync found.
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.controller});

  final LauncherController controller;

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  late final SyncConfig _start = widget.controller.syncConfig;
  late final _endpoint = TextEditingController(text: _start.endpoint);
  late final _region = TextEditingController(text: _start.region);
  late final _bucket = TextEditingController(text: _start.bucket);
  late final _keyId = TextEditingController(text: _start.accessKeyId);
  late final _secret = TextEditingController(text: _start.secretAccessKey);
  late final _name = TextEditingController(text: _start.deviceName);
  String? _result;
  bool _busy = false;

  LauncherController get _c => widget.controller;

  @override
  void initState() {
    super.initState();
    _c.addListener(_rebuild);
  }

  void _rebuild() => setState(() {});

  @override
  void dispose() {
    _c.removeListener(_rebuild);
    for (final t in [_endpoint, _region, _bucket, _keyId, _secret, _name]) {
      t.dispose();
    }
    super.dispose();
  }

  void _save({bool? enabled}) => _c.updateSyncConfig(
    _c.syncConfig.copyWith(
      enabled: enabled,
      endpoint: _endpoint.text,
      region: _region.text,
      bucket: _bucket.text,
      accessKeyId: _keyId.text,
      secretAccessKey: _secret.text,
      deviceName: _name.text,
    ),
  );

  Future<void> _syncNow() async {
    _save();
    setState(() {
      _busy = true;
      _result = 'Syncing…';
    });
    String message;
    try {
      await _c.syncNow();
      final n = _c.otherPhones.length;
      message =
          'Synced with ${n == 0
              ? 'no other phones yet'
              : n == 1
              ? '1 other phone'
              : '$n other phones'}.';
    } on SyncException catch (e) {
      message = e.message;
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _result = message;
      });
    }
  }

  static String _when(DateTime? t) {
    if (t == null) return 'never';
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  Widget _field(String key, TextEditingController c, String label, {String? hint, bool secret = false}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: TextField(
      key: Key(key),
      controller: c,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(labelText: label, hintText: hint),
      onChanged: (_) => _save(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final cfg = _c.syncConfig;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: ListView(
        children: [
          // The identifiers are resource-ids on Android, for the e2e.
          Semantics(
            identifier: 'sync-enabled',
            child: SwitchListTile(
              key: const Key('sync-enabled'),
              title: const Text('Sync between phones'),
              subtitle: const Text('Launch counts and home cells, through an S3 bucket'),
              value: cfg.enabled,
              onChanged: (v) => _save(enabled: v),
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              'Each phone writes a file of its own and reads the others. Launch counts add up across phones. '
              'Icons already on the home screen stay where they are; an app that gets a cell later goes to the '
              'cell it has on your other phones, and a cell kept for an app this phone lacks is lent until you '
              'install it. Automatic syncs fail silently; Sync now tells you what went wrong.',
            ),
          ),
          _field('sync-endpoint', _endpoint, 'Endpoint', hint: kDefaultS3Endpoint),
          _field('sync-region', _region, 'Region', hint: kDefaultS3Region),
          _field('sync-bucket', _bucket, 'Bucket', hint: kDefaultS3Bucket),
          _field('sync-key-id', _keyId, 'Access key ID'),
          _field('sync-secret', _secret, 'Secret key', secret: true),
          _field('sync-name', _name, "This phone's name", hint: 'Shown on your other phones'),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Semantics(
                  identifier: 'sync-now',
                  child: FilledButton.icon(
                    key: const Key('sync-now'),
                    onPressed: _busy || !cfg.enabled ? null : _syncNow,
                    icon: const Icon(Icons.sync),
                    label: const Text('Sync now'),
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(child: Text('Last sync: ${_when(_c.lastSync)}', key: const Key('sync-last'))),
              ],
            ),
          ),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(_result!, key: const Key('sync-result')),
            ),
          if (_c.otherPhones.isNotEmpty) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text('Other phones', style: text.titleMedium),
            ),
            for (final d in _c.otherPhones)
              ListTile(
                key: ValueKey('phone-${d.device}'),
                leading: const Icon(Icons.smartphone),
                title: Text(d.label),
                subtitle: Text(
                  '${d.counts.values.fold(0, (a, b) => a + b)} launches, '
                  '${d.cells.length} home cells, updated ${_when(d.updatedAt)}',
                ),
              ),
          ],
        ],
      ),
    );
  }
}
