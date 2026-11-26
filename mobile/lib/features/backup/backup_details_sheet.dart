import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/backup_service.dart';
import '../../models/json.dart';
import '../../models/website_rule.dart' show websitesOf;
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../accounts/websites_editor.dart';

/// What a backup-code service is called, which is its name when it has one and its service name otherwise.
String backupTitle(BackupService service) {
  final name = service.name?.trim() ?? '';
  return name.isNotEmpty ? name : service.serviceName;
}

/// Opens the sheet that edits [service]'s name and websites; [onSave] gets the changed service.
Future<void> showBackupDetailsSheet(BuildContext context, BackupService service, ValueChanged<BackupService> onSave) =>
    showAppBottomSheet<void>(
      context,
      label: context.t('accounts.backup.details'),
      builder: (_) => BackupDetailsSheet(service: service, onSave: onSave),
    );

/// A backup-code service's optional name and the websites its codes are used on. A service linked to an item that has websites shows
/// that item's, read-only, and writes none of its own.
class BackupDetailsSheet extends ConsumerStatefulWidget {
  const BackupDetailsSheet({super.key, required this.service, required this.onSave});

  final BackupService service;
  final ValueChanged<BackupService> onSave;

  @override
  ConsumerState<BackupDetailsSheet> createState() => _BackupDetailsSheetState();
}

class _BackupDetailsSheetState extends ConsumerState<BackupDetailsSheet> {
  late final _name = TextEditingController(text: widget.service.name ?? '');
  late final _websites = WebsitesDraft(widget.service.rules);

  @override
  void initState() {
    super.initState();
    _websites.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _websites.dispose();
    super.dispose();
  }

  void _save(bool inherited) {
    final name = _name.text.trim();
    var next = widget.service.copyWith(name: name.isEmpty ? unset : name);
    if (!inherited) {
      final made = websitesOf(_websites.rules);
      next = next.copyWith(websites: made.websites ?? unset, uris: made.uris ?? unset);
    }
    widget.onSave(next);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final inherited = inheritedWebsites(ref.watch(vaultControllerProvider.select((state) => state.lists)), widget.service);
    final linked = inherited.isNotEmpty;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.confirmation_number_outlined), title: context.t('accounts.backup.details')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: InputDecoration(
                    labelText: context.t('accounts.field.name'),
                    hintText: context.t('accounts.field.nameBackupPlaceholder'),
                  ),
                ),
                const SizedBox(height: 16),
                if (linked)
                  InheritedWebsites(rules: inherited)
                else ...[
                  SectionLabel(context.t('accounts.websites.title'), padding: const EdgeInsets.fromLTRB(4, 0, 4, 8)),
                  WebsitesEditor(draft: _websites),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 8,
            children: [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: p.text),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(context.t('addBackup.cancel')),
              ),
              FilledButton(
                onPressed: linked || _websites.isValid ? () => _save(linked) : null,
                child: Text(context.t('accountSheet.save')),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
