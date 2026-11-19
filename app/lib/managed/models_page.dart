import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/l10n.dart';
import '../ui/providers/new_chat_defaults_card.dart';
import '../ui/settings/settings_widgets.dart';
import '../ui/shell/page_frame.dart';
import 'account_page.dart';
import 'model_sync.dart';
import 'session.dart';

class ManagedModelsPage extends ConsumerWidget {
  const ManagedModelsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final signedIn = ref.watch(managedSignedInProvider);
    final catalog = ref.watch(managedModelCatalogProvider);
    final sync = ref.watch(managedModelSyncProvider);
    final models = catalog.value == null ? [] : managedModels(catalog.value!);
    return AppPage.list(
      title: l10n.engineProvidersTitle,
      children: [
        if (signedIn && models.isNotEmpty) const NewChatDefaultsCard(),
        SettingsSection(
          title: l10n.managedOfficial,
          children: [
            if (!signedIn)
              SettingsTile(
                title: l10n.managedModelsSignIn,
                onTap: () =>
                    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ManagedAccountPage())),
              )
            else if (catalog.hasError || sync.hasError)
              SettingsTile(
                title: l10n.viewModelLoadFailed,
                onTap: () => ref.invalidate(managedModelCatalogProvider),
                value: Text(l10n.commonRetry),
              )
            else if (catalog.isLoading || sync.isLoading)
              const LinearProgressIndicator()
            else if (models.isEmpty)
              SettingsTile(title: l10n.managedModelsEmpty),
            for (final model in models) SettingsTile(title: model.name ?? model.id),
          ],
        ),
      ],
    );
  }
}
