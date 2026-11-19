import 'package:flutter/material.dart';

import '../../l10n/l10n.dart';
import 'client.dart';

typedef DesktopOptions = ({String? model, String? expert, String? mode, Set<String> skills});

String desktopModeLabel(L10n l10n, String? mode) => switch (mode) {
  'plan' => l10n.desktopRemotePlanMode,
  'ask' => l10n.desktopRemoteAskMode,
  'goal' => l10n.desktopRemoteGoalMode,
  _ => l10n.desktopRemoteNormalMode,
};

Future<DesktopOptions?> chooseDesktopOptions(
  BuildContext context,
  RemoteJson catalog, {
  required DesktopOptions initial,
  required bool creating,
  bool allowGoal = true,
}) => showModalBottomSheet<DesktopOptions>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _OptionsSheet(catalog: catalog, initial: initial, creating: creating, allowGoal: allowGoal),
);

class _OptionsSheet extends StatefulWidget {
  const _OptionsSheet({required this.catalog, required this.initial, required this.creating, required this.allowGoal});

  final RemoteJson catalog;
  final DesktopOptions initial;
  final bool creating;
  final bool allowGoal;

  @override
  State<_OptionsSheet> createState() => _OptionsSheetState();
}

class _OptionsSheetState extends State<_OptionsSheet> {
  late String? _model = widget.initial.model;
  late String? _expert = widget.initial.expert;
  late String? _mode = widget.initial.mode;
  late final Set<String> _skills = {...widget.initial.skills};

  List<RemoteJson> _items(String key) => (widget.catalog[key] as List<dynamic>? ?? []).whereType<RemoteJson>().toList();

  Widget _picker(String title, List<RemoteJson> items, String? value, ValueChanged<String?> changed) {
    final defaultLabel = context.l10n.desktopRemoteUseDefault;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DropdownButtonFormField<String>(
        initialValue: items.any((item) => item['id'] == value) ? value : '',
        decoration: InputDecoration(labelText: title, border: const OutlineInputBorder()),
        isExpanded: true,
        items: [
          DropdownMenuItem(value: '', child: Text(defaultLabel)),
          for (final item in items)
            DropdownMenuItem(
              value: item['id'] as String,
              child: Text(item['name'] as String, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: items.isEmpty ? null : (value) => changed(value == '' ? null : value),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final skills = _items('skills');
    return FractionallySizedBox(
      heightFactor: .86,
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
          children: [
            Text(
              widget.creating ? l10n.desktopRemoteNewChat : l10n.desktopRemoteOptions,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            _picker(l10n.desktopRemoteModel, _items('models'), _model, (value) => _model = value),
            if (widget.creating)
              _picker(l10n.desktopRemoteExpert, _items('agents'), _expert, (value) => _expert = value),
            _picker(
              l10n.desktopRemoteMode,
              [
                for (final mode in ['default', 'plan', 'ask', if (widget.allowGoal) 'goal'])
                  {'id': mode, 'name': desktopModeLabel(l10n, mode)},
              ],
              _mode,
              (value) => _mode = value,
            ),
            Text(l10n.desktopRemoteSkills, style: Theme.of(context).textTheme.titleSmall),
            if (skills.isEmpty) Text(l10n.desktopRemoteNoSkills),
            Wrap(
              spacing: 8,
              children: [
                for (final skill in skills)
                  FilterChip(
                    label: Text(skill['name'] as String),
                    selected: _skills.contains(skill['id']),
                    onSelected: (selected) => setState(() {
                      final id = skill['id'] as String;
                      if (!selected) {
                        _skills.remove(id);
                      } else if (_skills.length < 12) {
                        _skills.add(id);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, (
                model: _model,
                expert: _expert,
                mode: _mode,
                skills: _skills.intersection(skills.map((item) => item['id'] as String).toSet()),
              )),
              child: Text(widget.creating ? l10n.desktopRemoteNewChat : l10n.desktopRemoteApplyOptions),
            ),
          ],
        ),
      ),
    );
  }
}
