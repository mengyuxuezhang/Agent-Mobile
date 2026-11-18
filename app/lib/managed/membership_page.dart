import 'package:flutter/material.dart';

import '../l10n/l10n.dart';
import 'client.dart';

class ManagedMembershipPage extends StatefulWidget {
  const ManagedMembershipPage({super.key, required this.client, required this.token, required this.userId});

  final ManagedClient client;
  final String token;
  final String userId;

  @override
  State<ManagedMembershipPage> createState() => _ManagedMembershipPageState();
}

class _ManagedMembershipPageState extends State<ManagedMembershipPage> {
  JsonObject? _catalog;
  JsonObject? _membership;
  bool _loading = false;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final [catalog, account] = await Future.wait([
        widget.client.membershipStore(widget.token),
        widget.client.account(widget.token),
      ]);
      final user = account['user'];
      if (catalog['userId'] != widget.userId || user is! JsonObject || user['id'] != widget.userId) {
        throw const FormatException('Membership account mismatch');
      }
      if (!mounted) return;
      final membership = user['membership'];
      setState(() {
        _catalog = catalog;
        _membership = membership is JsonObject ? membership : null;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final cards = _catalog?['cards'];
    final methods = _catalog?['paymentMethods'];
    final desktopPayment =
        methods is List &&
        methods.whereType<JsonObject>().any((method) => method['provider'] == 'alipay' && method['mode'] == 'page');
    return Scaffold(
      appBar: AppBar(title: Text(l10n.managedMembershipStore)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            if (_loading) const LinearProgressIndicator(),
            if (_failed) Text(l10n.managedRequestFailed),
            if (_catalog != null) ...[
              Text(l10n.managedMembershipValue('${_membership?['cardName'] ?? '—'}')),
              if (_membership?['expiresAt'] case final String expiry when expiry.isNotEmpty)
                Text(l10n.managedMembershipExpiry(expiry.split('T').first)),
              const SizedBox(height: 12),
              if (cards is List)
                for (final card in cards.whereType<JsonObject>())
                  if (card['package'] case final JsonObject offer)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${card['name'] ?? ''}'),
                      subtitle: Text(
                        [
                          if (offer['name'] case final String name when name.isNotEmpty) name,
                          if (card['description'] case final String description when description.isNotEmpty)
                            description,
                          if (int.tryParse('${offer['durationDays']}') case final int days when days > 0)
                            l10n.managedMembershipDays(days),
                        ].join('\n'),
                      ),
                      trailing: Text('¥${(num.tryParse('${offer['price']}') ?? 0).toStringAsFixed(2)}'),
                    ),
              if (cards is! List || cards.isEmpty) Text(l10n.managedMembershipEmpty),
              const SizedBox(height: 16),
              if (desktopPayment && cards is List && cards.isNotEmpty)
                Text(l10n.managedDesktopPaymentGuide)
              else
                Text(l10n.managedMembershipPaymentUnavailable),
            ],
            TextButton(onPressed: _loading ? null : _refresh, child: Text(l10n.managedRefreshBenefits)),
          ],
        ),
      ),
    );
  }
}
